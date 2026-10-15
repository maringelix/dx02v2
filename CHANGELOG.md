# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Security

- The integration tests drop and recreate tables (`messages`, `schema_migrations`), and with
  `DB_HOST` set the harness ran them against whatever database `DB_*` pointed at, such as the
  development database of `docs/RUNBOOK.md`. They now refuse a `DB_NAME` that does not end in `_test`,
  both in `api/test/integration/helpers.ts` (`requireTestDatabase`, new unit test `test-database`) and
  in `scripts/harness.sh`; `docs/RUNBOOK.md` shows a separate `dx02v2_test` database.
- `scripts/deploy-local.sh` refuses any kube context but `kind-tx02v2-local`: a cluster of whoever runs
  it, left in the current context, never receives the deploy.
- `deploy/local/tx02v2.ref` follows tx02v2 to the commit where its scripts act only on the lab.

### Changed

- `deploy/local/tx02v2.ref` follows tx02v2 to `c92def2` (tx02v2#10, the debts round of the roadmap).
- Comments, script messages and docs say "the contract" or point to `docs/CONTRATO.md` instead of
  "contract v1": the contract has been at version 2 since round 1 (roadmap S.8); the README says that HTTPS on the gateway listener is outside contract v2.
- The family table of both READMEs links the family hub `tx00v2` (roadmap, family guardrails,
  cross-repo checks).
- `scripts/repo-guardrails.sh` also turns issues on (the issue forms) and requires approval for
  workflow runs from forks of external contributors; the reviewer of the `lab` environment is the gh
  user that runs it. It fails while the workflows of a fork are still disabled and notes a renamed
  repository or a CODEOWNERS that names someone else (tested against a stub gh, then applied to the
  original repository and read back with `gh api` on 2026-10-14).
- The ruleset requires the CI job `e2e-platform` too (`.github/rulesets/main.json`, applied with
  `scripts/repo-guardrails.sh`): the local lab is a merge gate, not only maintainer discipline.
- README status matrix: repository settings as code are applied (read back with `gh api` on
  2026-10-13), no longer `planned`.

### Fixed

- `scripts/deploy-local.sh` waits for the Argo CD sync of the commit it pushed: on a redeploy the
  Application was still Synced and Healthy on the previous commit, and the script went on too early.

### Added

- Traces with OpenTelemetry, ported from `dx01v2` (same `api/` code, names only): a SERVER span per
  request (named after the route) and a CLIENT span per PostgreSQL query inside it (parameterized SQL
  only), W3C `traceparent` continued, OTLP/HTTP to `OTEL_EXPORTER_OTLP_ENDPOINT` (off without it).
  Manual spans with `@opentelemetry/api` 1.9.1, `sdk-trace-node` 2.12.0, `exporter-trace-otlp-http`
  0.223.0, `resources` 2.12.0 and `semantic-conventions` 1.43.0, no ESM loader hook; `/healthz` and
  `/readyz` untraced; the shutdown flush takes at most 5 s and never fails because of the Collector.
  Log lines carry `trace_id`/`span_id`, and `/metrics` speaks OpenMetrics with the trace id as an
  exemplar. New unit and integration tests (`telemetry`, `tracing`).
- Contract version 2 with tx02v2: the overlay `local-platform` sends the traces to the Collector of the
  local contract (`tracing.otlp-endpoint`, required by `scripts/deploy-local.sh`), the component `azure`
  to `opentelemetry-collector.observability.svc:4318` (`not run in the cloud (v2)`; the Collector of
  tx02v2 writes them to Application Insights). NetworkPolicies widened only for that: API → Collector
  (4318) and Gateway → Collector (4317, its spans), both over HBONE (15008) in the mesh;
  `contract-app` asserts both.
- `make e2e-platform` has 18 probes (was 13): one trace in Tempo from the Gateway to the query, the
  `trace_id` in the log lines in Loki and in an exemplar in Prometheus; a zero-downtime rollout; 200 ms
  of latency between the API and PostgreSQL (NetworkChaos), every read passes and the trace shows the
  delay in the query span.
- `FORK.md`: forking the app step by step (the steps shared with tx02v2, the local runs, testing against
  your own tx02v2, deploying to your own cloud account, troubleshooting), linked from both READMEs and
  CONTRIBUTING.md; the harness requires it.
- `scripts/e2e-platform.sh` takes `TX02V2_REPO` (an https URL; the CI job `e2e-platform` passes the
  repository variable of the same name): a fork can test against its own tx02v2. A pinned commit that is
  not in that repository fails with a clear message.
- The devcontainer declares 4 CPUs and 8 GB (the platform e2e runs the whole local lab).
- The app on the full local platform of tx02v2 (docs/LAB_LOCAL.md), ported from `dx01v2`: overlay
  `local-platform` (Istio Gateway with HTTPS from cert-manager, HTTPRoutes, ExternalSecrets from
  `local-secrets`, HPA, `PeerAuthentication` STRICT, `AuthorizationPolicy` by identity, NetworkPolicies
  with HBONE, ServiceMonitor, five alert rules, a Grafana dashboard); `scripts/deploy-local.sh` (images
  to the lab registry, GitOps repository, Argo CD Application); `scripts/e2e-platform.sh` with probes
  (smoke over HTTPS through the emulated load balancer, mesh, observability, Trivy reports, HPA,
  database backup + restore drill, Argo CD self-heal, chaos experiment). Harness checks
  `promtool-rules` (tool promtool 3.15.0) and `platform-e2e` (stage `platform`, `make e2e-platform`,
  CI job `e2e-platform`); `contract-app` asserts the new overlay. The platform e2e is
  verified locally (13 probes on the tx02v2 local lab, from scratch) and in CI.
- `e2e/smoke.mjs`: `SMOKE_EDGE=istio` for the Istio Gateway of the local platform, which routes `/api`
  straight to the API like AGC and keeps an external `X-Request-Id` like nginx (Azure-specific: the
  `dx01v2` smoke accepts both API CSPs and has no edge modes).

- Initial v2 of the Azure application lab, started from every tracked file of `dx01v2` at commit
  `22e69c4` (the same app on both clouds, docs/ARQUITETURA.md) and adapted to the AKS cluster of
  `tx02v2` (contract v1, docs/CONTRATO.md):
  - Azure path: `deploy/k8s/components/azure` and `overlays/azure` (Gateway `dx02v2` on Application
    Gateway for Containers in "bring your own" mode, HTTPRoute `/api` → api:3000 and `/` → web:8080,
    one HealthCheckPolicy per Service, ExternalSecrets from Key Vault through the ClusterSecretStore
    `azure-key-vault`, `verify-full` TLS with the ConfigMap `azure-pg-ca`, HPA 2-4 at 70 % CPU,
    NetworkPolicies limited to the AGC and PostgreSQL subnets) and `components/azure-waf` /
    `overlays/azure-waf` (WebApplicationFirewallPolicy on the Gateway when `waf/policy-id` is not
    `none`), rendered from `params.example.env` in CI.
  - `scripts/deploy-azure.sh` and the `deploy-azure` workflow (`workflow_dispatch` only, environment
    `lab`, `azure/login` v3.1.0 with OIDC): reads the 15 App Configuration keys of the contract and
    checks the fixed ones, fetches the kubeconfig with `az aks get-credentials` + kubelogin, checks the
    platform API groups and RBAC before building, never overwrites an existing ACR tag, verifies the
    SHA-1 thumbprints of the three PostgreSQL root CAs, applies the overlay, waits for the
    ExternalSecrets, rollouts, Gateway and WAF policy, and runs the smoke test through AGC.
  - Kubeconform schemas for Gateway API v1.5.1 (standard) and `alb.networking.azure.io/v1`,
    generated by `scripts/update-crd-schemas.sh` + `scripts/crd-to-jsonschema.mjs` from the CRDs image
    of ALB Controller 1.12.2 (pinned by digest); harness check `crd-schemas` keeps them reproducible.
  - Harness: kubelogin 0.2.21 as a pinned tool; checks `policy-cloud` (nothing of the AWS path may
    remain) and `crd-schemas`; Azure contract assertions in `scripts/check-manifests.mjs` and
    `contract-app` (Gateway, HTTPRoute, HealthCheckPolicy, WAF policy, ExternalSecrets,
    NetworkPolicies, labels, annotations, deployer kinds, App Configuration keys and CA thumbprints);
    `policy-identifiers` also rejects real-looking GUIDs and real tx02v2 name suffixes;
    `policy-workflows` checks the deploy workflow (no service principal secrets, no inputs,
    `id-token: write` only in the deploy job); `repo-structure` rejects UTF-16 and BOMs;
    `image-policy:web` rejects sourcemaps.
  - Brazilian Portuguese docs for the Azure pair: architecture (dx01v2 ↔ dx02v2 and v1 → v2 tables),
    contract v1 (app side, with implementation notes for tx02v2), runbook, guardrails, harness,
    sustainment (ALB Controller, Gateway API, kubelogin, AKS calendar, parity routine), publication.

### Changed (relative to dx01v2)

- Names: `dx01v2` → `dx02v2` and `tx01v2` → `tx02v2` everywhere they identify the pair (namespace,
  images, kind cluster, compose project, `/api/info` name, logger service, database
  `application_name`, `WWW-Authenticate` realm, advisory lock key, page title and footer, npm
  package names). No behaviour change.
- `e2e/smoke.mjs`: the AWS-only `SMOKE_BEHIND_WAF` flag is replaced by `SMOKE_EDGE` (`nginx`, the
  default for compose and kind; `agc` for Azure). The `/api` Content-Security-Policy assertion is now
  exact per edge instead of accepting either policy; behind AGC the smoke expects the GUID that AGC
  assigns as `X-Request-Id`. The 70 KB body gets 413 on both edges (the Azure WAF policy inspects up
  to 128 KB, so the API answers itself). Compose and kind keep the same assertions.
- One integration test case more in `api/test/integration/rate-limit.test.ts`: the comma-only
  `X-Forwarded-For` format that Application Gateway for Containers appends. One test value changed
  (`/etc/azure-pg-ca/ca.pem` in `api/test/unit/config.test.ts`). Comments that named AWS services now
  name the Azure ones.
- Deploy order: every Azure token is acquired before the image builds (the GitHub OIDC assertion lives
  5-10 minutes).
- The harness writes the vitest coverage reports to `HARNESS_WORK_DIR` instead of `api/coverage` and
  `web/coverage` (nothing generated by the harness lands in the repository; the gates are the same).

### Removed (relative to dx01v2)

- The AWS path: `deploy/k8s/components/aws*`, `deploy/k8s/overlays/aws*`, `scripts/deploy-aws.sh`,
  `.github/workflows/deploy-aws.yml`, and the AWS contract checks and docs.

### Changed (after the first push)

- The CI (`static`, `test`, `images`, `e2e`) ran green on GitHub: the README status matrix now says
  `verified in CI` for those rows (the compose row stays `verified locally`).
- docs/CONTRATO.md mirrors the contract v1 of tx02v2: the Role lists the real AGC CRD plurals
  (`healthcheckpolicy`, `webapplicationfirewallpolicy`), and the implementation notes are recorded as
  incorporated (frontend through `spec.addresses`, /24 AGC subnet, x86-64 nodes, kubelet `AcrPull`,
  the three Azure roles of `app_deployer_principal_ids`). docs/RUNBOOK.md and docs/SUSTENTACAO.md
  follow.
- The README family table and AGENTS.md link the Google Cloud pair (`tx03v2`, `dx03v2`), now public;
  `dx03v2` runs this same application (AGENTS.md rule 6 and the parity routine of
  docs/SUSTENTACAO.md, section 5.10, name it).
- One integration test case more, ported from `dx03v2` for parity: the
  `[<supplied>,]<client-ip>,<lb-ip>` `X-Forwarded-For` of the Google Cloud Application Load Balancer
  with `TRUST_PROXY_HOPS=2` (`api/test/integration/rate-limit.test.ts`, now identical in dx02v2 and
  dx03v2).
- Dependabot ignores major bumps of the `node` build image (it follows `.nvmrc` and `engines.node`;
  a `node:26` bump fails `npm ci` with EBADENGINE).
