#!/usr/bin/env bash
# Generates the kubeconform JSON schemas in deploy/k8s/schemas from the CRDs that the ALB Controller
# of Application Gateway for Containers installs on the tx02v2 cluster: Gateway and HTTPRoute
# (Gateway API bundle of the controller) and HealthCheckPolicy and WebApplicationFirewallPolicy
# (alb.networking.azure.io). The CRDs come from the official image
# mcr.microsoft.com/application-lb/images/alb-controller-crds, fetched with the OCI registry API
# (anonymous pull) and verified by digest at every step; no Docker needed.
# Usage:
#   scripts/update-crd-schemas.sh --check     regenerate into a temporary dir and compare with the
#                                             committed files (harness check crd-schemas)
#   scripts/update-crd-schemas.sh <version>   pin another ALB Controller version (e.g. 1.12.2):
#                                             resolves its digest, rewrites source.env and the schemas
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SCHEMA_DIR="$REPO_ROOT/deploy/k8s/schemas"
SOURCE_FILE="$SCHEMA_DIR/source.env"
REGISTRY=https://mcr.microsoft.com
REPOSITORY=application-lb/images/alb-controller-crds
# The CRDs are the same on every platform of the image; read the linux/amd64 one.
PLATFORM_OS=linux
PLATFORM_ARCH=amd64
# CRD files inside the image (directory /alb-controller-crds) for the kinds the manifests use.
CRD_FILES=(
  gateway-api-crds/gateway.networking.k8s.io_gateways.yaml
  gateway-api-crds/gateway.networking.k8s.io_httproutes.yaml
  agc-crds/alb.networking.azure.io_healthcheckpolicy.yaml
  extra-crds/alb.networking.azure.io_webapplicationfirewallpolicy.yaml
)
INDEX_TYPES='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
MANIFEST_TYPES='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

WORK_DIR=""
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

usage() {
  echo "usage: $0 --check | <alb-controller-version>" >&2
  exit 2
}

# fetch PATH ACCEPT OUT -> GET $REGISTRY/v2/$REPOSITORY/PATH (HTTPS only, redirects to HTTPS only).
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -H "Accept: $2" -o "$3" "$REGISTRY/v2/$REPOSITORY/$1" || die "download failed: $REGISTRY/v2/$REPOSITORY/$1"
}

# verify FILE DIGEST -> refuses content whose sha256 differs from the digest that named it.
verify() {
  [[ "sha256:$(sha256_of "$1")" == "$2" ]] || die "digest mismatch for $2: refusing the download"
}

# json_get FILE EXPRESSION -> prints the result of a small JavaScript expression over the JSON in FILE (`j`).
json_get() {
  node -e 'const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const r = eval(process.argv[2]); console.log(Array.isArray(r) ? r.join("\n") : r);' "$1" "$2"
}

# extract_crds INDEX_DIGEST DEST -> every CRD_FILES entry of the image as DEST/alb-controller-crds/<file>.
# Layers are read from the top down and only until every file is found: the topmost copy of a file
# is the one the container sees (OCI layer order), and the CRDs live in the small top layer.
extract_crds() {
  local index=$1 dest=$2 manifest layer media i=0 f path missing
  local -a layers=()
  declare -A found=()
  fetch "manifests/$index" "$INDEX_TYPES" "$WORK_DIR/index.json"
  verify "$WORK_DIR/index.json" "$index"
  manifest="$(json_get "$WORK_DIR/index.json" "(j.manifests.find((m) => m.platform?.os === '$PLATFORM_OS' && m.platform?.architecture === '$PLATFORM_ARCH') ?? {}).digest ?? ''")"
  [[ "$manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no $PLATFORM_OS/$PLATFORM_ARCH manifest in $index"
  fetch "manifests/$manifest" "$MANIFEST_TYPES" "$WORK_DIR/manifest.json"
  verify "$WORK_DIR/manifest.json" "$manifest"
  # shellcheck disable=SC2016 # a JavaScript template literal, not a shell expansion
  mapfile -t layers < <(json_get "$WORK_DIR/manifest.json" 'j.layers.map((l) => `${l.digest} ${l.mediaType}`).reverse()')
  mkdir -p "$dest"
  for layer in "${layers[@]}"; do
    media=${layer#* }
    layer=${layer%% *}
    case "$media" in
      application/vnd.oci.image.layer.v1.tar+gzip | application/vnd.docker.image.rootfs.diff.tar.gzip) ;;
      *) die "unsupported layer media type $media in $manifest" ;;
    esac
    i=$((i + 1))
    fetch "blobs/$layer" '*/*' "$WORK_DIR/layer-$i.tgz"
    verify "$WORK_DIR/layer-$i.tgz" "$layer"
    tar -tzf "$WORK_DIR/layer-$i.tgz" >"$WORK_DIR/layer-$i.list"
    for f in "${CRD_FILES[@]}"; do
      [[ -z "${found[$f]:-}" ]] || continue
      path="alb-controller-crds/$f"
      if grep -qxF "$path" "$WORK_DIR/layer-$i.list"; then
        tar -xzf "$WORK_DIR/layer-$i.tgz" -C "$dest" --no-same-owner "$path"
        found[$f]=$layer
      elif grep -qE '^alb-controller-crds/(.*/)?\.wh\.' "$WORK_DIR/layer-$i.list"; then
        die "layer $layer deletes files under /alb-controller-crds (whiteout): read the image by hand"
      fi
    done
    missing=0
    for f in "${CRD_FILES[@]}"; do
      [[ -n "${found[$f]:-}" ]] || missing=$((missing + 1))
    done
    ((missing > 0)) || break
  done
  for f in "${CRD_FILES[@]}"; do
    [[ -n "${found[$f]:-}" ]] || die "the image $index has no /alb-controller-crds/$f"
  done
  log "read ${#CRD_FILES[@]} CRD files from $i of ${#layers[@]} layers of $manifest ($PLATFORM_OS/$PLATFORM_ARCH)"
}

# generate INDEX_DIGEST OUT_DIR -> OUT_DIR/<group>/<kind>_<version>.json for every CRD_FILES entry.
generate() {
  local index=$1 out=$2 f
  local -a crds=()
  extract_crds "$index" "$WORK_DIR/image"
  for f in "${CRD_FILES[@]}"; do
    crds+=("$WORK_DIR/image/alb-controller-crds/$f")
  done
  log "Gateway API bundle: $(grep -hoE 'gateway.networking.k8s.io/(bundle-version|channel): [^ ]+' "${crds[@]:0:2}" | sort -u | sed 's/.*\///' | tr '\n' ' ')"
  mkdir -p "$out"
  node "$REPO_ROOT/scripts/crd-to-jsonschema.mjs" "$out" "${crds[@]}"
}

# generated_files DIR -> the schema files under DIR, relative and sorted.
generated_files() {
  (cd "$1" && find . -type f -name '*.json' | sed 's|^\./||' | sort)
}

check() {
  local version index
  require_cmd curl node tar
  [[ -f "$SOURCE_FILE" ]] || die "missing $SOURCE_FILE"
  version="$(env_file_value "$SOURCE_FILE" ALB_CONTROLLER_VERSION)"
  index="$(env_file_value "$SOURCE_FILE" ALB_CRDS_INDEX_DIGEST)"
  [[ "$index" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$SOURCE_FILE: ALB_CRDS_INDEX_DIGEST must be sha256:<64 hex>"
  log "ALB Controller $version: $REGISTRY/$REPOSITORY@$index"
  generate "$index" "$WORK_DIR/generated" >"$WORK_DIR/generated.list"
  if [[ "$(generated_files "$WORK_DIR/generated")" != "$(generated_files "$SCHEMA_DIR")" ]]; then
    diff <(generated_files "$WORK_DIR/generated") <(generated_files "$SCHEMA_DIR") >&2 || :
    die "deploy/k8s/schemas holds other files than the generator writes (run scripts/update-crd-schemas.sh $version)"
  fi
  if ! diff -r -x source.env "$WORK_DIR/generated" "$SCHEMA_DIR" >"$WORK_DIR/diff.txt"; then
    head -n 40 "$WORK_DIR/diff.txt" >&2
    die "deploy/k8s/schemas differs from the generator output (never edit it by hand; run scripts/update-crd-schemas.sh $version)"
  fi
  printf 'SUMMARY: %s schemas identical to the CRDs of ALB Controller %s (%s)\n' \
    "$(wc -l <"$WORK_DIR/generated.list" | tr -d ' ')" "$version" "$(tr '\n' ' ' <"$WORK_DIR/generated.list" | sed 's/ $//')"
}

update() {
  local version=$1 index tmp
  require_cmd curl node tar
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.12.2 (got '$version')"
  fetch "manifests/$version" "$INDEX_TYPES" "$WORK_DIR/tag-index.json"
  index="sha256:$(sha256_of "$WORK_DIR/tag-index.json")"
  log "ALB Controller $version: $REGISTRY/$REPOSITORY:$version = $index"
  generate "$index" "$WORK_DIR/generated"
  tmp="$(mktemp "$SCHEMA_DIR/.source.env.XXXXXX")"
  awk -v v="$version" -v d="$index" '
    /^ALB_CONTROLLER_VERSION=/ { print "ALB_CONTROLLER_VERSION=" v; next }
    /^ALB_CRDS_INDEX_DIGEST=/ { print "ALB_CRDS_INDEX_DIGEST=" d; next }
    { print }
  ' "$SOURCE_FILE" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SOURCE_FILE"
  find "$SCHEMA_DIR" -type f -name '*.json' -delete
  find "$SCHEMA_DIR" -mindepth 1 -type d -empty -delete
  cp -R "$WORK_DIR/generated/." "$SCHEMA_DIR/"
  log "updated deploy/k8s/schemas to ALB Controller $version; next: update the date in source.env,"
  log "HARNESS_STRICT=1 make verify, and the calendar in docs/SUSTENTACAO.md (same version as tx02v2)."
}

main() {
  (($# == 1)) || usage
  WORK_DIR="$(mktemp -d)"
  case "$1" in
    --check) check ;;
    -*) usage ;;
    *) update "$1" ;;
  esac
}

main "$@"
