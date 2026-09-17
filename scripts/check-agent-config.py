#!/usr/bin/env python3
"""Audit this repo's own agent config for the drift that makes context silently vanish.

check-doc-paths.py catches a dead path inside a doc. check-doc-cluster-claims.py catches a dead
cluster name. Neither catches the wiring: a skill with no frontmatter is never auto-invoked, a
skill with no `.claude/skills/` symlink is invisible to Claude Code, a dangling `@import` in
CLAUDE.md drops a whole instruction file, and a reference doc missing from the AGENTS.md index is
one no agent will ever think to open.

Every one of those failures is silent. Nothing errors; the agent just does not know the rule
exists and confidently does the wrong thing. A sibling home-ops repo ships an AGENTS.md claiming
a `.claude/skills` symlink it does not have, and another has a 19KB `.agents/AGENTS.md` that no
tool loads at all — both would have been caught by twenty lines of grep.

Offline and fast, so it runs in lefthook. Usage: check-agent-config.py [--quiet]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

problems: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


def frontmatter(path: Path) -> dict[str, str] | None:
    """Parse the leading --- block. Flat scalars only; that is all we check."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end == -1:
        return None
    out: dict[str, str] = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def check_skills() -> None:
    skills_dir = ROOT / ".agents/skills"
    for skill_md in sorted(skills_dir.glob("*/SKILL.md")):
        name = skill_md.parent.name
        fm = frontmatter(skill_md)
        if fm is None:
            fail(f"skill {name}: no YAML frontmatter — it can never be auto-invoked")
            continue
        if not fm.get("name"):
            fail(f"skill {name}: frontmatter has no `name:`")
        elif fm["name"] != name:
            fail(f"skill {name}: frontmatter name is `{fm['name']}`, does not match the directory")
        if not fm.get("description"):
            fail(f"skill {name}: frontmatter has no `description:` — nothing can match it to a task")

        link = ROOT / ".claude/skills" / name
        if not link.is_symlink():
            fail(f"skill {name}: no `.claude/skills/{name}` symlink — invisible to Claude Code")
        elif not link.resolve().exists():
            fail(f"skill {name}: `.claude/skills/{name}` symlink is dangling")

    # A symlink pointing at a skill that no longer exists.
    claude_skills = ROOT / ".claude/skills"
    if claude_skills.is_dir():
        for link in sorted(claude_skills.iterdir()):
            if link.is_symlink() and not link.resolve().exists():
                fail(f"`.claude/skills/{link.name}` is a dangling symlink — the skill was removed")


def check_agents() -> None:
    for agent_md in sorted((ROOT / ".agents/agents").glob("*.md")):
        name = agent_md.stem
        fm = frontmatter(agent_md)
        if fm is None:
            fail(f"subagent {name}: no YAML frontmatter — it cannot be dispatched")
            continue
        for key in ("name", "description", "mode"):
            if not fm.get(key):
                fail(f"subagent {name}: frontmatter has no `{key}:`")
        if fm.get("mode") and fm["mode"] != "subagent":
            fail(f"subagent {name}: `mode: {fm['mode']}` — expected `subagent`")

        link = ROOT / ".claude/agents" / f"{name}.md"
        if not link.is_symlink():
            fail(f"subagent {name}: no `.claude/agents/{name}.md` symlink — invisible to Claude Code")
        elif not link.resolve().exists():
            fail(f"subagent {name}: `.claude/agents/{name}.md` symlink is dangling")


def check_imports() -> None:
    """Every @import in CLAUDE.md must resolve, or that instruction file is silently absent."""
    claude_md = ROOT / "CLAUDE.md"
    if not claude_md.exists():
        fail("no CLAUDE.md at the repo root — Claude Code does not read AGENTS.md natively")
        return
    imported: set[str] = set()
    for line in claude_md.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^@(\S+)", line.strip())
        if not m:
            continue
        target = m.group(1)
        imported.add(target)
        if not (ROOT / target).exists():
            fail(f"CLAUDE.md imports `@{target}`, which does not exist")

    # Every instruction file must reach Claude Code one way or the other:
    # an unconditional @import, or a paths:-scoped rule symlinked into .claude/rules/.
    rules_dir = ROOT / ".claude/rules"
    scoped: set[str] = set()
    if rules_dir.is_dir():
        for link in sorted(rules_dir.iterdir()):
            if not link.is_symlink():
                continue
            target = link.resolve()
            if not target.exists():
                fail(f"`.claude/rules/{link.name}` is a dangling symlink")
                continue
            scoped.add(target.name)
            fm = frontmatter(target)
            if not fm or "paths" not in fm:
                notes.append(
                    f"`.claude/rules/{link.name}` has no `paths:` frontmatter, so it loads on "
                    f"every session rather than on a matching file"
                )

    for instr in sorted((ROOT / ".agents/instructions").glob("*.md")):
        rel = f".agents/instructions/{instr.name}"
        if rel not in imported and instr.name not in scoped:
            fail(
                f"{rel} is neither imported by CLAUDE.md nor symlinked into .claude/rules/ — "
                f"Claude Code never loads it"
            )
        if rel in imported and instr.name in scoped:
            fail(
                f"{rel} is both @imported and a .claude/rules symlink — it loads twice, and the "
                f"paths: scoping buys nothing"
            )


def check_reference_index() -> None:
    """Every reference doc is in the AGENTS.md index, and every index row names a real file."""
    agents_md = ROOT / "AGENTS.md"
    if not agents_md.exists():
        fail("no AGENTS.md at the repo root")
        return
    text = agents_md.read_text(encoding="utf-8")
    listed = set(re.findall(r"`([a-z0-9][a-z0-9-]*\.md)`", text))

    on_disk = {p.name for p in (ROOT / ".agents/references").glob("*.md")}
    for name in sorted(on_disk - listed):
        fail(f".agents/references/{name} is not in the AGENTS.md index — no agent will open it")

    # An index row naming a reference that was deleted or renamed.
    instr_names = {p.name for p in (ROOT / ".agents/instructions").glob("*.md")}
    for name in sorted(listed - on_disk - instr_names):
        if (ROOT / ".agents/references" / name).exists():
            continue
        if any(ROOT.glob(f"**/{name}")):
            continue
        fail(f"AGENTS.md names `{name}`, which exists nowhere in the repo")


def check_opencode() -> None:
    cfg = ROOT / "opencode.json"
    if not cfg.exists():
        return
    text = cfg.read_text(encoding="utf-8")
    m = re.search(r'"instructions"\s*:\s*\[(.*?)\]', text, re.S)
    if not m:
        fail("opencode.json has no `instructions` key — opencode loads AGENTS.md only")
        return
    for pattern in re.findall(r'"([^"]+)"', m.group(1)):
        if not list(ROOT.glob(pattern)):
            fail(f"opencode.json instructions pattern `{pattern}` matches no file")


def main() -> int:
    quiet = "--quiet" in sys.argv
    check_skills()
    check_agents()
    check_imports()
    check_reference_index()
    check_opencode()

    for note in notes:
        if not quiet:
            print(f"note: {note}")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)

    if problems:
        print(f"\n{len(problems)} agent-config problem(s).", file=sys.stderr)
        return 1
    if not quiet:
        print("agent config OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
