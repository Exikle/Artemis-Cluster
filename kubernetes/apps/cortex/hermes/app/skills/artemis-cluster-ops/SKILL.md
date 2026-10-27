---
name: artemis-cluster-ops
description: "Rules for any question or change request about the Artemis homelab cluster (Talos + Flux, repo exikle/Artemis-Cluster). Use for 'why is X not working', cluster status, 'review this deployment', 'change X', Flux, Kopiur, tinyauth, MCP or Hermes questions. Says where facts live, which tools to use, what you must not do."
---

# Artemis cluster ops

Facts live in the repo. This skill holds only rules and pointers.

## Find facts

- Read `AGENTS.md` first (use skill `forgejo-gitea-api`; `web_extract` is blocked for git.dcunha.io).
- Then open ONE file from `.agents/references/` that its table names. Never read the whole directory.
- Versions, counts, "which apps use X": grep the tree. Do not answer from memory.

## Symptom to doc

| Symptom                                             | Read                                                                                                         |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| SecurityPolicy `Accepted=False` / `RefNotPermitted` | `identity-stack.md` § Cross-namespace grants (add the namespace to `security/tinyauth/app/resourceset.yaml`) |
| Kopiur / atlas `IndexBlobHealth`, backup failing    | `kopiur.md`                                                                                                  |
| MCP tool missing, 403, unreachable                  | `cortex-mcp.md`                                                                                              |
| Hermes model, skills, cron, memory                  | `hermes.md`                                                                                                  |
| Flux reconcile stuck, `dependsOn`                   | `flux-patterns.md`                                                                                           |
| Storage class, PVC                                  | `storage.md`                                                                                                 |
| CI / OCI artifact not built                         | `ci.md`                                                                                                      |

## Live state

- Use your MCP tools (server `ai-agent`: k8s, flux, searxng, victoria-logs). They are read-only. List the tools; do not guess names.
- The pod has no `kubectl` and no cluster credentials. The MCP tools are the only way in.
- Answer by calling tools. Do not hand the user shell commands to run.
- `forbidden ... mcp-k8s-sa` = RBAC limit, not an outage. Read the answer from logs instead.
- `MCP unreachable after N failures` = cooldown. Wait about 50s, retry.

## Changing the cluster

- `main` is production. No staging cluster.
- You never apply, delete, scale or patch cluster objects. Not through MCP, not through `kubectl`.
- A change request: give the user the diff, or open a PR as dusk-bot (`$FORGEJO_PAT`). Never merge it. Never push `main`.
- Your skills are read-only. To change one, follow skill `skill-change-pr`.
- The human deploy sequence is `.agents/instructions/commit-style.md`. Point to it. Do not restate it.

## Do not "fix" these

- `hermes.dcunha.io` redirects to `/auth/login?provider=self-hosted`. Correct: it means the Pocket-ID login.
- Removed on purpose: Rook-Ceph, SOPS, VolSync, per-app Postgres. Storage classes are `miroir` and `miroir-local` only. Never suggest the removed ones.
- Secrets are 1Password ExternalSecrets (`ClusterSecretStore: onepassword-connect`).
- Parked or blocked work becomes a Forgejo issue, not a note.

## Replies

Follow skill `adhd-friendly-communication`.
