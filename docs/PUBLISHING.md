# Publishing dx02v2

Checklist for publishing a repository with the v2 protections. Follow the order; each item identifies
the command or place to check. Initial creation is distinct from ongoing PR-based delivery.
Fork onboarding starts in the
[central guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md).

## Before publication

- [ ] `HARNESS_STRICT=1 make verify build` and `make e2e` pass in Linux or the devcontainer.
- [ ] Set entry-point executable bits before the first commit; Windows does not infer them:
  `git add --chmod=+x scripts/compose-smoke.sh scripts/deploy-azure.sh scripts/dev-env.sh scripts/e2e-kind.sh scripts/harness.sh scripts/install-tools.sh scripts/render-k8s.sh scripts/repo-guardrails.sh scripts/update-crd-schemas.sh scripts/update-tool-checksums.sh`.
  The `repo-structure` check inspects the Git index.
- [ ] The initial private repository commit has been pushed to `main` and CI is green.
- [ ] `gitleaks git` reports no secrets in complete history; the harness uses this mode whenever commits exist.
- [ ] No real identifiers: `policy-identifiers` passes and a human has reviewed `docs/`.
- [ ] Review the README matrix: `verified locally` becomes `verified in CI` only after green CI.
  Compose evidence remains local; Azure deploy remains `not run in the cloud (v2)` until a `cloud_run_report`.
- [ ] Set repository description and topics, for example
  `gh repo edit maringelix/dx02v2 --description ... --add-topic kubernetes`.
- [ ] Documentation, agent instructions and public templates are in English.

## Publication

- [ ] `gh repo edit maringelix/dx02v2 --visibility public --accept-visibility-change-consequences`
- [ ] Run `scripts/repo-guardrails.sh maringelix/dx02v2`: vulnerability alerts, Dependabot security
  updates, squash-only merges, `delete_branch_on_merge`, issues, a read-only default `GITHUB_TOKEN`
  without PR approval, the `main` ruleset, secret scanning and push protection, private vulnerability
  reporting, approval for workflows from external contributors' fork PRs and the `lab` environment
  with the invoking user as required reviewer and `main` as its only deployment branch.
  The script fails if Actions is disabled and identifies remaining fork-specific settings in
  `FORK.md`. It reports applied settings, skips, notes and failures.

Replace owner/repository arguments for your fork. Repository settings and visibility changes are
explicit maintainer operations.

## Main ruleset (`.github/rulesets/main.json`)

- Blocks deletion and force pushes; requires a PR, with zero approvals for a solo maintainer,
  `dismiss_stale_reviews_on_push` and `required_review_thread_resolution`; squash merges only.
- Strict GitHub Actions checks include `static`, `test`, `images`, `e2e` and `e2e-platform`.
  The complete CI additionally exercises `continuity` and `e2e-platform-small`.
- Administrator bypass uses `pull_request` mode and is reserved for emergencies, such as an external
  failure blocking an urgent security fix. Record the reason in the PR. Ordinary deliveries wait
  for green checks.

## Stable job IDs

Changing a job ID can break protection. Current jobs:

| Workflow | Job | Role |
|---|---|---|
| `ci.yml` | `static` | required static checks |
| `ci.yml` | `test` | required tests |
| `ci.yml` | `images` | required tested-image build and scanning |
| `ci.yml` | `e2e` | required kind end-to-end check |
| `ci.yml` | `e2e-platform` | required app check on the complete local platform |
| `ci.yml` | `continuity` | database continuity evidence; required by release verification |
| `ci.yml` | `e2e-platform-small` | platform proof with bounded small-runner resources |
| `publish-images.yml` | `ref-guard`, `publish` | manual publication of a verified current-main CI artifact |
| `deploy-azure.yml` | `verify-release`, `deploy` | manual release verification/promotion/deploy; `deploy` uses protected `lab` |

## After publication

- [ ] Public `main` CI is green and the badge works; update statuses with that evidence.
- [ ] Set AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID and AZURE_APPCONFIG_ENDPOINT after TX bootstrap/apply; DR additionally uses AZURE_DR_APPCONFIG_ENDPOINT. See RUNBOOK.md.
- [ ] Publish a tested main artifact before cloud deployment; see the signed release flow in the runbook.
- [ ] Record the first cloud run using `cloud_run_report`.
