# PR review rules — home-infra

GitOps Kubernetes cluster on Talos, reconciled by Flux CD. `main` is production. Only
`clusters/artemis/kubernetes/` deploys on merge. You apply `terraform/`, `ansible/`, `clusters/artemis/talos/` and `clusters/artemis/bootstrap/` by
hand. These rules are condensed from `AGENTS.md`, which wins where they differ.

## Request changes

- A secret in plain text, or SOPS / age encryption. Secrets are ExternalSecrets on the
  `onepassword-connect` ClusterSecretStore.
- A container image tag under `clusters/artemis/kubernetes/` without an `@sha256:` digest.
- A StorageClass other than `miroir` or `miroir-local`, or `miroir-local` for app data (it is for
  kopiur caches only). Rook-Ceph and VolSync are gone. Any reference to them is a blocker.
- In-cluster traffic sent to an external hostname instead of `<app>.<namespace>.svc.cluster.local`.
- A prose comment added under `clusters/artemis/kubernetes/`.

## Check on every PR

- Major bump: name each breaking change in the release notes that touches the config of this
  repo, or say that the notes list none.
- A chart that ships CRDs (Flux, cert-manager, kube-prometheus-stack, CNPG): say whether the CRDs
  change.
- `flux-system`, `kube-system`, `network`, storage or Talos changes: label them infrastructure.

## Not a finding

- A missing changelog or release note alone. Say "unverified" and move on.
- Renovate PRs carry no linked issue.
- No evidence of the suspend / apply-ks / user-confirmation test. That happens outside the PR.
- Tag-only images in `clusters/artemis/talos/`: the Talos installer is pinned by version, not digest.
- `terraform/` changes render nothing in Kubernetes. Judge the provider bump on its notes.
- A tag that Renovate calls major only because it has no semver (build numbers like `server-b10884`).
