# Git Tasks

Simple Git workflow helpers for common operations.

**Module:** `git` (`.taskfiles/Git/Taskfile.yaml`)

---

## Status and Inspection

### `git:status`

Show git status.

**Usage:**
```bash
task git:status
```

**Equivalent to:**
```bash
git status
```

**Shows:**
- Modified files
- Staged files
- Untracked files
- Current branch
- Commits ahead/behind

---

### `git:diff`

Show git diff.

**Usage:**
```bash
task git:diff
```

**Equivalent to:**
```bash
git diff
```

**Shows:**
- Line-by-line changes in modified files
- Does not show staged changes (use `git diff --staged` for that)

---

## Sync Operations

### `git:pull`

Pull latest changes from remote.

**Usage:**
```bash
task git:pull
```

**Equivalent to:**
```bash
git pull --rebase
```

**What it does:**
- Fetches latest changes from origin
- Rebases your local commits on top
- Avoids merge commits

**Use before:**
- Starting new work
- After someone else pushed changes

---

### `git:push`

Push changes to remote.

**Usage:**
```bash
task git:push
```

**Equivalent to:**
```bash
git push
```

**What it does:**
- Pushes committed changes to origin
- Updates remote branch

**Prerequisites:**
- Changes must be committed first

---

## Common Workflows

### Before Starting Work

```bash
# Pull latest changes
task git:pull

# Check current status
task git:status
```

### After Making Changes

```bash
# See what changed
task git:diff

# Check status
task git:status

# Add and commit (manual)
git add .
git commit -m "feat: description of changes"

# Push to remote
task git:push
```

### Quick Status Check

```bash
# Are there any uncommitted changes?
task git:status

# What changed?
task git:diff
```

---

## Tips

### Commit Message Format

Follow conventional commits:

```bash
feat: add new feature
fix: fix bug
docs: update documentation
chore: update dependencies
refactor: refactor code
test: add tests
```

### Before Pushing

Always validate before pushing:

```bash
# Validate all changes
task validate:all

# Check what you're pushing
task git:diff
task git:status

# Push
task git:push
```

---

## Related Documentation

- [Git Documentation](https://git-scm.com/doc)
- [Conventional Commits](https://www.conventionalcommits.org/)