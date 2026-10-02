# Worktrees — one per agent task, under .worktrees/ (gitignored)

[private]
default:
    @just --list wt

# Create .worktrees/<type>-<slug> on branch <type>/<slug>, with .worktreeinclude files copied in
[group('wt')]
new branch:
    #!/usr/bin/env bash
    set -euo pipefail
    # In a just module, justfile_directory() is the root justfile's dir, so this resolves to the
    # checkout `just` ran from; worktrees always hang off the main checkout.
    main="$(dirname "$(git -C "{{ justfile_directory() }}" rev-parse --path-format=absolute --git-common-dir)")"
    dir="$main/.worktrees/$(echo "{{ branch }}" | tr '/' '-')"
    git -C "$main" worktree add "$dir" -b "{{ branch }}" main
    grep -v -e '^#' -e '^$' "{{ justfile_directory() }}/.worktreeinclude" | while read -r f; do
      if [ -e "$main/$f" ]; then (cd "$main" && cp -a --parents "$f" "$dir/"); fi
    done
    echo "$dir"

# Remove a worktree and its branch; refuses if it has uncommitted work or unmerged commits
[group('wt')]
rm branch:
    #!/usr/bin/env bash
    set -euo pipefail
    main="$(dirname "$(git -C "{{ justfile_directory() }}" rev-parse --path-format=absolute --git-common-dir)")"
    git -C "$main" merge-base --is-ancestor "{{ branch }}" main || { echo "{{ branch }} is not merged into main"; exit 1; }
    git -C "$main" worktree remove "$main/.worktrees/$(echo "{{ branch }}" | tr '/' '-')"
    git -C "$main" branch -d "{{ branch }}"

# List worktrees
[group('wt')]
ls:
    @git worktree list
