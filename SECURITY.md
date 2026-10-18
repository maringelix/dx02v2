# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security > Report a vulnerability** on this repository (private
vulnerability reporting is enabled when the repository is public, see `docs/PUBLISHING.md`). Do not
open a public issue. Never include credentials, admin tokens, subscription, tenant or object IDs or
IP addresses; use placeholders.

This is a personal educational project: reports are handled on a best-effort basis, with no response
time guarantee and no bug bounty.

## Supported versions

Only the latest commit on `main`. There are no releases yet.

## What this repository does to stay safe

The rules, where each one is enforced and the known limits are in
[docs/GUARDRAILS.md](docs/GUARDRAILS.md). In short:

- The harness (`make verify`, `make build`, `make e2e`, also the CI) runs gitleaks, eslint with
  type-aware rules, hadolint, actionlint, shellcheck, kubeconform (with schemas generated from the
  pinned Application Gateway for Containers CRDs), trivy (config and images, HIGH/CRITICAL with a fix
  available) and policy checks that block real identifiers and GUIDs, unpinned actions and images,
  and the regressions found in v1.
- API: input validated with zod (control characters rejected, text stored as received and rendered
  as text by the UI), JSON errors without internals, `trust proxy` as a hop count so spoofed
  `X-Forwarded-For` entries cannot bypass the per-client write rate limit (tested, including the
  comma-only format that Application Gateway for Containers appends), admin token compared in
  constant time and never logged, credentials redacted from logs.
- Web: strict Content-Security-Policy without inline scripts or styles, security headers on every
  response including static assets, HSTS only for requests that arrived over HTTPS (there is no
  HTTPS listener on Azure yet, so no HSTS is sent there).
- Containers run as numeric non-root users with a read-only root filesystem; the API runtime image
  is distroless (no shell, no npm). Kubernetes: Pod Security `restricted`, default-deny
  NetworkPolicies (enforcement proven on kind), no service account tokens.
- GitHub Actions reach Azure only through OIDC with the managed identity `dx02v2-gha-deploy`
  (federated credential for the environment `lab`); there are no client secrets. Runtime secrets on
  Azure come from Key Vault through External Secrets; the deploy verifies the SHA-1 thumbprints of
  the PostgreSQL root CAs before trusting them, and never overwrites an existing image tag in ACR.
- Every harness tool is pinned by version and SHA256; actions by commit SHA; images by digest; npm
  dependencies by exact version and a committed lockfile.

## Known limits

The Azure deploy has never run (`not run in the cloud (v2)`). The admin token is a single shared
bearer token (no users, no rotation automation). The write rate limit is kept in memory per API
replica, so the effective limit grows with the number of replicas. ACR Basic tags are mutable: the
deploy never pushes over an existing tag but cannot prove who pushed it. The kind e2e proves
NetworkPolicy enforcement with kindnet, not with the Cilium dataplane of AKS. See the "Limites"
section of docs/GUARDRAILS.md.
