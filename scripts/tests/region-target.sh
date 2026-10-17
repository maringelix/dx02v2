#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
# shellcheck source=scripts/lib/region-target.sh
source "$REPO_ROOT/scripts/lib/region-target.sh"
select_region_target primary
[[ "$GITOPS_BRANCH" == gitops/azure && "$CONTRACT_CLUSTER" == tx02v2-lab ]]
select_region_target secondary
[[ "$GITOPS_BRANCH" == gitops/azure-dr && "$CONTRACT_CLUSTER" == tx02v2-lab-dr ]]
if (select_region_target unrelated) >/dev/null 2>&1; then die 'arbitrary target accepted'; fi
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
sed -e 's/tx02v2lab0a1b2c3d\.azurecr/tx02v2lab0a1b2c3ddr.azurecr/g' \
  -e 's/tx02v2-lab-db-app/tx02v2-lab-dr-db-app/g' \
  -e 's/tx02v2-lab-app-admin-token/tx02v2-lab-dr-app-admin-token/g' \
  "$K8S_PARAMS_EXAMPLE" >"$work/dr.env"
k8s_render azure-full "$work/dr.env" >"$work/dr.yaml"
k8s_render azure-full >"$work/example.yaml"
node --input-type=module - "$work/dr.yaml" <<'JS'
import fs from 'node:fs';
import YAML from 'yaml';
const docs = YAML.parseAllDocuments(fs.readFileSync(process.argv[2], 'utf8')).map((d) => d.toJSON());
for (const doc of docs.filter((d) => d?.kind === 'ExternalSecret')) {
  if (doc.spec.data.some((entry) => !entry.remoteRef.key.startsWith('tx02v2-lab-dr-'))) {
    throw new Error('primary secret leaked into the standby render');
  }
}
JS
node "$REPO_ROOT/scripts/render-gitops-application.mjs" azure azure-full "$work/dr.env" "$K8S_PARAMS_EXAMPLE" >"$work/application.json"
jq -e '.spec.source.targetRevision == "gitops/azure-dr"' "$work/application.json" >/dev/null
node "$REPO_ROOT/scripts/check-gitops-renderer.mjs" "$work/application.json" "$work/example.yaml"
echo 'PASS regional targets, secret references, GitOps branch and valid Application overrides'
