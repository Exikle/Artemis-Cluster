# PR review rules — Artemis-Cluster

GitOps Kubernetes cluster on Talos, reconciled by Flux CD; `main` is production. Only
`kubernetes/` deploys on merge — `terraform/`, `ansible/`, `talos/` and `bootstrap/` are applied
by hand. Condensed from `AGENTS.md`, which wins where they differ.

## Request changes

- A secret in plain text, or SOPS / age encryption. Secrets are ExternalSecrets on the
  `onepassword-connect` ClusterSecretStore.
- A container image tag under `kubernetes/` without an `@sha256:` digest.
- A StorageClass other than `miroir` or `miroir-local`, or `miroir-local` for app data (it is for
  kopiur caches only). Rook-Ceph and VolSync are gone; any reference to them is a blocker.
- In-cluster traffic sent to an external hostname instead of `<app>.<namespace>.svc.cluster.local`.
- A prose comment added under `kubernetes/`.

## Check on every PR

- Major bump: name each breaking change in the release notes that touches this repo's
  config, or say the notes list none.
- A chart that ships CRDs (Flux, cert-manager, kube-prometheus-stack, CNPG): say whether the CRDs
  change.
- `flux-system`, `kube-system`, `network`, storage or Talos changes: label them infrastructure.

## Not a finding

- A missing changelog or release note alone. Say "unverified" and move on.
- Renovate PRs carry no linked issue.
- No evidence of the suspend / apply-ks / user-confirmation test. That happens outside the PR.
- Tag-only images in `talos/`: the Talos installer is pinned by version, not digest.
- `terraform/` changes render nothing in Kubernetes; judge the provider bump on its notes.
- A tag Renovate calls major only because it has no semver (build numbers like `server-b10884`).
