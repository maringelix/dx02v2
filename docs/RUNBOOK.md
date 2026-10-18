# dx02v2 runbook

Develop/test the app with npm, Compose and kind, then publish it to tx02v2 AKS.
Start with the [central getting-started guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md).
The free local path is verified locally/in CI as listed in README; Azure
deployment remains `not run in the cloud (v2)`. Your cloud run supplies evidence.

## 1. Local prerequisites

- Docker/devcontainer (Docker-in-Docker), or Linux/Ubuntu WSL2 with Docker,
  bash>=4.4, Node 24 (.nvmrc), curl/unzip/xz/git/make.
- make tools installs pinned Trivy, hadolint, actionlint, shellcheck,
  kubeconform, Gitleaks, kind, kubectl and kubelogin under .tools/.
- Ports: Compose8080 (WEB_PORT, loopback), dev PostgreSQL 15432 (loopback),
  Vite 5173 (loopback), dev API 3000/metrics9464 (all interfaces).

## 2. npm workspace development

One root package-lock.json; workspaces api/web.

```bash
npm ci
# Disposable PostgreSQL 17; random password/token exist only in this shell session.
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx02v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx02v2 -e POSTGRES_USER=dx02v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx02v2 DB_USER=dx02v2
node api/src/migrate.ts           # Node 24 executes TypeScript directly
npm run dev --workspace api       # API 3000, metrics9464, reload on save
npm run dev --workspace web       # another terminal; 127.0.0.1:5173, /api -> :3000
docker rm -f dx02v2-dev-pg        # after finishing
```

Useful commands: npm run lint/typecheck/format/build. Web tests:
`npm run test:coverage --workspace web`. API tests use DB_* and **drop/recreate
tables**; they reject database names not ending in _test:

```bash
docker exec dx02v2-dev-pg createdb -U dx02v2 dx02v2_test
DB_NAME=dx02v2_test npm run test:coverage --workspace api
```

Strict verify starts disposable PostgreSQL when DB_HOST is unset; exported DB_*
selects that database and must use _test. In the shell above, use
`env -u DB_HOST HARNESS_STRICT=1 make verify`.

## 3. Compose stack (dx02v2-dev)

```bash
scripts/dev-env.sh                                # random .env secrets, mode600
docker compose -p dx02v2-dev up -d --build --wait # db -> migrate -> api -> web
scripts/compose-smoke.sh                          # smoke at http://127.0.0.1:8080
docker compose -p dx02v2-dev down -v              # containers/network/database volume
```

- Only web publishes `127.0.0.1:${WEB_PORT:-8080}`; API/database use internal networks.
- Read-only root filesystems, cap_drop ALL, no-new-privileges.
- Page admin mode accepts .env ADMIN_TOKEN, stored only in tab memory.
- Rotate with dev-env.sh --force then down -v; the volume retains its old password.
- Another port: WEB_PORT=18080 scripts/dev-env.sh --force.

## 4. kind end to end (make e2e)

```bash
make tools
make e2e                        # create dx02v2-e2e, test, delete cluster
KEEP_CLUSTER=1 make e2e         # keep for investigation
kind get kubeconfig --name dx02v2-e2e > /tmp/dx02v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx02v2-e2e.kubeconfig kubectl -n dx02v2 get pods,svc,networkpolicy
kind delete cluster --name dx02v2-e2e
```

e2e-kind.sh builds dx02v2-api:e2e/web:e2e, creates digest-pinned kind 1.36.4,
loads images, generates Secrets, applies local overlay, waits for rollouts,
requires privileged Pod rejection, runs smoke through svc/web port-forward,
and probes NetworkPolicies with disposable Pods. Failure diagnostics:
$TMPDIR/dx02v2-harness/e2e-diagnostics.

## 5. Azure prerequisites

> Cost: AGC/WAF is the largest tx02v2 item (historical eastus2 reference
> USD0.279/hour, USD0.155 without WAF, Retail Prices API 2026-10-11), plus
> AKS/PostgreSQL. Read tx02v2 COSTS.md and current calculator. Destroy the same day.

1. Complete TX bootstrap/apply/platform: ALB Controller/GatewayClass
   azure-alb-external, ESO/store azure-key-vault, dx02v2 namespace/deployer Role/
   RoleBinding. TX adds the deploy identity object ID. Laptop deployers also
   need app_deployer_principal_ids and section 6 Azure roles.
2. Public fork with repo-guardrails applied: lab required reviewer/main only.
   Federation trusts immutable
   `repo:<owner>@<owner-id>/dx02v2@<repository-id>:environment:lab`,
   with matching bootstrap numeric IDs.
3. Configure section 6 variables. No static Azure client-secret is used.
4. Full requires matching full platform, sized nodes, delegated public DNS/CNAME
   and ready ACME certificate. TX RUNBOOK owns installation, Velero key escrow
   and FinOps/pricing prerequisites.
5. DR additionally requires the secondary contract output and fencing/promotion
   procedure in both CONTINUITY runbooks; target selection does not promote data.

## 6. GitHub variables and Azure roles

Settings > Secrets and variables > Actions > **Variables**. These values appear
in logs; do not store credentials/private operator information here. Workflow
validates formats first and masks identity IDs.

| Variable | Example | Use |
|---|---|---|
| AZURE_CLIENT_ID | 00000000-0000-0000-0000-000000000000 | dx02v2-gha-deploy managed identity clientID, bootstrap output |
| AZURE_TENANT_ID | 00000000-0000-0000-0000-000000000000 | Entra tenant |
| AZURE_SUBSCRIPTION_ID | 00000000-0000-0000-0000-000000000000 | Must match contract agc/id subscription |
| AZURE_APPCONFIG_ENDPOINT | https://tx02v2-lab-00000000.azconfig.io | Primary contract endpoint, TX output |
| AZURE_DR_APPCONFIG_ENDPOINT | TX dr_appconfig_endpoint output | Required only target=secondary |

TX assigns Container Registry Repository Writer with separate ABAC conditions
for dx02v2/api/web, AKS Cluster User on the cluster, App Configuration Data Reader
on the store. Human app_deployer_principal_ids receive the same roles plus
RoleBinding (CONTRACT.md). No Key Vault role is granted to the deployer.
Infrastructure/operator secrets belong in TX, including ranges/admins/Slack/
Velero password; application credentials stay in Key Vault/ESO.

## 7. Publish, promote and deploy

First run **publish-images from main**, with ci_run_id pointing to a successful
current-main push ci.yml run; wait for signed publication. A PR run is insufficient.
Then run deploy-azure from main with release_run_id equal to the successful
publish-images run ID. It verifies source CI, SBOMs and attestations before lab
approval and rechecks after approval before Azure authentication.

Choose platform_profile=core|full, deploy_mode=auto|gitops|push,
target=primary|secondary. Auto uses GitOps when Application dx02v2 exists,
otherwise direct apply; permission/connection failures are not treated as absence.
Full requires TX full, ambient waypoint and signature policy. Workflow promotes
and attests final ACR images before deployment. Cloud homologation follows
construction/integration; delivery of the planned PRs does not itself prove runtime.

```bash
gh workflow run publish-images.yml --repo <owner>/dx02v2 --ref main -f ci_run_id=<successful-main-CI-run-ID>
# Wait for successful publication, then:
gh workflow run deploy-azure.yml --repo <owner>/dx02v2 --ref main \
  -f release_run_id=<publisher-run-ID> -f platform_profile=core -f deploy_mode=auto -f target=primary
```

The workflow promotes verified images and signs/verifies an attestation binding
source/destination digests. Deployment then:

1. Verifies publisher/source CI and six release-required checks (static, test,
   images, e2e, e2e-platform, continuity), SBOM hashes, provenance and SPDX.
   CI additionally runs e2e-platform-small.
2. Reads 17 tx02v2/lab keys, checking group/cluster/secrets/DNS/formats.
3. Gets temporary kubeconfig and preflights namespace API groups/RBAC; GitOps
   also requires update permission on Application dx02v2.
4. Checks approved GHCR image, transfers without rebuild, verifies imageID,
   refuses a commit tag pointing to another image. Registry manifest digests
   may change; promotion attestation binds both.
5. Creates azure-pg-ca from three verified roots; renders/validates azure,
   azure-waf, azure-full or azure-waf-full. Sets real live kustomize values and
   publishes revision in gitops/azure or gitops/azure-dr; push applies directly.
6. Waits Synced/Healthy at the published commit, ExternalSecrets/rollouts and
   correct Deployment digests.
7. Waits Gateway Programmed and optional WAF Accepted; runs smoke through AGC.
   Full uses public HTTPS and HTTP 301 redirect (secondary checks chosen Gateway
   with --resolve/SNI before DNS cutover); core uses frontend HTTP.
   The script neither reads nor sends the admin token.

Full's internal mesh-demo route demonstrates 80/20 stable/canary, bounded retries
and canary ejection after failures. The deploy job does not automatically run
this lesson; inspect app logs/TX checks to study it.

For manual laptop execution, obtain/extract the verified release artifact and set
RELEASE_DIR, RELEASE_RUN_ID, GITHUB_REPOSITORY, GITHUB_ACTOR and GH_TOKEN with
actions:read/attestations:read/packages:read. Authenticate Docker to GHCR and Git
for publishing gitops/azure; az login/select dedicated subscription, then:

```bash
make tools
printf '%s' "$GH_TOKEN" | docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin
AZURE_APPCONFIG_ENDPOINT=https://tx02v2-lab-<suffix>.azconfig.io scripts/deploy-azure.sh
```

Without Argo CD, set DEPLOY_MODE=push. Manual full deployment must use digests
already attested by the main workflow; the local script does not issue signatures.

## 8. Inspect

```bash
az aks get-credentials --resource-group tx02v2-lab --name tx02v2-lab --file /tmp/dx02v2-lab.kubeconfig
kubelogin convert-kubeconfig -l azurecli --kubeconfig /tmp/dx02v2-lab.kubeconfig
export KUBECONFIG=/tmp/dx02v2-lab.kubeconfig
kubectl -n dx02v2 get pods,gateway,httproute,externalsecrets,hpa
kubectl -n dx02v2 get healthcheckpolicy,webapplicationfirewallpolicy
# Core HTTP; full uses your configured HTTPS hostname with certificate verification.
curl -fsS "http://$(kubectl -n dx02v2 get gateway dx02v2 -o jsonpath='{.status.addresses[0].value}')/api/info"
```

After requests, service dx02v2-api appears in Application Insights
tx02v2-lab-traces Transaction search. Flow: API → Collector.observability OTLP/HTTP
4318 → Insights; Collector/identity/role belong to TX.

## 9. Stop

TX destroy/leftover workflow removes AGC/AKS/PostgreSQL/ACR. Removing only app
ingress while retaining cluster needs GitOps reconciliation stopped first:
otherwise self-heal recreates Gateway. Then delete Gateway dx02v2. AGC/frontend
remain TX-owned and still incur charges. Follow TX RUNBOOK for full teardown,
PVC cleanup, soft-deleted names and Owner-level leftover checks.

## 10. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| App Configuration key missing | TX unapplied/wrong endpoint | Complete TX or fix endpoint |
| Cannot read keys | Missing store Data Reader | Section 6 roles |
| Logged into another subscription | Wrong az selection | az account set --subscription <lab-subscription> |
| AADSTS700024 expired assertion | GitHub OIDC expired before new az token | Rerun; no slow steps between azure/login/deploy |
| Cluster does not serve API | TX platform absent | Install platform |
| Principal cannot deploy to dx02v2 | Missing object-ID RoleBinding or Role rule | Check TX platform; exact AGC plurals healthcheckpolicy/webapplicationfirewallpolicy |
| Docker registry login failed | Missing app-repository Writer | Section 6 |
| Refusing root SHA-1 | Downloaded root differs from contract | Stop; inspect Azure CA details. Root changes require contract |
| ExternalSecret not Ready | Missing store/ESO identity/secret | describe externalsecret db-credentials; inspect TX |
| migrate TLS error | Missing azure-pg-ca or non-FQDN host | Script recreates CA; check Key Vault host |
| Gateway not Programmed | ALB/AGC ID/frontend error | describe gateway and controller events |
| WAF policy not Accepted | TX SecurityPolicy or wrong subscription/region | describe webapplicationfirewallpolicy |
| Smoke403 everywhere | Bot Manager/custom WAF rule | Inspect WAF logs; contract requires smoke allowed |
| Request-ID smoke failure | AGC behavior differs from docs | Record cloud_run_report; change assertions only with evidence |
| ImagePullBackOff | Missing kubelet conditional Repository Reader | Inspect apply/ABAC grants on both app repos, not registry-wide AcrPull |
| No Insights trace | Missing Collector/old v1 platform or Entra ingestion denied | Get observability Pods/Collector logs; API continues, spans are lost |

## 11. Record

Create Cloud run report with date/region, DX/TX SHAs, ALB version, steps,
duration, observed cost, smoke output/problems and redacted TX leftovers.
