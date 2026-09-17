#!/usr/bin/env python3
"""Behavioural tests for this repo's agent instructions.

`check-agent-config.py` proves a file is *wired*. It cannot prove the wiring carries meaning — that
an agent reading the assembled context actually comes away knowing to suspend the root Kustomization
before `apply-ks`, or that `ceph-block` no longer exists. That is what this does: assemble the real
context an agent would get, ask it questions the instructions are supposed to answer, and score the
replies against required and forbidden strings.

The point is mostly differential. `--ab <ref>` assembles the context from a git ref as well as from
the working tree, runs both, and reports what a doc edit gained or lost — which is the only honest
way to back a claim like "I cut 238 lines and nothing important went missing".

### Why this does not repeat the mistake it was modelled on

The reference implementation in the wild (ionfury/homelab `.claude/skills/instruction-eval`) never
loads a single CLAUDE.md. It primes the model with a short paraphrase that already contains the
answers its own probes look for, so every repo-constraint test passes for the wrong reason. This
harness assembles the actual file chain — CLAUDE.md, its `@` imports expanded recursively, and the
`paths:`-scoped rules that match a case's declared file — prints a fingerprint of what it built, and
refuses to run if the result is implausibly small. `--show-context` dumps it for inspection.

Usage:
  eval-instructions.py                      # run every case against the working tree
  eval-instructions.py --ab HEAD~1          # working tree vs a ref, report regressions
  eval-instructions.py --show-context       # print the assembled context and exit
  eval-instructions.py --case RULE-SUSPEND  # run one case
  eval-instructions.py --model <id>         # override the model

Needs `.env` (`just ai env`) for LITELLM_API_KEY, and `yq` to read the case files.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASE_DIR = ROOT / ".agents/evals"
BASE_URL = "https://litellm.dcunha.io/v1"
DEFAULT_MODEL = "opencode-go/qwen3.6-plus"

# An assembled context smaller than this means the chain failed to resolve and every
# constraint probe would pass or fail for the wrong reason. Refuse rather than report.
MIN_CONTEXT_BYTES = 6000

SEVERITY_EXIT = {"critical": 2, "major": 1, "minor": 0}

# Keyed (case_id, ref). A failing case is undiagnosable without the reply that produced it —
# most "failures" on first run are bad cases, not bad instructions, and the two are only
# distinguishable by reading what the model actually said.
REPLIES: dict[tuple[str, str | None], str] = {}


# --------------------------------------------------------------------------- context


def read_at(ref: str | None, rel: str) -> str | None:
    """Read a repo file from the working tree, or from a git ref when one is given."""
    if ref is None:
        p = ROOT / rel
        return p.read_text(encoding="utf-8") if p.is_file() else None
    try:
        return subprocess.run(
            ["git", "show", f"{ref}:{rel}"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout
    except subprocess.CalledProcessError:
        return None


def expand_imports(text: str, ref: str | None, seen: set[str], depth: int = 0) -> str:
    """Expand `@path` imports the way Claude Code does — recursively, to 4 hops."""
    if depth >= 4:
        return text
    out = []
    for line in text.splitlines():
        m = re.match(r"^@(\S+)\s*$", line.strip())
        if not m:
            out.append(line)
            continue
        rel = m.group(1)
        if rel in seen:
            continue
        seen.add(rel)
        body = read_at(ref, rel)
        if body is None:
            out.append(f"[MISSING IMPORT: {rel}]")
            continue
        out.append(f"\n===== {rel} =====")
        out.append(expand_imports(body, ref, seen, depth + 1))
    return "\n".join(out)


def rule_paths(text: str) -> list[str]:
    """Pull the `paths:` list out of a rule file's frontmatter."""
    if not text.startswith("---\n"):
        return []
    end = text.find("\n---", 4)
    if end == -1:
        return []
    block = text[4:end]
    m = re.search(r"^paths:\s*\n((?:\s*-\s*.+\n?)+)", block, re.M)
    if not m:
        inline = re.search(r'^paths:\s*\[(.*)\]', block, re.M)
        return re.findall(r'"([^"]+)"', inline.group(1)) if inline else []
    return [x.strip().strip('"\'') for x in re.findall(r"-\s*(.+)", m.group(1))]


def matches(glob: str, path: str) -> bool:
    """`kubernetes/**` must match `kubernetes/a/b.yaml`; fnmatch alone does not do that."""
    if fnmatch.fnmatch(path, glob):
        return True
    if glob.endswith("/**"):
        return path.startswith(glob[:-2])
    return fnmatch.fnmatch(path, glob.replace("**/", "*"))


def build_context(ref: str | None, context_path: str | None) -> tuple[str, list[str]]:
    """Assemble exactly what an agent would have: CLAUDE.md + imports + matching rules."""
    parts: list[str] = []
    loaded: list[str] = []

    root_md = read_at(ref, "CLAUDE.md")
    if root_md is None:
        raise SystemExit("error: CLAUDE.md not found — cannot assemble context")
    parts.append("===== CLAUDE.md =====")
    parts.append(expand_imports(root_md, ref, {"CLAUDE.md"}))
    loaded.append("CLAUDE.md (+imports)")

    if context_path:
        rules_dir = ROOT / ".claude/rules"
        for link in sorted(rules_dir.iterdir()) if rules_dir.is_dir() else []:
            rel = os.path.relpath(link.resolve(), ROOT)
            body = read_at(ref, rel)
            if body is None:
                continue
            globs = rule_paths(body)
            if any(matches(g, context_path) for g in globs):
                parts.append(f"\n===== {rel} (path-scoped, matched {context_path}) =====")
                parts.append(body)
                loaded.append(f"{rel} [scoped]")

    return "\n".join(parts), loaded


# --------------------------------------------------------------------------- cases


def load_cases() -> list[dict]:
    if not CASE_DIR.is_dir():
        raise SystemExit(f"error: no case directory at {CASE_DIR}")
    cases: list[dict] = []
    for f in sorted(CASE_DIR.glob("*.yaml")):
        try:
            out = subprocess.run(
                ["yq", "-o=json", "-I0", ".", str(f)],
                capture_output=True, text=True, check=True,
            ).stdout
        except FileNotFoundError:
            raise SystemExit("error: yq not found — it parses the case files")
        except subprocess.CalledProcessError as e:
            raise SystemExit(f"error: {f.name} is not valid YAML\n{e.stderr}")
        data = json.loads(out)
        for c in data.get("cases", []):
            c["_file"] = f.name
            cases.append(c)
    return cases


# --------------------------------------------------------------------------- model


# Without this, a tool-capable model answers an operational question by emitting tool-call markup
# instead of prose, and the reply is unscoreable — it neither passes nor fails for any reason to do
# with the instructions. Seen on QUIRK-ZFS-EXTENSION, which reads as a request to go and check.
ANSWER_DIRECTLY = (
    "\n\n---\n\nYou are being evaluated on the context above. Answer the question directly, in "
    "prose, from what that context says. Do not call tools, do not emit tool-call markup, and do "
    "not propose commands to run first — if the context does not settle it, say so."
)


def ask(model: str, context: str, prompt: str, api_key: str) -> str:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": context + ANSWER_DIRECTLY},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": 700,
    }).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)["choices"][0]["message"]["content"] or ""
    except urllib.error.HTTPError as e:
        return f"[HTTP {e.code}: {e.read()[:300].decode(errors='replace')}]"
    except Exception as e:  # noqa: BLE001 - a transport failure is a case failure, not a crash
        return f"[ERROR: {e}]"


# A correct answer usually has to NAME the forbidden thing in order to rule it out —
# "SOPS is fully removed", "no `git add .`", "no Co-Authored-By trailer". Naive substring
# matching scores all three as failures, which is how a good instruction set looks broken.
# Only an AFFIRMATIVE use counts, so a hit preceded by a negation is not a hit.
NEGATORS = (
    "no ", "not ", "never", "don't", "do not", "avoid", "without", "removed", "no longer",
    "instead of", "rather than", "must not", "cannot", "can't", "refrain", "neither", "nor ",
    "forbidden", "prohibited", "deprecated", "gone", "does not exist", "unlike", "—no", "not:",
)


# A negation can also FOLLOW the term — "SOPS and age are fully removed", "ceph-block is gone".
TRAILING_NEGATORS = (
    "removed", "no longer", "is gone", "are gone", "does not exist", "do not exist",
    "not used", "is not", "are not", "was removed", "were removed", "deprecated",
    "not available", "unavailable", "retired",
)


def negated(low: str, at: int, span: int, back: int = 60, fwd: int = 70) -> bool:
    """True when the match sits inside a clause ruling it out, before or after the term."""
    if any(n in low[max(0, at - back):at] for n in NEGATORS):
        return True
    after = low[at + span:at + span + fwd]
    # Stop at a sentence boundary so a later unrelated sentence cannot excuse the hit.
    after = re.split(r"[.!?\n]", after)[0]
    return any(n in after for n in TRAILING_NEGATORS)


def score(case: dict, reply: str) -> tuple[bool, list[str]]:
    """A case passes when every `required` hits, no `forbidden` hits, and `any_of` hits once."""
    low = reply.lower()
    notes: list[str] = []
    ok = True

    for needle in case.get("required", []):
        if needle.lower() not in low:
            ok = False
            notes.append(f"missing required: {needle!r}")

    for needle in case.get("forbidden", []):
        n = needle.lower()
        hits = [i for i in range(len(low)) if low.startswith(n, i)]
        affirmative = [i for i in hits if not negated(low, i, len(n))]
        if affirmative:
            ok = False
            ctx = low[max(0, affirmative[0] - 50):affirmative[0] + len(n) + 20].replace("\n", " ")
            notes.append(f"hit forbidden: {needle!r} (affirmative use) …{ctx.strip()}…")

    alts = case.get("any_of", [])
    if alts and not any(a.lower() in low for a in alts):
        ok = False
        notes.append(f"none of any_of matched: {alts}")

    return ok, notes


# --------------------------------------------------------------------------- run


def run(cases: list[dict], ref: str | None, model: str, api_key: str) -> dict[str, tuple[bool, list[str]]]:
    results: dict[str, tuple[bool, list[str]]] = {}
    ctx_cache: dict[str | None, str] = {}

    for case in cases:
        cpath = case.get("context_path")
        key = cpath
        if key not in ctx_cache:
            ctx, loaded = build_context(ref, cpath)
            if len(ctx) < MIN_CONTEXT_BYTES:
                raise SystemExit(
                    f"error: assembled context is only {len(ctx)} bytes "
                    f"(expected >{MIN_CONTEXT_BYTES}). The file chain did not resolve; "
                    f"refusing to score against an empty prompt. Loaded: {loaded}"
                )
            ctx_cache[key] = ctx
        reply = ask(model, ctx_cache[key], case["prompt"], api_key)
        REPLIES[(case["id"], ref)] = reply
        results[case["id"]] = score(case, reply)
    return results


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ab", metavar="REF", help="also run against this git ref and diff the results")
    ap.add_argument("--model", default=os.environ.get("EVAL_MODEL", DEFAULT_MODEL))
    ap.add_argument("--case", help="run a single case id")
    ap.add_argument("--show-context", action="store_true", help="print the assembled context and exit")
    ap.add_argument("--context-path", help="file path to resolve path-scoped rules against")
    ap.add_argument("--save", metavar="PATH", help="write every model reply here, for diagnosing failures")
    ap.add_argument("--show-replies", action="store_true", help="print the reply for each failing case")
    args = ap.parse_args()

    if args.show_context:
        ctx, loaded = build_context(None, args.context_path)
        print(f"--- loaded: {', '.join(loaded)}")
        print(f"--- {len(ctx)} bytes, {len(ctx.splitlines())} lines\n")
        print(ctx)
        return 0

    env = ROOT / ".env"
    api_key = ""
    if env.is_file():
        for line in env.read_text().splitlines():
            if line.startswith("LITELLM_API_KEY="):
                api_key = line.split("=", 1)[1].strip()
    api_key = os.environ.get("LITELLM_API_KEY", api_key)
    if not api_key:
        raise SystemExit("error: no LITELLM_API_KEY — run `just ai env`")

    cases = load_cases()
    if args.case:
        cases = [c for c in cases if c["id"] == args.case]
        if not cases:
            raise SystemExit(f"error: no case with id {args.case}")

    print(f"model: {args.model}   cases: {len(cases)}\n")
    now = run(cases, None, args.model, api_key)

    before = run(cases, args.ab, args.model, api_key) if args.ab else None

    worst = 0
    regressions = 0
    for case in cases:
        cid = case["id"]
        ok, notes = now[cid]
        mark = "PASS" if ok else "FAIL"
        line = f"  {mark}  {cid:<22} {case.get('category', '-')}"
        if before:
            was_ok = before[cid][0]
            if was_ok and not ok:
                line += "   << REGRESSION"
                regressions += 1
            elif ok and not was_ok:
                line += "   >> fixed"
        print(line)
        for n in notes:
            print(f"          {n}")
        if not ok:
            worst = max(worst, SEVERITY_EXIT.get(case.get("severity", "major"), 1))

    if args.show_replies:
        for case in cases:
            if not now[case["id"]][0]:
                print(f"\n--- reply for {case['id']} ---")
                print(REPLIES.get((case["id"], None), "").strip()[:1200])

    if args.save:
        out = []
        for case in cases:
            for ref in ([None, args.ab] if args.ab else [None]):
                out.append(f"===== {case['id']} ref={ref or 'working-tree'} =====")
                out.append(REPLIES.get((case["id"], ref), ""))
        pathlib.Path(args.save).write_text("\n".join(out), encoding="utf-8")
        print(f"replies written to {args.save}")

    failed = sum(1 for c in cases if not now[c["id"]][0])
    print(f"\n{len(cases) - failed}/{len(cases)} passed", end="")
    if before:
        print(f", {regressions} regression(s) vs {args.ab}", end="")
    print(".")

    if before and regressions:
        return 2
    return worst


if __name__ == "__main__":
    sys.exit(main())
