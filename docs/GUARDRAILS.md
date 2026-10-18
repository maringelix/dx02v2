# dx02v2 guardrails

A guardrail combines a rule with enforcement, automated where possible. This document names rules,
enforcement and limits. Types: blocking (fails harness/CI), alert (notifies), process (human/agent
discipline). IDs remain stable, including historical CUSTO/MUD identifiers.

## Rules

| ID | Rule | Reason | Enforcement | Type |
|---|---|---|---|---|
| SEC-01 | No committed secrets | public repository; history persists | gitleaks, harness/pre-commit | blocking |
| SEC-02 | No real identifiers: all-zero subscription/tenant/client/object GUIDs, tx02v2 suffix 00000000, placeholder 12-digit ID123456789012, example.com emails, private/RFC5737 IPs | avoid exposing people/subscriptions/identities | policy-identifiers | blocking |
| SEC-03 | Random runtime local credentials with dev-env.sh/e2e-kind.sh; ignored .env; example placeholders; no Secret objects in app manifests | no copied default passwords | .gitignore, gitleaks, contract-app | blocking |
| SEC-04 | GitHub→Azure uses OIDC deploy managed identity, immutable lab subject with owner/repository IDs; no creds/client-secret/interpolated credential inputs; CI cannot authenticate to cloud | no service-principal secrets; re-registered names inherit no trust | policy-workflows; repo-guardrails.sh checks sub | blocking |
| SEC-05 | Admin token >=32 characters, constant-time comparison; absent token gives503 admin_disabled | prevent weak tokens/timing disclosure | config.ts; admin-auth/config/messages tests | blocking |
| SEC-06 | Redact Authorization/Cookie/password/token; deploy masks App Configuration identifiers in Actions logs | no secrets/IDs in public logs | logger.ts/logger test; deploy-azure.sh | blocking/process |
| SEC-07 | Azure DB TLS trusts only three contract roots, downloaded and SHA-1-thumbprint-verified; lab requires verify-full | altered download cannot become trusted | deploy-azure.sh, contract-app, config test | blocking |
| SEC-08 | Integration tests recreate tables only with DB_NAME ending _test; deploy-local only kind-tx02v2-local | operator DB_* or context may target other work | requireTestDatabase in integration/helpers.ts, test-database/test:api; require_lab_context | blocking |
| SEC-09 | Smoke sends tokens only through HTTPS/localhost; otherwise omits only the credentialed call. Cloud deploy never reads/sends the token, including core HTTP | public ingress must not leak credentials | smoke.mjs, deploy-azure.sh | blocking |
| SEC-10 | k8s.sh rm -rf requires nonempty destination, `${dest:?}`/`${tmp:?}` | empty variables cannot broaden deletion | policy-app | blocking |
| SUP-01 | Tool versions/SHA256 pinned; mismatch fatal | supply chain | install-tools.sh, checksums.txt | blocking |
| SUP-02 | Actions use40-character SHA and # vX.Y.Z | tags move; v1 used nonexistent azure/login SHA | policy-workflows | blocking |
| SUP-03 | Digest-pin Dockerfile/Compose/manifest/CI/kind/devcontainer images/features; no latest | March2026 malicious Trivy latest incident | policy-images | blocking |
| SUP-04 | Exact npm versions, synchronized lock | reproducible builds | version-consistency/npm-ci; strict mode always npm ci | blocking |
| SUP-05 | Install Trivy through install-tools.sh only, never trivy-action/setup-trivy | March2026 incident GHSA-69fq-xp46-6x23 | policy-workflows | blocking |
| SUP-06 | No fixable HIGH/CRITICAL image CVEs | do not publish known fixable vulnerabilities | trivy-image:api/web | blocking |
| SUP-07 | Match Node major across .nvmrc/engines/builder, PostgreSQL digest across Compose/CI/kind/harness, Kubernetes minor across kind/kubectl/schemas | reject partial upgrades | version-consistency | blocking |
| SUP-08 | Monthly npm/docker/actions/pre-commit Dependabot; grouped minor/patch, separate major | detect drift | dependabot.yml | alert |
| SUP-09 | Generate GatewayAPI/AGC schemas from pinned ALB CRD image; no hand edits; separately pin experimental waypoint schemas | validate installed interface | crd-schemas, update-crd-schemas.sh --check | blocking |
| K8S-01 | Strict kubeconform with pinned Kubernetes 1.36, ALB GatewayAPI1.5.1 standard, alb.networking.azure.io/v1, ExternalSecret; full waypoint experimental schemas | invalid manifests cannot reach cluster | kubeconform | blocking |
| K8S-02 | Restricted Pods: numeric non-root UID, RuntimeDefault, no escalation, drop ALL, read-only root, no SA token/hostPath/host namespaces, requests/memory limits | least privilege, enforced app namespace | contract-app; kind rejects privileged Pod | blocking |
| K8S-03 | Default-deny; allow approved DNS, web→api3000, API→local PostgreSQL 5432/Azure subnet, AGC subnet→web8080/api3000, monitoring metrics; one CIDR/rule, no except | prevent lateral traversal; v1 omitted from/allowed arbitrary egress | contract-app, kind probes | blocking |
| K8S-04 | Azure overlays use only deployer-writable kinds and approved annotations including alb.networking.azure.io/alb-id on Gateway; all objects part-of dx02v2; TX owns namespace/RBAC | least-privilege deploy | contract-app, kubectl auth can-i | blocking |
| K8S-05 | No HIGH/CRITICAL rendered-manifest/Dockerfile findings | secure configuration | trivy-config | blocking |
| K8S-06 | Entry through dx02v2 Gateway/HTTPRoute (/api→api3000, /→web8080), /healthz and /readyz policies, optional whole-Gateway WAF; full adds HTTPS/HTTP redirect | no uncontracted exposure | contract-app | blocking |
| APP-01 | trust proxy is TRUST_PROXY_HOPS count, never true; limiter uses req.ip | forged XFF cannot bypass | policy-app, AGC rate-limit tests, forged-XFF429 smoke | blocking |
| APP-02 | Same-origin without CORS middleware/pre-storage HTML escaping; UI renders text | avoid v1 localhost-only CORS | policy-app; tests/smoke preserve literal <b> | blocking |
| APP-03 | No inline UI style/scripts; CSP script-src self/style-src self; no sourcemaps | prevent v1 unsafe-inline/public maps | policy-app, smoke, image-policy:web | blocking |
| APP-04 | nginx security headers on responses/assets/errors; HSTS only HTTPS; server_tokens off | v1 preload-HSTS over HTTP | policy-app, smoke | blocking |
| APP-05 | JSON error.code/message/requestId, no internals, for400/413/404/415/429/500/503 | v1 returned500 for everything | integration/smoke | blocking |
| APP-06 | pino-only JSON logs with request ID per line | structured/redacted logs | policy-app forbids console.*, eslint no-console | blocking |
| APP-07 | Browser admin token only in memory | no localStorage/cookie credentials | policy-app | blocking |
| APP-08 | Distroless API without shell/npm/npx/corepack; both images numeric non-root uid:gid and OCI source/revision | reduce attack surface | policy-images, image-policy:api/web, hadolint | blocking |
| APP-09 | API >=80% lines/>=70% branches, web >=70% lines on real code | no expect(true).toBe(true) substitutes | Vitest thresholds | blocking |
| APP-10 | Never edit applied migration; schema_migrations checksum; transaction per migration, advisory lock | concurrent replicas/initContainers cannot corrupt schema | migrate.ts, migrations tests | blocking |
| APP-11 | Versioned TX contract; coordinated interface PRs | both sides evolve together | CONTRACT.md, contract-app | process |
| APP-12 | api/web/e2e parity across all three apps or explicit cloud-specific justification | fair comparison | PR template, MAINTENANCE routine | process |
| APP-13 | No unrelated-cloud implementation; README/ARCHITECTURE/CHANGELOG may compare family | describe actual behavior | policy-cloud, contract-app | blocking |
| CUSTO-01 | Explicit workflow_dispatch release/deploy; validated ci_run_id/release_run_id, protected lab; GitOps contents:write only deploy | deliberate intent/bounded push rights | policy-workflows, publish-gitops.sh | blocking |
| CUSTO-02 | Same-day TX destroy, leftovers, cloud_run_report | AGC/WAF, AKS, PostgreSQL charge while provisioned | RUNBOOK.md | process |
| CUSTO-03 | Never replace ACR tag; verify promoted image IDs/digests, platform/RBAC | avoid substitution/waste | deploy-azure.sh | blocking during deploy |
| CI-01 | Harness is CI; checks in harness.sh, jobs call make targets | local reproducibility | PR review, ci.yml | process |
| CI-02 | No continue-on-error:true, `\|\| true`, `\|\| echo` workflows | meaningful gates; v1 lint only ran npm install | policy-workflows | blocking |
| CI-03 | Top-level contents:read, timeout/concurrency, ubuntu-24.04, persist-credentials:false | least privilege/predictability | policy-workflows | blocking |
| CI-04 | Strict CI makes SKIP fail, requires pinned versions, no cloud secrets | no silent skips/missing-secret failures | ci.yml, harness | blocking |
| CI-05 | e2e loads images job's exact built/scanned artifact | cluster bytes match scanned bytes | ci.yml | process |
| CI-06 | Weekly Monday06:00UTC CI | detect new CVEs, expiry, broken URLs | ci.yml | alert |
| MUD-01 | Main ruleset requires PR, strict static/test/images/e2e/e2e-platform, no force push | harness every change | ruleset/main.json, repo-guardrails.sh | blocking after publication |
| MUD-02 | Scanner exceptions require statement/expired_at within approximately7months | bounded review | trivyignore-policy | blocking |
| MUD-03 | Conventional Commits, one topic/PR, Unreleased CHANGELOG | readable history | PR template | process |
| DOC-01 | English-only docs/README, exact evidence labels, no self-ratings, UTF-8/LF | prevent v1 false claims/UTF-16 | repo-structure, review | blocking |
| DOC-02 | Docs updated with code | prevent stale instructions | PR template | process |
| AGT-01 | Never mutate cloud without explicit human request for task | cost/security | AGENTS.md | process |
| AGT-02 | Never weaken gates/coverage or add unjustified/unbounded ignores | meaningful harness | AGENTS/checks above | process |
| LOC-01 | Local app through GitOps/ArgoCD/AppProject dx02v2 only, no direct apply | one owner; v1 had two | deploy-local.sh, gitops probe | blocking in e2e-platform |
| LOC-02 | Local STRICT mTLS, identity AuthorizationPolicy, NetworkPolicy with HBONE/ambient kubelet probes | identity, not IP alone | local-platform contract-app, mesh probe | blocking |
| LOC-03 | Alerts use exported app/KSM series with promtool tests | v1 used nonexistent series | promtool-rules, observability | blocking |
| AGT-03 | Stop/ask for AGENTS-listed situations | costly decisions stay human | AGENTS.md | process |

Release workflows request GitHub OIDC for Sigstore signing, separately from cloud credentials.
CI itself receives neither cloud secrets nor cloud authentication.

## Exceptions

A scanner exception must:

1. Represent a deliberate tradeoff or a finding currently impossible to fix, not a hidden defect.
2. Add .trivyignore.yaml id, narrowest paths/purls, statement (acceptance and compensating
   controls), and expired_at within approximately seven months.
3. Be explained in the PR. trivyignore-policy rejects missing reasons/dates, expired entries
   and excessive durations; Trivy no longer applies an expired entry.

Other exclusions are fixed and explained in checks. policy-identifiers excludes package-lock.json,
tools/checksums.txt and generated deploy/k8s/schemas (official hashes/examples verified by
crd-schemas), and permits an API-test UUID. policy-cloud permits family comparisons in
README, ARCHITECTURE and CHANGELOG.

Trivy exception baseline checked 2026-10-11: none. The image gate uses --ignore-unfixed.
Unfixed and LOW/MEDIUM CVEs do not fail builds; full counts remain in trivy-image:* summaries.

## Limits

- Nothing in v2 ran in Azure: deploy, ESO/Key Vault, AGC Gateway/WAF, PostgreSQL verify-full and
  RBAC preflight were rendered/validated/stub-tested with az/kubectl/kubelogin/docker, not Azure.
- kind e2e proves kindnet/kube-network-policies, not AKS Cilium; AGC/PostgreSQL subnet CIDRs
  exist only in cloud overlays.
- Write rate limiting is in memory per API replica: N replicas permit up to N times the limit.
- Admin token is one shared secret, no users/automatic rotation. Restart API Pods after
  Key Vault/ESO rotation.
- Cloud smoke never reads/sends the admin token. Deployer RBAC can read app Secrets; access to
  the identity is sensitive even when scripts avoid printing credentials.
- Current ACR uses Standard/ABAC-scoped repositories and verified promotion attestations/digests.
  Historical Basic/AcrPush access did not prove who published a tag. Deployment refuses tag
  replacement; real registry/admission behavior remains a cloud acceptance test.
- Azure CLI tokens acquired at deployment start last roughly one hour; longer runs can fail later calls.
- Trivy --ignore-unfixed does not block unfixed CVEs; weekly CI reevaluates them.
- Core Azure intentionally uses HTTP; full configures public HTTPS/redirect. Local kind uses lab-CA
  HTTPS; local proof does not establish public certificate issuance.
- Before the first commit gitleaks scans Git-visible tracked/unignored files; afterward it also
  scans full history.
- Executable-bit checks cover files already in the Git index.

## Verification

```bash
make tools                       # pinned .tools binaries
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list           # every check and stage
```
