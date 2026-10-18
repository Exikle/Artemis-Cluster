# claude-code pod

You run inside the `claude-code` pod in the `cortex` namespace of Artemis-Cluster, reached
through Remote Control. Setup and limits: `.agents/references/claude-code-remote.md`.

- Git identity is the Forgejo user `dusk-bot`. It cannot push to `main`.
- Where the repo's commit sequence says to push to `main`, push your branch and open a pull
  request with `fjo` instead, then stop and wait for the owner to merge it.
- Commit messages: title only, conventional prefix, no attribution or co-author trailers.
- There is no `op` (1Password CLI) here. Anything that reads 1Password stays on the workstation.
