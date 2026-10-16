#!/usr/bin/env bash
# Deploys dx02v2 to the AKS lab cluster of tx02v2 (docs/CONTRATO.md).
# CLOUD-MUTATING and billable: promotes a signed GHCR release to ACR and makes the ALB Controller program Application
# Gateway for Containers (AGC), which with its WAF is the biggest cost item of the Azure lab. Run it
# only on purpose, after the tx02v2 apply + platform steps; the teardown is the tx02v2 destroy.
# Not run in the cloud yet (v2).
# Used by .github/workflows/deploy-azure.yml and from a laptop (docs/RUNBOOK.md):
#   see docs/RUNBOOK.md for release bundle, GHCR login, Git credentials and Azure login requirements
# Environment:
#   AZURE_APPCONFIG_ENDPOINT  required: endpoint of the contract store (an output of tx02v2)
#   RELEASE_DIR               verified release bundle (manifest and two SPDX files)
#   RELEASE_RUN_ID            successful publish-images Actions run id for that bundle
#   GH_TOKEN                  token with actions:read, attestations:read and packages:read
#   GIT_SHA                   optional; if set, must equal the release manifest source commit
#   DEPLOY_MODE               gitops (default: publish to gitops/azure and wait for Argo CD) or push
#   GITHUB_TOKEN              optional locally; Actions uses it for the GitOps branch push
#   GITHUB_REPOSITORY, GITHUB_ACTOR  repository and GHCR username used to verify/import the release
#   ARGO_SYNC_TIMEOUT         seconds to wait for the Argo CD Application (default 600)
#   SMOKE_WAIT_SECONDS        how long the smoke test waits for the AGC frontend (default 900)
# Steps: verify signed release -> App Configuration contract -> AKS kubeconfig (az aks get-credentials + kubelogin) -> API
# groups and RBAC preflight -> import verified GHCR digests into ACR without rebuilding -> ConfigMap azure-pg-ca (three root CAs, SHA-1 thumbprints
# checked) -> configure Argo CD and publish gitops/azure (default) -> sync -> ExternalSecrets
# -> rollouts -> Gateway address (and WAF policy) -> smoke test through AGC.
# DEPLOY_MODE=push applies the overlay directly.
# Every Azure token is acquired in the first minutes: the GitHub OIDC
# assertion behind azure/login expires after 5-10 minutes, and from then on the Azure CLI can only
# reuse the access tokens it already holds (about one hour).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx02v2
APPCONFIG_PREFIX=tx02v2/lab/
# Contract: every App Configuration key the deploy reads (the harness check contract-app verifies this list).
CONTRACT_KEYS=(
  location resource-group cluster-name vnet-cidr agc-subnet-cidr postgres-subnet-cidr acr/login-server
  keyvault/uri db/secret-name app/admin-token-secret-name eso/cluster-secret-store agc/id agc/frontend-name
  waf/policy-id deploy/principal-id
)
# Values fixed in deploy/k8s/components/azure and in this script: the store of tx02v2 must agree.
CONTRACT_RESOURCE_GROUP=tx02v2-lab
CONTRACT_CLUSTER=tx02v2-lab
CONTRACT_DB_SECRET=tx02v2-lab-db-app
CONTRACT_ADMIN_TOKEN_SECRET=tx02v2-lab-app-admin-token
CONTRACT_SECRET_STORE=azure-key-vault
APPCONFIG_ENDPOINT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}\.azconfig\.io/?$'
ACR_PATTERN='^tx02v2lab[0-9a-f]{8}\.azurecr\.io$'
KEYVAULT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}\.vault\.azure\.net/?$'
CIDR_PATTERN='^([0-9]{1,3}\.){3}[0-9]{1,3}/([89]|1[0-9]|2[0-9])$'
# Contract: root CAs for Azure Database for PostgreSQL (SHA-1 thumbprint, DER download URL), from
# learn.microsoft.com/azure/security/fundamentals/azure-ca-details. A download whose thumbprint
# differs is refused.
AZURE_PG_ROOTS=(
  'DF3C24F9BFD666761B268073FE06D1CC8D4F82A4 https://cacerts.digicert.com/DigiCertGlobalRootG2.crt'
  '73A5E64A3BFF8316FF0EDCCC618A906E4EAE4D74 https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt'
  '999A64C37FF47D9FAB95F14769891460EEC4C3C5 https://www.microsoft.com/pkiops/certs/Microsoft%20ECC%20Root%20Certificate%20Authority%202017.crt'
)
# Every kind of the rendered overlays, as Kubernetes resources (the WAF policy is checked apart).
DEPLOY_RESOURCES=(
  deployments.apps services configmaps serviceaccounts poddisruptionbudgets.policy
  horizontalpodautoscalers.autoscaling networkpolicies.networking.k8s.io gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io healthcheckpolicy.alb.networking.azure.io externalsecrets.external-secrets.io
)
WAF_RESOURCE=webapplicationfirewallpolicy.alb.networking.azure.io

declare -A PARAM=()
WORK_DIR=""
GROUP_OPEN=0
OVERLAY=azure
SUBSCRIPTION_ID=""
ACR_NAME=""
ACR_LOGGED_IN=0
API_IMAGE=""
WEB_IMAGE=""
RELEASE_MANIFEST=""
API_SOURCE_NAME=""
API_SOURCE_DIGEST=""
API_IMAGE_ID=""
WEB_SOURCE_NAME=""
WEB_SOURCE_DIGEST=""
WEB_IMAGE_ID=""
WAF_SERVED=0
GATEWAY_ADDRESS=""
BASE=""
DEPLOY_MODE="${DEPLOY_MODE:-gitops}"
ARGO_SYNC_TIMEOUT="${ARGO_SYNC_TIMEOUT:-600}"
GITOPS_REV=""

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }

# mask VALUE -> hides an identifier (subscription, resource IDs, object ID) or the admin token in
# the GitHub Actions logs, which are public for a public repository.
mask() {
  if in_actions && [[ -n "$1" ]]; then
    echo "::add-mask::$1"
  fi
}

section() {
  if in_actions; then
    ((GROUP_OPEN == 0)) || echo "::endgroup::"
    echo "::group::$*"
    GROUP_OPEN=1
  else
    log "== $*"
  fi
}

param() { printf '%s' "${PARAM[$1]}"; }

# expect_param KEY VALUE -> the fixed names of the contract (never identifiers, safe to print).
expect_param() {
  [[ "$(param "$1")" == "$2" ]] ||
    die "App Configuration $APPCONFIG_PREFIX$1 is '$(param "$1")' but the manifests expect '$2' (docs/CONTRATO.md)"
}

# expect_format KEY REGEX -> values that carry identifiers are validated without printing them.
expect_format() {
  [[ "$(param "$1")" =~ $2 ]] ||
    die "App Configuration $APPCONFIG_PREFIX$1 does not have the format of the contract (docs/CONTRATO.md)"
}

write_summary() { # RESULT
  local api_digest="${API_IMAGE##*@}" web_digest="${WEB_IMAGE##*@}"
  [[ "$api_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || api_digest=not-promoted
  [[ "$web_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || web_digest=not-promoted
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## dx02v2 deploy: $1"
    echo
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Commit | \`${GIT_SHA:-unknown}\` |"
    echo "| Overlay | \`deploy/k8s/overlays/$OVERLAY\` |"
    printf "| Images | API \`%s\`, web \`%s\` in ACR |\n" "$api_digest" "$web_digest"
    echo "| Entry point | $([[ -n "$GATEWAY_ADDRESS" ]] && echo 'AGC ready' || echo 'not reached') |"
    echo "| Smoke test | $([[ -f "$WORK_DIR/smoke.txt" ]] && echo 'completed' || echo 'not completed') |"
    echo
    echo "Application Gateway for Containers (and its WAF), AKS and PostgreSQL bill by the hour: tear the lab down with the destroy workflow of tx02v2."
  } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
  local rc=$?
  if ((GROUP_OPEN)); then
    echo "::endgroup::"
  fi
  if ((ACR_LOGGED_IN)); then
    docker logout "$(param acr/login-server)" >/dev/null 2>&1 || :
  fi
  if [[ -n "$WORK_DIR" ]]; then
    if ((rc == 0)); then
      write_summary succeeded
    else
      write_summary failed
    fi
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}

preflight() {
  local release_sha
  require_cmd az kubectl kubelogin docker node git curl base64 gh jq
  for name in GITHUB_REPOSITORY GITHUB_ACTOR; do
    [[ -n "${!name:-}" ]] || die "$name is required to verify and promote the signed release"
  done
  [[ -n "${RELEASE_DIR:-}" ]] || die "RELEASE_DIR is required; publish and verify a release first"
  [[ -n "${RELEASE_RUN_ID:-}" ]] || die "RELEASE_RUN_ID is required; select the successful publish-images run"
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN with actions:read, attestations:read and packages:read is required"
  RELEASE_MANIFEST="$RELEASE_DIR/release-manifest.json"
  bash "$REPO_ROOT/scripts/verify-release-bundle.sh"
  API_SOURCE_NAME="$(jq -er '.images.api.name' "$RELEASE_MANIFEST")"
  API_SOURCE_DIGEST="$(jq -er '.images.api.digest' "$RELEASE_MANIFEST")"
  API_IMAGE_ID="$(jq -er '.images.api.image_id' "$RELEASE_MANIFEST")"
  WEB_SOURCE_NAME="$(jq -er '.images.web.name' "$RELEASE_MANIFEST")"
  WEB_SOURCE_DIGEST="$(jq -er '.images.web.digest' "$RELEASE_MANIFEST")"
  WEB_IMAGE_ID="$(jq -er '.images.web.image_id' "$RELEASE_MANIFEST")"
  release_sha="$(jq -er '.source.sha' "$RELEASE_MANIFEST")"
  if [[ -n "${GIT_SHA:-}" && "$GIT_SHA" != "$release_sha" ]]; then
    die "GIT_SHA does not match the verified release source commit $release_sha"
  fi
  GIT_SHA="$release_sha"
  [[ -n "${AZURE_APPCONFIG_ENDPOINT:-}" ]] ||
    die "AZURE_APPCONFIG_ENDPOINT is required (the App Configuration endpoint output by tx02v2)"
  [[ "$AZURE_APPCONFIG_ENDPOINT" =~ $APPCONFIG_ENDPOINT_PATTERN ]] ||
    die "AZURE_APPCONFIG_ENDPOINT must look like https://tx02v2-lab-<suffix>.azconfig.io (docs/CONTRATO.md)"
  [[ "$DEPLOY_MODE" == gitops || "$DEPLOY_MODE" == push ]] || die "DEPLOY_MODE must be gitops or push"
  if [[ ! "$ARGO_SYNC_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    die "ARGO_SYNC_TIMEOUT must be an integer of at least 5 seconds"
  fi
  if ((ARGO_SYNC_TIMEOUT < 5)); then
    die "ARGO_SYNC_TIMEOUT must be an integer of at least 5 seconds"
  fi
  az account show --query id --output tsv >/dev/null ||
    die "no usable Azure CLI login (azure/login with dx02v2-gha-deploy in GitHub Actions, or az login)"
}

read_contract() {
  local out key value n waf waf_subscription
  out="$(az appconfig kv list --endpoint "$AZURE_APPCONFIG_ENDPOINT" --auth-mode login --key "${APPCONFIG_PREFIX}*" \
    --label '\0' --all --fields key value --output json --only-show-errors)" ||
    die "cannot read the App Configuration keys ${APPCONFIG_PREFIX}* (is tx02v2 applied, and does this principal have App Configuration Data Reader on the store?)"
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  while IFS=$'\t' read -r key value; do
    if [[ -n "$key" ]]; then
      PARAM[${key#"$APPCONFIG_PREFIX"}]=$value
    fi
  done < <(node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      for (const kv of JSON.parse(s)) {
        if (typeof kv.key === "string" && typeof kv.value === "string" && !/[\t\n\r]/.test(kv.key + kv.value)) {
          console.log(`${kv.key}\t${kv.value}`);
        }
      }
    });' <<<"$out")
  for n in "${CONTRACT_KEYS[@]}"; do
    [[ -n "${PARAM[$n]:-}" ]] || die "the App Configuration key $APPCONFIG_PREFIX$n is missing (docs/CONTRATO.md)"
  done
  for n in agc/id waf/policy-id deploy/principal-id; do
    mask "$(param "$n")"
  done
  expect_param resource-group "$CONTRACT_RESOURCE_GROUP"
  expect_param cluster-name "$CONTRACT_CLUSTER"
  expect_param db/secret-name "$CONTRACT_DB_SECRET"
  expect_param app/admin-token-secret-name "$CONTRACT_ADMIN_TOKEN_SECRET"
  expect_param eso/cluster-secret-store "$CONTRACT_SECRET_STORE"
  expect_format location '^[a-z0-9]+$'
  expect_format vnet-cidr "$CIDR_PATTERN"
  expect_format acr/login-server "$ACR_PATTERN"
  expect_format keyvault/uri "$KEYVAULT_PATTERN"
  expect_format deploy/principal-id "^$K8S_GUID\$"
  expect_format agc/id "${K8S_PARAM_PATTERN[AGC_ID]}"
  expect_format agc/frontend-name "${K8S_PARAM_PATTERN[AGC_FRONTEND]}"
  expect_format waf/policy-id "${K8S_PARAM_PATTERN[WAF_POLICY_ID]}"
  expect_format agc-subnet-cidr "${K8S_PARAM_PATTERN[AGC_SUBNET_CIDR]}"
  expect_format postgres-subnet-cidr "${K8S_PARAM_PATTERN[POSTGRES_SUBNET_CIDR]}"
  SUBSCRIPTION_ID="$(param agc/id)"
  SUBSCRIPTION_ID="${SUBSCRIPTION_ID#/subscriptions/}"
  SUBSCRIPTION_ID="${SUBSCRIPTION_ID%%/*}"
  mask "$SUBSCRIPTION_ID"
  waf="$(param waf/policy-id)"
  if [[ "$waf" != none ]]; then
    OVERLAY=azure-waf
    waf_subscription="${waf#/subscriptions/}"
    # Application Gateway for Containers only uses WAF policies of its own subscription and region.
    [[ "${waf_subscription%%/*}" == "$SUBSCRIPTION_ID" ]] ||
      die "App Configuration ${APPCONFIG_PREFIX}waf/policy-id is in another subscription than agc/id"
  fi
  [[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] ||
    die "the Azure CLI is logged in to another subscription than the one of agc/id (az account set --subscription <lab subscription>)"
  ACR_NAME="$(param acr/login-server)"
  ACR_NAME="${ACR_NAME%%.*}"
  API_IMAGE="$(param acr/login-server)/dx02v2/api@$API_SOURCE_DIGEST"
  WEB_IMAGE="$(param acr/login-server)/dx02v2/web@$WEB_SOURCE_DIGEST"
  log "contract: ${#CONTRACT_KEYS[@]} keys read and consistent with the manifests (overlay $OVERLAY)"
}

# connect_cluster -> temporary kubeconfig, then proof that the platform layer of tx02v2 is there and
# that this principal may write every kind of the overlay (fails before anything is built or pushed).
connect_cluster() {
  local versions resources resource
  local -a missing=()
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  az aks get-credentials --subscription "$SUBSCRIPTION_ID" --resource-group "$(param resource-group)" \
    --name "$(param cluster-name)" --file "$KUBECONFIG" --only-show-errors >/dev/null ||
    die "cannot fetch the kubeconfig of $(param cluster-name) (this principal needs the Azure Kubernetes Service Cluster User Role on it, docs/CONTRATO.md)"
  # Local accounts are disabled: kubectl authenticates with Entra ID through the Azure CLI session.
  kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG"
  # Discovery is open to every authenticated user: the API groups of the platform layer must be served.
  versions="$(kubectl api-versions)" || die "cannot reach the API server of $(param cluster-name) with this principal"
  for resource in gateway.networking.k8s.io/v1 alb.networking.azure.io/v1 external-secrets.io/v1; do
    grep -qxF "$resource" <<<"$versions" || missing+=("$resource")
  done
  ((${#missing[@]} == 0)) ||
    die "the cluster does not serve ${missing[*]}: install the tx02v2 platform layer (ALB Controller, External Secrets Operator)"
  resources="$(kubectl api-resources --api-group=alb.networking.azure.io -o name)" ||
    die "cannot list the resources of alb.networking.azure.io"
  if grep -qxF "$WAF_RESOURCE" <<<"$resources"; then
    WAF_SERVED=1
  fi
  if [[ "$OVERLAY" == azure-waf ]] && ((WAF_SERVED == 0)); then
    die "waf/policy-id names a WAF policy, but the ALB Controller of tx02v2 does not serve $WAF_RESOURCE"
  fi
  for resource in "${DEPLOY_RESOURCES[@]}"; do
    [[ "$(kubectl auth can-i create "$resource" -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("create $resource")
  done
  if [[ "$OVERLAY" == azure-waf ]]; then
    [[ "$(kubectl auth can-i create "$WAF_RESOURCE" -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("create $WAF_RESOURCE")
  elif ((WAF_SERVED)); then
    [[ "$(kubectl auth can-i delete "$WAF_RESOURCE" -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("delete $WAF_RESOURCE")
  fi
  [[ "$(kubectl auth can-i get secrets -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("get secrets")
  ((${#missing[@]} == 0)) ||
    die "this principal cannot deploy to namespace $NAMESPACE (${missing[*]}): it needs the RoleBinding dx02v2-deployers of the tx02v2 platform layer (Role dx02v2-deployer; subject: the object ID of dx02v2-gha-deploy, or yours in app_deployer_principal_ids)"
  if [[ "$DEPLOY_MODE" == gitops ]]; then
    [[ "$(kubectl auth can-i patch applications.argoproj.io/dx02v2 -n argocd 2>/dev/null)" == yes ]] ||
      die "this principal cannot patch the Argo CD Application dx02v2 in argocd (tx02v2 full platform Role)"
    kubectl -n argocd get application dx02v2 >/dev/null ||
      die "Argo CD Application dx02v2 is missing (install the tx02v2 full platform first)"
  fi
  log "cluster $(param cluster-name): platform API groups served, Role dx02v2-deployer usable in $NAMESPACE"
}

# promote_image COMPONENT GHCR_NAME DIGEST EXPECTED_IMAGE_ID -> immutable ACR image reference.
# ACR Basic does not enforce immutable tags, so an existing commit tag must match the signed digest.
promote_image() {
  local component="$1" source_name="$2" source_digest="$3" expected_id="$4"
  local source_ref="$source_name@$source_digest" image_tag="dx02v2/$component:$GIT_SHA"
  local repositories="" tags="" target_digest="" target_ref target_id source_id
  docker pull "$source_ref" >/dev/null || die "cannot pull verified $component source digest $source_ref"
  source_id="$(docker image inspect "$source_ref" --format '{{.Id}}')"
  [[ "$source_id" == "$expected_id" ]] ||
    die "$component GHCR digest does not contain the image ID from the release manifest"
  repositories="$(az acr repository list --name "$ACR_NAME" --output tsv --only-show-errors)" ||
    die "cannot list the repositories of $ACR_NAME (the deploy identity needs Container Registry Data Importer and Data Reader; see the R8 tx02v2 contract update)"
  if grep -qxF "dx02v2/$component" <<<"$repositories"; then
    tags="$(az acr repository show-tags --name "$ACR_NAME" --repository "dx02v2/$component" --output tsv --only-show-errors)" ||
      die "cannot list the tags of dx02v2/$component in $ACR_NAME"
  fi
  if grep -qxF "$GIT_SHA" <<<"$tags"; then
    target_digest="$(az acr repository show --name "$ACR_NAME" --image "$image_tag" --query digest --output tsv --only-show-errors)" ||
      die "cannot resolve the existing ACR digest for $image_tag"
    [[ "$target_digest" == "$source_digest" ]] ||
      die "ACR tag $image_tag already points to a digest other than the verified release; refusing to overwrite it"
    log "$image_tag already exists with the verified digest; reusing it" >&2
  else
    az acr import --name "$ACR_NAME" --source "$source_ref" --image "$image_tag" \
      --username "$GITHUB_ACTOR" --password "$GH_TOKEN" --only-show-errors --output none ||
      die "cannot import the verified $component digest into ACR without rebuilding"
    target_digest="$(az acr repository show --name "$ACR_NAME" --image "$image_tag" --query digest --output tsv --only-show-errors)" ||
      die "cannot resolve the imported ACR digest for $image_tag"
    [[ "$target_digest" == "$source_digest" ]] ||
      die "ACR import changed the approved $component manifest digest (source $source_digest, ACR $target_digest)"
  fi
  target_ref="$(param acr/login-server)/dx02v2/$component@$target_digest"
  docker pull "$target_ref" >/dev/null || die "cannot pull the promoted $component digest from ACR"
  target_id="$(docker image inspect "$target_ref" --format '{{.Id}}')"
  [[ "$target_id" == "$expected_id" ]] || die "promoted $component ACR digest differs from the signed GHCR image"
  printf '%s' "$target_ref"
}

publish_images() {
  local acr_login_server
  acr_login_server="$(param acr/login-server)"
  az acr login --name "$ACR_NAME" --only-show-errors >/dev/null ||
    die "docker login to $ACR_NAME failed (the deploy identity needs Container Registry Data Importer and Data Reader; see the R8 tx02v2 contract update)"
  ACR_LOGGED_IN=1
  API_IMAGE="$(promote_image api "$API_SOURCE_NAME" "$API_SOURCE_DIGEST" "$API_IMAGE_ID")"
  WEB_IMAGE="$(promote_image web "$WEB_SOURCE_NAME" "$WEB_SOURCE_DIGEST" "$WEB_IMAGE_ID")"
  log "promoted the signed API and web digests to $acr_login_server; no image was rebuilt"
}

# create_pg_ca -> ConfigMap azure-pg-ca with the PEM bundle of the contract roots. Each root is
# downloaded in DER, its SHA-1 thumbprint compared with the contract, then converted to PEM.
create_pg_ca() {
  local entry want url der i=0 bundle="$WORK_DIR/azure-pg-ca.pem"
  : >"$bundle"
  for entry in "${AZURE_PG_ROOTS[@]}"; do
    i=$((i + 1))
    want=${entry%% *}
    url=${entry#* }
    der="$WORK_DIR/root-$i.der"
    download "$url" "$der"
    # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
    node -e '
      const { createHash, X509Certificate } = require("node:crypto");
      const der = require("node:fs").readFileSync(process.argv[1]);
      const want = process.argv[2];
      const got = createHash("sha1").update(der).digest("hex").toUpperCase();
      if (got !== want) {
        console.error(`SHA-1 thumbprint ${got}, the contract expects ${want}`);
        process.exit(3);
      }
      const cert = new X509Certificate(der);
      if (!cert.ca || Date.parse(cert.validTo) <= Date.now()) {
        console.error(`not a valid CA certificate: ${cert.subject} (valid to ${cert.validTo})`);
        process.exit(3);
      }
      const cn = cert.subject.split("\n").find((line) => line.startsWith("CN=")) ?? cert.subject;
      console.error(`verified ${cn}: SHA-1 ${got}, SHA-256 ${cert.fingerprint256.replaceAll(":", "")}, valid to ${cert.validTo}`);
      const pem = cert.toString();
      process.stdout.write(pem.endsWith("\n") ? pem : `${pem}\n`);
    ' "$der" "$want" >>"$bundle" || die "refusing $url (root CA of the contract)"
  done
  (($(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle") == ${#AZURE_PG_ROOTS[@]})) ||
    die "the azure-pg-ca bundle does not hold the ${#AZURE_PG_ROOTS[@]} contract roots"
  kubectl -n "$NAMESPACE" create configmap azure-pg-ca --from-file=ca.pem="$bundle" --dry-run=client -o yaml |
    kubectl apply -f -
}

write_params() {
  local params="$WORK_DIR/params.env"
  {
    echo "API_IMAGE=$API_IMAGE"
    echo "WEB_IMAGE=$WEB_IMAGE"
    echo "AGC_ID=$(param agc/id)"
    echo "AGC_FRONTEND=$(param agc/frontend-name)"
    echo "WAF_POLICY_ID=$(param waf/policy-id)"
    echo "AGC_SUBNET_CIDR=$(param agc-subnet-cidr)"
    echo "POSTGRES_SUBNET_CIDR=$(param postgres-subnet-cidr)"
  } >"$params"
}

write_revision() {
  local file="$1"
  cat >"$file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-revision
  labels:
    app.kubernetes.io/name: dx02v2
    app.kubernetes.io/part-of: dx02v2
data:
  source-commit: "$GIT_SHA"
  api-image-tag: "$GIT_SHA"
  web-image-tag: "$GIT_SHA"
  api-image-digest: "${API_IMAGE##*@}"
  web-image-digest: "${WEB_IMAGE##*@}"
EOF
}

render_and_apply() {
  local tree="$WORK_DIR/k8s"
  write_params
  # Validates every value against the contract formats and renders a temporary copy of deploy/k8s.
  k8s_prepare_tree "$tree" "$WORK_DIR/params.env"
  write_revision "$tree/overlays/$OVERLAY/gitops-revision.yaml"
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
  kubectl apply -k "$tree/overlays/$OVERLAY"
  if [[ "$OVERLAY" == azure ]] && ((WAF_SERVED)); then
    # waf/policy-id is none: a policy left by an earlier deploy would point at a deleted WAF policy.
    kubectl -n "$NAMESPACE" delete "$WAF_RESOURCE" dx02v2 --ignore-not-found
  fi
}

render_gitops_source() {
  local tree="$WORK_DIR/k8s"
  write_params
  k8s_prepare_tree "$tree" "$WORK_DIR/params.env"
  write_revision "$tree/overlays/$OVERLAY/gitops-revision.yaml"
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "GitOps source overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
}

configure_gitops_application() {
  local patch="$WORK_DIR/argocd-application-patch.json"
  node "$REPO_ROOT/scripts/render-gitops-application.mjs" azure "$OVERLAY" \
    "$WORK_DIR/params.env" "$REPO_ROOT/deploy/k8s/components/azure/params.example.env" >"$patch"
  kubectl -n argocd patch application dx02v2 --type merge --patch-file "$patch" >/dev/null
  log "Argo CD Application source configured for $OVERLAY and approved image digests"
}

publish_gitops_revision() {
  GITOPS_REV="$(bash "$REPO_ROOT/scripts/publish-gitops.sh" azure "$OVERLAY" "$GIT_SHA" \
    "${API_IMAGE##*@}" "${WEB_IMAGE##*@}")"
  [[ "$GITOPS_REV" =~ ^[0-9a-f]{40}$ ]] || die "GitOps branch push returned no commit SHA"
  kubectl -n argocd annotate application dx02v2 argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  log "published origin/gitops/azure at ${GITOPS_REV:0:7}"
}

wait_for_gitops() {
  local i sync health revision=""
  for i in $(seq 1 $((ARGO_SYNC_TIMEOUT / 5))); do
    sync="$(kubectl -n argocd get application dx02v2 -o jsonpath='{.status.sync.status}' 2>/dev/null)" || sync=""
    health="$(kubectl -n argocd get application dx02v2 -o jsonpath='{.status.health.status}' 2>/dev/null)" || health=""
    revision="$(kubectl -n argocd get application dx02v2 -o jsonpath='{.status.sync.revision}' 2>/dev/null)" || revision=""
    [[ "$sync" == Synced && "$health" == Healthy && "$revision" == "$GITOPS_REV" ]] && {
      log "Argo CD: dx02v2 Synced and Healthy at ${revision:0:7}"
      return 0
    }
    ((i % 12 == 0)) && log "Argo CD: dx02v2 sync=${sync:-?} health=${health:-?} revision=${revision:0:7}"
    sleep 5
  done
  kubectl -n argocd get application dx02v2 -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || :
  die "Argo CD did not reach Synced/Healthy at ${GITOPS_REV:0:7} within ${ARGO_SYNC_TIMEOUT}s"
}

wait_for_rollout() {
  local api_image api_init_image web_image
  if ! kubectl -n "$NAMESPACE" wait externalsecret/db-credentials externalsecret/app-secrets \
    --for=condition=Ready --timeout=300s; then
    kubectl -n "$NAMESPACE" describe externalsecret db-credentials app-secrets >&2 || :
    die "the ExternalSecrets did not become Ready (ClusterSecretStore $CONTRACT_SECRET_STORE and the Key Vault secrets of tx02v2)"
  fi
  api_image="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')"
  api_init_image="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="migrate")].image}')"
  web_image="$(kubectl -n "$NAMESPACE" get deployment web -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].image}')"
  [[ "$api_image" == "$API_IMAGE" && "$api_init_image" == "$API_IMAGE" && "$web_image" == "$WEB_IMAGE" ]] ||
    die "Argo CD did not apply the requested immutable images (api=$api_image migrate=$api_init_image web=$web_image)"
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=600s
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=600s
}

wait_for_gateway() {
  local route health
  if ! kubectl -n "$NAMESPACE" wait gateway/dx02v2 --for=condition=Programmed --timeout=600s; then
    kubectl -n "$NAMESPACE" describe gateway dx02v2 >&2 || :
    die "the Gateway was not programmed in 10 minutes (ALB Controller of tx02v2, agc/id and agc/frontend-name; see the events above)"
  fi
  GATEWAY_ADDRESS="$(kubectl -n "$NAMESPACE" get gateway dx02v2 -o jsonpath='{.status.addresses[0].value}')"
  [[ "$GATEWAY_ADDRESS" =~ ^[A-Za-z0-9.-]+$ ]] || die "the programmed Gateway has no frontend address"
  if [[ "$OVERLAY" == azure-waf ]]; then
    if ! kubectl -n "$NAMESPACE" wait "$WAF_RESOURCE/dx02v2" --for=condition=Accepted --timeout=300s; then
      kubectl -n "$NAMESPACE" describe "$WAF_RESOURCE" dx02v2 >&2 || :
      die "the WebApplicationFirewallPolicy was not accepted (SecurityPolicy of the AGC in tx02v2; see the events above)"
    fi
  fi
  route="$(kubectl -n "$NAMESPACE" get httproute dx02v2 -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  health="$(kubectl -n "$NAMESPACE" get healthcheckpolicy.alb.networking.azure.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Accepted")].status} {end}')"
  log "Gateway programmed at $GATEWAY_ADDRESS; HTTPRoute accepted: ${route:-unknown}; HealthCheckPolicy accepted: ${health:-unknown}"
}

smoke() {
  local status=0
  BASE="http://$GATEWAY_ADDRESS"
  # The admin token is a credential: the frontend of the AGC answers plain HTTP only (HTTPS in the
  # clouds is outside the scope of v2), so the token is neither read nor sent, and the smoke test skips
  # the one call that needs it (SKIP in the summary). The checks that send a made-up token still run.
  log "the entry point is plain HTTP: the admin token is not read, and the smoke test skips the DELETE that needs it"
  # SMOKE_EDGE=agc: AGC routes /api straight to the API and assigns its own X-Request-Id; the WAF
  # policy inspects bodies up to 128 KB, so the API itself answers 413 for the 70 KB body.
  BASE_URL="$BASE" ADMIN_TOKEN="" SMOKE_EDGE=agc SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-900}" \
    node "$REPO_ROOT/e2e/smoke.mjs" | tee "$WORK_DIR/smoke.txt" || status=$?
  ((status == 0)) || die "the smoke test through Application Gateway for Containers failed (FAIL lines above)"
}

main() {
  (($# == 0)) || die "usage: $0 (configuration through environment variables, see the header)"
  preflight
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  section "contract: App Configuration ${APPCONFIG_PREFIX}*"
  read_contract
  section "cluster $(param cluster-name): kubeconfig, platform API groups, RBAC"
  connect_cluster
  section "registry $ACR_NAME: promote verified image digests"
  publish_images
  section "ConfigMap azure-pg-ca (Azure root CAs, thumbprints checked)"
  create_pg_ca
  if [[ "$DEPLOY_MODE" == gitops ]]; then
    section "publish and sync GitOps revision gitops/azure"
    render_gitops_source
    configure_gitops_application
    publish_gitops_revision
    wait_for_gitops
  else
    section "kubectl apply -k deploy/k8s/overlays/$OVERLAY (direct push alternative)"
    render_and_apply
  fi
  section "ExternalSecrets and rollouts"
  wait_for_rollout
  section "Gateway (Application Gateway for Containers)"
  wait_for_gateway
  section "smoke test through Application Gateway for Containers"
  smoke
  log "deploy of $GIT_SHA complete: $BASE"
}

main "$@"
