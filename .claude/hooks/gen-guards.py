#!/usr/bin/env python3
"""Generate the destructive-command guards from guard-rules.json.

One rule table, two runtimes. The Claude Code hook (bash) and the opencode plugin
(JavaScript) used to carry hand-maintained copies of the same rules; they drifted,
and the drift was only ever found by accident. Both are now generated from
guard-rules.json, and pre-commit re-runs this with --check so a hand-edit or a
half-applied change fails the commit instead of shipping.

This file and guard-rules.json are vendored into each repo under .claude/hooks/, so
generation and verification work in CI with no dotfiles checkout present. The
canonical copies live in dotfiles/home/claude/agent-hooks/ and are pushed out by
sync-hooks.sh.

Usage:
    gen-guards.py [--repo-root DIR] [--check]
"""

from __future__ import annotations

import argparse
import difflib
import json
import shlex
import sys
from pathlib import Path

BANNER = """# GENERATED FILE — do not edit here.
# Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
# Regenerate: python3 .claude/hooks/gen-guards.py
# Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)"""

# Kept byte-identical to the pass in the JS guard below. A heredoc body is data being
# written to a file, not a command being executed, so matching rules against it produced
# false positives — documentation that merely quoted a guarded command was blocked.
HEREDOC_PY = r'''
import sys, json, re
try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    print(""); sys.exit(0)
lines = cmd.split("\n")
kept, i = [], 0
start = re.compile(r"<<-?[ \t]*([\x27\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
while i < len(lines):
    line = lines[i]
    kept.append(line)
    i += 1
    for _q, delim in start.findall(line):
        while i < len(lines) and lines[i].strip() != delim:
            i += 1
        if i < len(lines):
            i += 1
print("\n".join(kept))
'''


def rules_for(spec: dict, repo_key: str) -> list[dict]:
    out = []
    for rule in spec["rules"]:
        repos = rule.get("repos")
        if repos is None or repo_key in repos:
            out.append(rule)
    return out


def fast_path_regex(spec: dict) -> str:
    parts = list(spec["fast_path_keywords"])
    parts += [f"(^|[^[:alnum:]_]){w}[^[:alnum:]_]" for w in spec["fast_path_words"]]
    return "(" + "|".join(parts) + ")"


def render_bash(spec: dict, repo_key: str) -> str:
    lines = [
        "#!/usr/bin/env bash",
        BANNER,
        "#",
        "# PreToolUse:Bash — blocks destructive cluster operations that bypass GitOps or",
        "# the sanctioned just commands.",
        "",
        "# The rule patterns are single-quoted regexes, so a literal \\$HOME in one is deliberate —",
        "# it must reach grep unexpanded. shellcheck reads it as a missed expansion.",
        "# shellcheck disable=SC2016",
        "set -euo pipefail",
        "",
        "INPUT=$(cat)",
        "",
        "# Fast path: skip the Python pass entirely when no rule below can possibly fire.",
        "# The stripped command is always a subset of this raw payload, so a keyword absent",
        "# here cannot appear in it. Saves ~60ms of interpreter startup on Bash calls that",
        "# match no rule at all, which is most of them.",
        f'[[ "$INPUT" =~ {fast_path_regex(spec)} ]] || exit 0',
        "",
        "# Strip heredoc BODIES before any rule sees the command; the opening line is kept,",
        "# so the real command on it (git commit -F - <<'MSG', python3 <<PY, ...) is checked.",
        "COMMAND=$(printf '%s' \"$INPUT\" | python3 -c '" + HEREDOC_PY.strip("\n") + "' 2>/dev/null || echo \"\")",
        "",
        "block() {",
        "    # Must be stderr: a PreToolUse hook's exit-2 reason only reaches the model on",
        "    # stderr. On stdout the call is still refused but the explanation is dropped,",
        '    # surfacing as "No stderr output".',
        '    echo "BLOCKED: $1" >&2',
        '    echo "Alternative: $2" >&2',
        "    exit 2",
        "}",
        "",
        "# Read-only validation is always fine",
        f'printf \'%s\' "$COMMAND" | grep -qE -- {shlex.quote(spec["always_allow"]["pattern"])} && exit 0',
    ]

    for rule in rules_for(spec, repo_key):
        lines += [
            "",
            f'# {rule["id"]}',
            f'if printf \'%s\' "$COMMAND" | grep -qE -- {shlex.quote(rule["pattern"])}; then',
            f'    block {shlex.quote(rule["reason"])} {shlex.quote(rule["alternative"])}',
            "fi",
        ]

    lines += ["", "exit 0", ""]
    return "\n".join(lines)


def render_js(spec: dict, repo_key: str) -> str:
    entries = []
    for rule in rules_for(spec, repo_key):
        entries.append(
            "  {\n"
            f"    id: {json.dumps(rule['id'])},\n"
            f"    pattern: new RegExp({json.dumps(rule['pattern'])}),\n"
            f"    reason: {json.dumps(rule['reason'])},\n"
            f"    alternative: {json.dumps(rule['alternative'])},\n"
            "  },"
        )

    return f"""// {BANNER.replace(chr(10) + "# ", chr(10) + "// ").lstrip("# ")}
//
// opencode counterpart to .claude/hooks/guard-destructive.sh. Both are generated from
// the same rule table, so the two cannot drift apart.

const RULES = [
{chr(10).join(entries)}
]

const ALWAYS_ALLOW = new RegExp({json.dumps(spec["always_allow"]["pattern"])})

// Strip heredoc BODIES before any rule sees the command. A heredoc body is data being
// written to a file, not a command being executed, so matching rules against it produced
// false positives. The heredoc's opening line is kept, so the real command on it is still
// checked. <<WORD / <<'WORD' / <<"WORD" / <<-WORD, but not the <<<herestring form.
const HEREDOC_START = /<<-?[ \\t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\\1/g

function stripHeredocBodies(command) {{
  const lines = command.split("\\n")
  const kept = []
  let i = 0
  while (i < lines.length) {{
    const line = lines[i]
    kept.push(line)
    i += 1
    HEREDOC_START.lastIndex = 0
    for (const m of line.matchAll(HEREDOC_START)) {{
      const delim = m[2]
      while (i < lines.length && lines[i].trim() !== delim) i += 1
      if (i < lines.length) i += 1 // consume the terminator line itself
    }}
  }}
  return kept.join("\\n")
}}

export const GuardDestructive = async () => {{
  return {{
    "tool.execute.before": async (input, output) => {{
      if (input.tool !== "bash") return

      const command = stripHeredocBodies(output.args?.command ?? "")

      if (ALWAYS_ALLOW.test(command)) return

      for (const rule of RULES) {{
        if (rule.pattern.test(command)) {{
          throw new Error(`BLOCKED: ${{rule.reason}}\\nAlternative: ${{rule.alternative}}`)
        }}
      }}
    }},
  }}
}}
"""


def emit(path: Path, content: str, check: bool, executable: bool) -> bool:
    """Write content, or in check mode report whether it already matches. True == drift."""
    existing = path.read_text() if path.exists() else None
    if existing == content:
        return False
    if check:
        rel = path
        print(f"DRIFT: {rel} does not match guard-rules.json", file=sys.stderr)
        for line in difflib.unified_diff(
            (existing or "").splitlines(keepends=True),
            content.splitlines(keepends=True),
            fromfile=f"{rel} (on disk)",
            tofile=f"{rel} (generated)",
        ):
            sys.stderr.write(line)
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)
    print(f"wrote {path}")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", default=None, help="repo root (default: parent of .claude/hooks)")
    ap.add_argument("--check", action="store_true", help="fail on drift instead of rewriting")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent
    root = Path(args.repo_root).resolve() if args.repo_root else here.parent.parent

    spec = json.loads((here / "guard-rules.json").read_text())

    key_file = here / "guard-repo"
    if not key_file.exists():
        print(f"error: {key_file} is missing — it names which repo's rules to emit", file=sys.stderr)
        return 2
    repo_key = key_file.read_text().strip()

    known = {r for rule in spec["rules"] for r in rule.get("repos", [])}
    if known and repo_key not in known:
        print(f"error: unknown repo key {repo_key!r}; guard-rules.json knows {sorted(known)}", file=sys.stderr)
        return 2

    drift = emit(root / ".claude/hooks/guard-destructive.sh", render_bash(spec, repo_key), args.check, True)

    opencode = root / ".opencode/plugins"
    if opencode.is_dir():
        drift |= emit(opencode / "guard-destructive.js", render_js(spec, repo_key), args.check, False)

    if drift:
        print(
            "\nThe guards are generated. Edit .claude/hooks/guard-rules.json, then run:\n"
            "    python3 .claude/hooks/gen-guards.py",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
