# tx02v2 <-> dx02v2 contract — version 5 (2026-10-17)

Version 5 (R9): `postgres_profile=dr` publishes the same 17 keys in a secondary
App Configuration with its own region, AKS, network, registry, Key Vault and AGC.
Deployment explicitly selects `dr_appconfig_endpoint` after fencing and manual
replica promotion. The primary retains the v4 interface; `ha` enables HA/PITR
without changing application keys. See [CONTINUITY.md](CONTINUITY.md) and the
coordinated dx02v2 R9 PR.

Version 4 added an optional public DNS zone, CNAME to the AGC frontend, and
automatically renewed ACME certificates in full. There are 17 keys. Version 3
added ambient, GitOps and backup; version 2 added OpenTelemetry Collector traces.

The application consumes the infrastructure interface documented here. The source of truth is [tx02v2 CONTRACT.md](https://github.com/maringelix/tx02v2/blob/main/docs/CONTRACT.md); it takes precedence on divergence. Changes require coordinated PRs and a version increment in both repositories.

R9 selects target=secondary through AZURE_DR_APPCONFIG_ENDPOINT, using DR AKS/ACR/Key Vault and gitops/azure-dr; lab resource group/deploy principals stay unchanged. Regional secret names pass through validated render parameters. The smoke verifies the chosen Gateway before a CNAME change.

Full/local-platform overlays use tx02v2's experimental Gateway API 1.6.3 bundle for waypoint retries. Core AGC entry still uses the ALB Controller schema.

## How this application verifies the contract

| Item | Evidence | Status |
|---|---|---|
| Services, ports, probes, Secrets, ConfigMap, Gateway/HTTPRoute/HealthCheckPolicies/WAF, ExternalSecrets, HPA, NetworkPolicies, Istio AuthorizationPolicy/DestinationRule, labels and permitted Role kinds | contract-app, scripts/check-manifests.mjs on azure/azure-waf/azure-full/azure-waf-full/local-platform | verified in CI |
| v2 API OTLP endpoint and Collector-only egress, observability:4318 | contract-app | verified locally |
| Kubernetes 1.36, ALB1.12.2/Gateway API 1.5.1 standard/alb.networking.azure.io/v1, ExternalSecret v1 | crd-schemas and strict kubeconform | verified locally |
| Exactly17 contract keys/prefix/fixed values; azure-pg-ca roots/SHA-1 checks | contract-app on deploy-azure.sh | verified locally |
| ACR image/AGC frontend+ID/WAF ID-or-none/subnet formats | k8s_validate_params in scripts/lib/k8s.sh and deploy-azure.sh | verified locally |
| Fixed group/cluster/secret/store names and API-group/RBAC preflight before promotion/apply | deploy-azure.sh | not run in the cloud (v2) |
| Actual Azure runtime | RUNBOOK.md | not run in the cloud (v2) |

## Identifiers

| Item | Value |
|---|---|
| Region | Terraform `location`, default `eastus2` |
| Project/environment/prefix | `tx02v2` / `lab` / `tx02v2-lab` |
| Tags on every supported resource (azurerm has no provider default tags) | `Project=tx02v2`, `Environment=lab`, `ManagedBy=terraform`, `Repository=<owner>/tx02v2` |
| Resource groups | `tx02v2-bootstrap` (state/CI identities); `tx02v2-lab` (**created by bootstrap**, populated by lab root); AKS nodes `tx02v2-lab-nodes` |
| Global suffix | `suffix = substr(sha1(<subscription_id>), 0, 8)`, deterministic |
| AKS | `tx02v2-lab`, Kubernetes `1.36`, local accounts disabled, Entra/Azure RBAC, OIDC + workload identity, Azure CNI Overlay/Cilium NetworkPolicy |
| Nodes | x86-64, default `Standard_D2als_v6`; dx02v2 images are linux/amd64, so node_vm_size must not be Arm64 (contract rule, not code-enforced) |
| App namespace | `dx02v2`, created by platform, Pod Security restricted; full enables ambient and Gatekeeper (`istio.io/dataplane-mode=ambient`, `policy.lab/enforce=true`) |
| Ambient NetworkPolicy | Cilium enforces policies; allow mesh HBONE TCP 15008 and kubelet probes `169.254.7.127/32`; ARCHITECTURE.md ADR 41 and dx02v2 checks |
| Traces (v2) | `http://opentelemetry-collector.observability.svc:4318`, OTLP/HTTP. Platform Collector in observability has the same Pod Security labels and writes to Insights/workspace `tx02v2-lab-traces` with local auth disabled. Identity `tx02v2-lab-otel`, subject `system:serviceaccount:observability:opentelemetry-collector`, Monitoring Metrics Publisher only on that Insights resource. App receives no Azure role |
| Deployer Kubernetes RBAC | Role `dx02v2-deployer` and RoleBinding `dx02v2-deployers` in dx02v2; User subject is dx02v2-gha-deploy object ID plus app_deployer_principal_ids |
| ACR | `tx02v2lab<suffix>`, Standard, `role_assignment_mode = AbacRepositoryPermissions`, admin/anonymous pull disabled; dx02v2/api and dx02v2/web, SHA256 digests. Kubelet/Trivy/Kyverno have separate ABAC Repository Reader conditions; deploy identity/human deployers have equivalent Writer conditions. Full 40-character Git SHA tags; deploy refuses overwrite |
| GitHub identities in bootstrap | `tx02v2-gha-plan`, `tx02v2-gha-apply`, `dx02v2-gha-deploy` |

Role `dx02v2-deployer` in dx02v2 controls the Azure traffic CRDs. Full CRUD means get/list/watch/create/update/patch/delete:

- apps: deployments full CRUD; replicasets get/list/watch.
- core: services/configmaps/serviceaccounts full CRUD; pods/pods-log/events/endpoints
  get/list/watch; secrets get/list/watch (ESO writes; deployer never writes).
- networking.k8s.io: networkpolicies full CRUD.
- networking.istio.io destinationrules and security.istio.io authorizationpolicies:
  full CRUD, limited to dx02v2 (full ambient/canary).
- gateway.networking.k8s.io: gateways/httproutes full CRUD.
- alb.networking.azure.io: `healthcheckpolicy` / `webapplicationfirewallpolicy`
  full CRUD. These are the exact spec.names.plural values from ALB Controller
  1.12.2 CRDs; the apparent singular is intentional. The alternatives
  healthcheckpolicies/webapplicationfirewallpolicies match nothing.
- autoscaling horizontalpodautoscalers and policy poddisruptionbudgets full CRUD.
- external-secrets.io externalsecrets full CRUD.

## Deployment selection and GitOps

platform_profile=full uses ambient waypoint and the internal 80/20 canary route. TX installs the mesh and image-signature gate. deploy-azure accepts platform_profile=core|full, deploy_mode=auto|gitops|push and target=primary|secondary. Auto selects GitOps when Application dx02v2 exists, direct apply when absent; permission/connection failures fail closed rather than looking absent. GitOps sets live spec.source.kustomize paths/images/real values, publishes the revision to gitops/azure (or azure-dr), and waits for Argo CD. The public branch never receives real account IDs/CIDRs. Run the full workflow on main so ACR digests are promoted and attested before deployment. Manual DEPLOY_MODE=push does not create this signature.

## GitHub OIDC

Issuer `https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, configurable `github_owner` with no default
(repository/fork owner), one federated credential per exact subject.

| Identity | Subjects |
|---|---|
| tx02v2-gha-plan | `repo:<owner>@<owner id>/tx02v2@<repo id>:pull_request`; `repo:<owner>@<owner id>/tx02v2@<repo id>:ref:refs/heads/main` |
| tx02v2-gha-apply | `repo:<owner>@<owner id>/tx02v2@<repo id>:environment:lab` |
| dx02v2-gha-deploy | `repo:<owner>@<owner id>/dx02v2@<repo id>:environment:lab` |

GitHub's immutable subject (new repositories after 2026-07-15 or opted-in
repositories) includes numeric owner/repository IDs: github_owner_id,
tx02v2_repository_id, dx02v2_repository_id. Re-registering a deleted account name
does not inherit this lab. The lab environment deploys only main.
tx02v2-gha-plan has Reader on tx02v2-lab and state read access, with no secret
values, App Configuration keys or AKS credentials, so plan uses -refresh=false.

The lab root grants dx02v2-gha-deploy Container Registry Repository Writer with
separate ABAC conditions for dx02v2/api and dx02v2/web, Azure Kubernetes Service
Cluster User Role on AKS (kubeconfig), and App Configuration Data Reader on the
contract store. No Key Vault role; Kubernetes access is only through the
RoleBinding above. Human app_deployer_principal_ids receive the same three roles
at identical scopes and join that RoleBinding, with no Key Vault access.

## Contract store: App Configuration `tx02v2-lab-<suffix>`

Free tier, local auth disabled, unlabeled keys, prefix `tx02v2/lab/`.
Output appconfig_endpoint becomes GitHub variable AZURE_APPCONFIG_ENDPOINT in
dx02v2. None of these values is a secret.

| Key | Value |
|---|---|
| `location` | Azure region |
| `resource-group` | tx02v2-lab |
| `cluster-name` | tx02v2-lab |
| `vnet-cidr` | VNet CIDR |
| `agc-subnet-cidr` | AGC delegated subnet, exactly /24; AGC-to-Pod traffic originates here |
| `postgres-subnet-cidr` | PostgreSQL Flexible Server delegated subnet |
| `acr/login-server` | <acr-name>.azurecr.io |
| `keyvault/uri` | Key Vault URI |
| `db/secret-name` | tx02v2-lab-db-app |
| `app/admin-token-secret-name` | tx02v2-lab-app-admin-token |
| `eso/cluster-secret-store` | azure-key-vault |
| `agc/id` | AGC resource ID |
| `agc/frontend-name` | AGC frontend name |
| `dns/hostname` | Public app subdomain, or disabled when DNS is unconfigured |
| `dns/acme-email` | Fork's ACME contact, or disabled; not a secret |
| `waf/policy-id` | WAF resource ID, or literal none with enable_waf=false |
| `deploy/principal-id` | dx02v2-gha-deploy object ID |

### How the application uses each key

| Key | Application use |
|---|---|
| location | Validate format |
| resource-group / cluster-name | Verify selected target; az aks get-credentials |
| vnet-cidr | Validate format |
| agc-subnet-cidr | AGC_SUBNET_CIDR, /24; web-ingress-from-agc and api-ingress-from-agc |
| postgres-subnet-cidr | POSTGRES_SUBNET_CIDR; api-egress-to-postgres-subnet |
| acr/login-server | API_IMAGE/WEB_IMAGE in dx02v2/api/web |
| keyvault/uri | Validate format; infrastructure ESO reads vault |
| db/secret-name | Match db-credentials ExternalSecret |
| app/admin-token-secret-name | Match app-secrets ExternalSecret |
| eso/cluster-secret-store | Match ExternalSecret secretStoreRef |
| agc/id | AGC_ID in Gateway alb-id annotation; subscription must match logged-in az |
| agc/frontend-name | AGC_FRONTEND in spec.addresses, alb.networking.azure.io/alb-frontend |
| dns/hostname | DNS_HOSTNAME, required full listeners/HTTPS/redirect |
| dns/acme-email | Validate enabled pair with hostname; TX issues/renews certificate |
| waf/policy-id | WAF_POLICY_ID; azure-waf/full overlays when enabled; none selects azure/full and deletes old policy |
| deploy/principal-id | Validate format |

## Key Vault `tx02v2-lab-<suffix>`

RBAC authorization; write-only arguments keep values out of plan and state.

- `tx02v2-lab-db-app`: JSON string fields username/password/host/port/dbname.
  Host is the server FQDN (<name>.postgres.database.azure.com), verified by TLS.
- `tx02v2-lab-app-admin-token`: plain random 48-character alphanumeric string.
- ESO identity tx02v2-lab-eso federates subject
  system:serviceaccount:external-secrets:external-secrets and has Key Vault
  Secrets User only on this vault.

## Platform (tx02v2 platform/install.sh; never Terraform)

- ALB Controller 1.12.2 in azure-alb-system, tx02v2-lab-alb federated with
  alb-controller-sa, bring-your-own roles (ARCHITECTURE.md), GatewayClass
  azure-alb-external.
- External Secrets Operator 2.12.0 in external-secrets, ServiceAccount
  external-secrets, annotation azure.workload.identity/client-id, Pod label
  azure.workload.identity/use: "true". ClusterSecretStore azure-key-vault,
  provider azurekv, authType WorkloadIdentity, contract vaultUrl and
  serviceAccountRef external-secrets/external-secrets; only dx02v2 may use it.
- Namespace, Role and RoleBinding above.

### Full cloud profile (R4)

platform accepts profile=core (default) or full. Full installs 16 charts from
platform/full/charts.txt, pinned by version/package SHA256/image digests:
Istio ambient/waypoint, cert-manager, Prometheus/Alertmanager/Grafana, Loki/Alloy,
Tempo/Collector, Argo CD, Gatekeeper, Kyverno, Trivy Operator, Velero, Chaos Mesh.
Azure overlays use Monitor/Blob instead of X-Ray/S3. Full adds ServiceMonitor,
SLO/alert rules and an API dashboard with managed-csi PVC persistence.

Kyverno ImageValidatingPolicy blocks app repository images without digest or
Sigstore promotion attestation. It trusts only the fork's deploy-azure.yml
OIDC subject on refs/heads/main, GitHub issuer, and predicate type
`https://github.com/maringelix/tx00v2/attestations/promoted-image/v1`.
dx02v2 must sign the same digest it publishes/promotes; admission fails closed.
Trivy and Kyverno use AKS federation with read access only to both repositories.

Argo CD's app-of-apps follows platform/gitops in public tx02v2 main.
Application dx02v2 follows public app branch gitops/azure and overlay
deploy/k8s/overlays/azure with automatic sync/self-heal/prune. Argo CD has no
LoadBalancer. Deploy identity can get/watch/patch only Application dx02v2,
without listing or changing others.

Deployment updates the live Application's overlay, images and deployment
IDs/CIDRs. Parent Application platform ignores only spec.source.path,
spec.source.kustomize.images and spec.source.kustomize.patches on its child,
preserving them during self-heal. Public gitops/azure contains revision and
example parameters; real IDs/CIDRs remain in-cluster.

Velero's Azure plugin and Entra Workload ID write Kubernetes resources to private
Blob. It creates no disk snapshots and does not replace managed PostgreSQL
backup. Storage Blob Data Contributor is scoped to the container. Backup-prefix
blobs expire after 35 days; shared Kopia chunks follow repository GC. Storage
has a public endpoint, no Private Endpoint, Deny firewall allowing own AKS node
subnets through Microsoft.Storage.Global (both regions in DR), no anonymous
access or shared keys. Azure backup/restore remains not run in the cloud (v2).

## Application runtime (dx02v2)

- db-credentials Secret: DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD, from
  tx02v2-lab-db-app in Azure; generated at runtime in local/kind/Compose.
- app-secrets Secret: ADMIN_TOKEN from tx02v2-lab-app-admin-token in Azure.
- Azure database TLS: DB_SSL_MODE=verify-full,
  DB_SSL_CA_FILE=/etc/azure-pg-ca/ca.pem, ConfigMap azure-pg-ca created by deploy.
  Bundle concatenates three PEM roots. Azure PostgreSQL TLS docs require at least
  the first two and recommend all Azure roots; names/SHA-1 values come from
  "Azure Certificate Authority details". Deploy downloads DER, converts to PEM,
  and rejects a different SHA-1 thumbprint. SHA256/expiry below were calculated
  from downloads on 2026-10-11, matching dx02v2.

| Root | DER URL | SHA-1 (contract) | SHA-256 | Expires |
|---|---|---|---|---|
| DigiCert Global Root G2 | `https://cacerts.digicert.com/DigiCertGlobalRootG2.crt` | `DF3C24F9BFD666761B268073FE06D1CC8D4F82A4` | `CB3CCBB76031E5E0138F8DD39A23F9DE47FFC35E43C1144CEA27D46A5AB1CB5F` | 2038-01-15 |
| Microsoft RSA Root Certificate Authority 2017 | `https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt` | `73A5E64A3BFF8316FF0EDCCC618A906E4EAE4D74` | `C741F70F4B2A8D88BF2E71C14122EF53EF10EBA0CFA5E64CFA20F418853073E0` | 2042-07-18 |
| Microsoft ECC Root Certificate Authority 2017 | `https://www.microsoft.com/pkiops/certs/Microsoft%20ECC%20Root%20Certificate%20Authority%202017.crt` | `999A64C37FF47D9FAB95F14769891460EEC4C3C5` | `358DF39D764AF9E1B766E9C972DF352EE15CFAC227AF6AD1D70E8E4A6EDCBA02` | 2042-07-18 |

Local uses DB_SSL_MODE=disable.

- Services: api HTTP 3000/metrics 9464; web 8080.
- Azure Gateway dx02v2, class azure-alb-external, annotation
  alb.networking.azure.io/alb-id = agc/id, spec.addresses type
  alb.networking.azure.io/alb-frontend = agc/frontend-name (bring your own).
  Core listens on HTTP 80; full uses HTTPS 443, Secret dx02v2-tls issued/renewed
  by cert-manager/Let's Encrypt and redirects HTTP. HTTPRoute /api → api:3000,
  / → web:8080. HealthCheckPolicy web /healthz, API /readyz.
  WebApplicationFirewallPolicy targets Gateway and waf/policy-id, absent for none.
- AGC subnet must be exactly /24 with Azure CNI Overlay; both repos check.
- WAF Prevention, DRS 2.1 + Bot Manager 1.1, body inspection 128 KB. The smoke's
  70 KB reaches API, which returns 413 (cross-cloud differences are documented in ARCHITECTURE.md). Custom
  rules must not block smoke; any added rate limit must be >=300 requests/minute/client.
- Azure NetworkPolicies allow AGC subnet → web:8080/API:3000; full allows only
  AGC subnet → temporary ACME solver:8089 for renewal. API egress PostgreSQL
  subnet:5432 and DNS. Namespace mTLS is STRICT; workload-specific PERMISSIVE exceptions allow AGC HTTP on web:8080, API:3000 and temporary solver:8089. Source-IP authorization and Cilium NetworkPolicies restrict this plaintext edge path to the delegated AGC subnet; other ports, including metrics:9464, remain STRICT.
- PostgreSQL Flexible 17, port 5432, private delegated subnet/DNS,
  require_secure_transport=on, TLS >=1.2.

## Implementation notes (2026-10-11, incorporated in contract v1)

These findings came from implementing against official documentation/ALB1.12.2 CRDs before the first TX publication. They did not themselves change v1; later versions are recorded above.

1. The original frontend annotation wording belonged to Ingress API. Gateway bring-your-own requires alb.networking.azure.io/alb-id plus spec.addresses type alb.networking.azure.io/alb-frontend, as implemented here.
2. CRD plurals are healthcheckpolicy/webapplicationfirewallpolicy, intentionally identical to singular. Incorrect healthcheckpolicies/webapplicationfirewallpolicies RBAC would fail the deploy preflight: kubectl auth can-i create healthcheckpolicy.alb.networking.azure.io.
3. Original notes said about 12KB smoke body; actual smoke sends 70 KB, below WAF 128 KB and above API 10kb, so API 413 remains expected.
4. Host is the server FQDN checked by verify-full; nodes are x86-64/linux/amd64; AGC Overlay subnet must be /24. Kubelet's former AcrPull wording is superseded by repository-scoped Reader ABAC in the current TX contract. Human app_deployer_principal_ids get the same conditional Repository Writer, AKS Cluster User and App Configuration Data Reader roles plus RoleBinding as dx02v2-gha-deploy.

## Local lab (separate local contract, version 2)

The local lab (LOCAL_LAB.md) has its own version key, consumed by dx02v2 local
deployment. It mirrors cloud names without changing the contract above; keys
match the other local family labs. platform/local/install.sh publishes ConfigMap
lab-system/lab-contract:

| Key | Value | Cloud equivalent |
|---|---|---|
| `version` | 2; 2026-10-14 added tracing.otlp-endpoint (v1 lacked traces) | This document's version |
| `cluster-name` | tx02v2-local | cluster-name |
| `network-cidr` | 10.251.0.0/24 or subnet_cidr | vnet-cidr |
| `registry` | registry.tx02v2.local (in-cluster names) | acr/login-server prefix |
| `registry-push` | localhost:5002 (host push) | — |
| `db.endpoint-ip`, `db.hostname`, `db.port` | 10.251.0.11, db.tx02v2.local, 5432 | PostgreSQL FQDN (host in tx02v2-lab-db-app) |
| `db.secret-name` | tx02v2-lab-db-app: host/port/dbname/username/password | db/secret-name |
| `db.ca-configmap` | lab-system/lab-ca, key ca.crt | Three-root azure-pg-ca bundle created by deploy |
| `app.admin-token-secret-name` | tx02v2-lab-app-admin-token, key token (plain string in Key Vault) | app/admin-token-secret-name |
| `eso.cluster-secret-store` | local-secrets, only dx02v2 | eso/cluster-secret-store |
| `gateway.class` | istio | azure-alb-external with agc/id and frontend-name |
| `tls.cluster-issuer` | lab-ca | Full: tx02v2-letsencrypt-prod, fork domain ACME HTTP-01 |
| `gitops.push-url`, `gitops.read-url` | ssh://10.251.0.13:23231/dx02v2-gitops, http://10.251.0.13:23232/dx02v2-gitops.git | — |
| `gitops.push-key-secret` | lab-secrets/gitops-push-key, kubernetes.io/ssh-auth | dx02v2-gha-deploy |
| `argocd.project` | dx02v2: only GitOps repo/namespace/deployment kinds; no Secret/cluster resources | dx02v2-deployer Role |
| `monitoring.prometheus-service-account` | monitoring/kube-prometheus-stack-prometheus, mesh identity | — |
| `tracing.otlp-endpoint` | http://opentelemetry-collector.monitoring.svc:4318, OTLP/HTTP through mesh; Gateways use OTLP/gRPC 4317 | http://opentelemetry-collector.observability.svc:4318 |

Secrets tx02v2-lab-db-app/tx02v2-lab-app-admin-token live in lab-secrets (local
Key Vault twin); their names are already Kubernetes-valid. dx02v2 has restricted
Pod Security, ambient mesh, Gatekeeper deny (policy.lab/enforce: "true", images
only registry.tx02v2.local/), and Prometheus scraping from monitoring. Local
deployment writes GitOps; Argo CD applies it. The local Gateway retains a safe
external X-Request-Id, whereas AGC generates its own.

## Changing the contract

1. Open linked PRs in both repositories and increment both CONTRACT.md titles.
2. Update application checks in scripts/check-manifests.mjs, scripts/deploy-azure.sh, scripts/lib/k8s.sh and scripts/harness.sh. A new App Configuration key also changes
   terraform/envs/lab/contract.tf, CONTRACT_KEYS in scripts/harness.sh and this
   table together.
3. Merge the publisher (tx02v2) before the consumer (dx02v2), except removals,
   which reverse the order.
