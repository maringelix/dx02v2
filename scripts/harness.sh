#!/usr/bin/env bash
# dx02v2 harness: every check lives here. `make` targets and every CI job only call this script.
# Usage: scripts/harness.sh <stage>...   stages: static, test, build, e2e, platform, platform-small, all, list
#   HARNESS_STRICT=1   (set in CI) turns every SKIP into a FAIL
#   HARNESS_VERBOSE=1  also prints the output of passing checks
#   HARNESS_ONLY=<re>  runs only the checks whose name matches (local debugging; never in CI)
#   HARNESS_WORK_DIR   scratch dir for logs, rendered manifests and caches (default: $TMPDIR/dx02v2-harness)
#   DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD  database for the API integration tests; when
#                      DB_HOST is unset, a throwaway postgres:17-alpine container is started
#   IMAGE_TAG          tag of the images built/scanned/loaded (default: e2e)
#   IMAGES_PREBUILT=1  stage build: check images built elsewhere (CI) instead of building them
#   E2E_SKIP_BUILD=1, KEEP_CLUSTER=1: see scripts/e2e-kind.sh; TX02V2_DIR, TX02V2_REPO, KEEP_LAB=1: scripts/e2e-platform.sh
#   SMALL_MEMORY: scripts/e2e-platform-small.sh
# Prints "PASS|FAIL|SKIP <check> (<secs>s)" per check and a summary; exits 1 on any FAIL.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "$REPO_ROOT/scripts/lib/tools.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"

export PATH="$REPO_ROOT/.tools/bin:$PATH"

HARNESS_STRICT="${HARNESS_STRICT:-0}"
HARNESS_VERBOSE="${HARNESS_VERBOSE:-0}"
HARNESS_WORK_DIR="${HARNESS_WORK_DIR:-${TMPDIR:-/tmp}/dx02v2-harness}"
HARNESS_ONLY="${HARNESS_ONLY:-}"
IMAGE_TAG="${IMAGE_TAG:-e2e}"
IMAGES_PREBUILT="${IMAGES_PREBUILT:-0}"

# Pinned schema sources of kubeconform (update procedure: docs/SUSTENTACAO.md). The Gateway API and
# Application Gateway for Containers schemas are generated into deploy/k8s/schemas from the CRDs of
# the pinned ALB Controller (scripts/update-crd-schemas.sh) and take precedence over the catalog.
K8S_SCHEMA_KUBERNETES_VERSION="1.36.0"
K8S_SCHEMA_REF="5f1fa4f7908afc9b6641c62d282a4a22437626e1" # yannh/kubernetes-json-schema
CRD_SCHEMA_REF="63669a570e231d4f1f8396d229a1de512bcf0a34" # datreeio/CRDs-catalog, 2026-10-08 (ESO 2.12 schemas)
# Throwaway database for the API integration tests (same digest as compose.yaml and ci.yml).
TEST_POSTGRES_IMAGE="postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"
# Scanner ignores must be reviewed at least every ~7 months.
TRIVYIGNORE_MAX_DAYS=214
# The contract (docs/CONTRATO.md): every App Configuration key under tx02v2/lab/ that the deploy reads.
CONTRACT_APPCONFIG_KEYS=(
  location resource-group cluster-name vnet-cidr agc-subnet-cidr postgres-subnet-cidr acr/login-server
  keyvault/uri db/secret-name app/admin-token-secret-name eso/cluster-secret-store agc/id agc/frontend-name
  waf/policy-id deploy/principal-id
)
# Contract: SHA-1 thumbprints of the Azure root CAs in the ConfigMap azure-pg-ca.
CONTRACT_PG_CA_THUMBPRINTS=(
  DF3C24F9BFD666761B268073FE06D1CC8D4F82A4 # DigiCert Global Root G2
  73A5E64A3BFF8316FF0EDCCC618A906E4EAE4D74 # Microsoft RSA Root Certificate Authority 2017
  999A64C37FF47D9FAB95F14769891460EEC4C3C5 # Microsoft ECC Root Certificate Authority 2017
)

REQUIRED_FILES=(
  README.md README.pt-BR.md AGENTS.md CLAUDE.md CONTRIBUTING.md SECURITY.md CHANGELOG.md LICENSE FORK.md
  .editorconfig .gitattributes .gitignore .pre-commit-config.yaml Makefile .trivyignore.yaml
  .nvmrc .npmrc .prettierrc .prettierignore eslint.config.js package.json package-lock.json
  .dockerignore api/Dockerfile api/Dockerfile.dockerignore web/Dockerfile web/Dockerfile.dockerignore
  compose.yaml .env.example kind/kind-config.yaml e2e/smoke.mjs
  .devcontainer/devcontainer.json
  .github/CODEOWNERS .github/dependabot.yml .github/pull_request_template.md
  .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/cloud_run_report.yml
  .github/workflows/ci.yml .github/workflows/deploy-azure.yml .github/rulesets/main.json
  docs/SUSTENTACAO.md docs/GUARDRAILS.md docs/HARNESS.md docs/CONTRATO.md docs/RUNBOOK.md
  docs/ARQUITETURA.md docs/API.md docs/PUBLICACAO.md
  tools/versions.env tools/checksums.txt
  scripts/install-tools.sh scripts/update-tool-checksums.sh scripts/harness.sh scripts/repo-guardrails.sh
  scripts/dev-env.sh scripts/compose-smoke.sh scripts/e2e-kind.sh scripts/deploy-azure.sh scripts/render-k8s.sh
  scripts/update-crd-schemas.sh scripts/crd-to-jsonschema.mjs scripts/check-manifests.mjs
  scripts/publish-gitops.sh scripts/render-gitops-application.mjs scripts/check-gitops-renderer.mjs
  deploy/k8s/components/azure/params.example.env deploy/k8s/schemas/source.env
  deploy/k8s/overlays/azure/gitops-revision.yaml deploy/k8s/overlays/azure-waf/gitops-revision.yaml
)
STABLE_CI_JOBS=(static test images e2e e2e-platform)

# ---------------------------------------------------------------------------------------------
# Check registry and helpers
# ---------------------------------------------------------------------------------------------

declare -a CHECK_STAGE=() CHECK_NAME=() CHECK_CMD=()
register() {
  CHECK_STAGE+=("$1")
  CHECK_NAME+=("$2")
  CHECK_CMD+=("$3")
}

strict() { [[ "$HARNESS_STRICT" == 1 ]]; }

# skip REASON -> ends the current check as SKIP (FAIL in strict mode). Only for missing preconditions.
# Exit code 77 (the automake SKIP convention) never collides with the tools' own codes.
SKIP_CODE=77
skip() {
  printf 'SKIP_REASON: %s\n' "$*"
  exit "$SKIP_CODE"
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || skip "'$c' not found (run: make tools; Node.js 24 comes from .nvmrc/devcontainer)"
  done
}

need_docker() {
  need docker
  docker info >/dev/null 2>&1 || skip "docker is installed but the daemon is not reachable"
}

# summary TEXT -> one line the runner prints even for passing checks (counts, coverage).
summary() { printf 'SUMMARY: %s\n' "$*"; }

# visible_files -> files git would track (tracked + untracked, minus .gitignore), one per line.
visible_files() {
  git ls-files --cached --others --exclude-standard
}

# forbid REGEX MESSAGE GLOB PATH... -> fails when the extended regex matches in the files named
# GLOB ('*' for all) under PATH (recursive).
forbid() {
  local re=$1 msg=$2 glob=$3 out status=0
  shift 3
  out="$(grep -rnIE --include="$glob" --exclude-dir=node_modules --exclude-dir=dist -e "$re" -- "$@")" || status=$?
  ((status <= 1)) || {
    echo "grep failed with status $status"
    return 1
  }
  if [[ -n "$out" ]]; then
    printf 'forbidden: %s\n%s\n' "$msg" "$out"
    return 1
  fi
}

date_plus_days() {
  date -u -d "+$1 days" +%F 2>/dev/null || date -u -v+"$1"d +%F
}

installed_version() {
  local out=""
  case "$1" in
    trivy) out="$(trivy --version 2>/dev/null)" || out="" ;;
    hadolint) out="$(hadolint --version 2>/dev/null)" || out="" ;;
    actionlint) out="$(actionlint -version 2>/dev/null)" || out="" ;;
    shellcheck) out="$(shellcheck --version 2>/dev/null)" || out="" ;;
    kubeconform) out="$(kubeconform -v 2>/dev/null)" || out="" ;;
    gitleaks) out="$(gitleaks version 2>/dev/null)" || out="" ;;
    kind) out="$(kind version 2>/dev/null)" || out="" ;;
    kubectl) out="$(kubectl version --client 2>/dev/null)" || out="" ;;
    kubelogin) out="$(kubelogin --version 2>/dev/null)" || out="" ;;
    promtool) out="$(promtool --version 2>/dev/null)" || out="" ;;
  esac
  [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

git_sha() {
  git rev-parse --verify -q HEAD 2>/dev/null || printf 'unknown'
}

image_ref() { printf 'dx02v2-%s:%s' "$1" "$IMAGE_TAG"; }

# render_overlays DIR -> DIR/<overlay>.yaml for every overlay (azure ones with the example params).
render_overlays() {
  local dir=$1 overlay
  mkdir -p "$dir"
  for overlay in "${K8S_OVERLAYS[@]}"; do
    k8s_render "$overlay" >"$dir/$overlay.yaml"
  done
}

# ---------------------------------------------------------------------------------------------
# Static checks (each runs in its own subshell from the repository root)
# ---------------------------------------------------------------------------------------------

check_tool_versions() {
  local t want got node_want node_got
  local -a missing=() mismatch=()
  load_versions
  for t in "${TOOLS_ALL[@]}"; do
    want="$(tool_version "$t")"
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
      continue
    fi
    got="$(installed_version "$t")"
    printf '%-12s want %-8s got %-8s %s\n' "$t" "$want" "${got:-?}" "$(command -v "$t")"
    [[ "$got" == "$want" ]] || mismatch+=("$t")
  done
  node_want="$(tr -d '[:space:]' <.nvmrc)"
  if command -v node >/dev/null 2>&1; then
    node_got="$(node --version)"
    printf '%-12s want %-8s got %-8s %s\n' node "$node_want.x" "$node_got" "$(command -v node)"
    [[ "$node_got" =~ ^v${node_want}\. ]] || mismatch+=(node)
  else
    missing+=(node)
  fi
  ((${#missing[@]} == 0)) || skip "missing tools: ${missing[*]} (run: make tools; Node.js $node_want from .nvmrc)"
  if ((${#mismatch[@]} > 0)); then
    strict && {
      echo "versions differ from tools/versions.env / .nvmrc: ${mismatch[*]}"
      return 1
    }
    skip "versions differ from tools/versions.env / .nvmrc: ${mismatch[*]} (run: make tools)"
  fi
}

check_repo_structure() {
  local f rc=0
  for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "$f" ]] || {
      echo "missing required file: $f"
      rc=1
    }
  done
  if [[ -f CLAUDE.md ]]; then
    [[ "$(sed -n 1p CLAUDE.md)" == "@AGENTS.md" ]] || {
      echo "CLAUDE.md: the first line must be @AGENTS.md"
      rc=1
    }
    (($(grep -c . CLAUDE.md) == 2)) || {
      echo "CLAUDE.md: must contain exactly @AGENTS.md and one sentence"
      rc=1
    }
  fi
  if [[ -f README.md ]] && (($(wc -l <README.md) > 250)); then
    echo "README.md: more than 250 lines"
    rc=1
  fi
  forbid 'production-grade|production-ready|enterprise|best-in-class|world-class|battle-tested' "self-ratings in the READMEs" '*' README.md README.pt-BR.md || rc=1
  grep -qF 'not run in the cloud (v2)' README.md || {
    echo "README.md: the status matrix must use the label 'not run in the cloud (v2)'"
    rc=1
  }
  grep -qF 'não executado em nuvem (v2)' README.pt-BR.md || {
    echo "README.pt-BR.md: the status matrix must use the label 'não executado em nuvem (v2)'"
    rc=1
  }
  need git
  grep -qP 'x' <<<"x" 2>/dev/null || skip "grep -P (PCRE) is not available"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if grep -q $'\r' "$f"; then
      echo "CRLF line endings (LF required): $f"
      rc=1
    fi
    # v1 shipped UTF-16 manifests: every file is UTF-8 without a byte order mark (and no NUL bytes).
    if LC_ALL=C grep -qaP '\x00' "$f" || [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then
      echo "not UTF-8 without BOM (UTF-16, BOM or NUL bytes): $f"
      rc=1
    fi
  done < <(visible_files)
  # Entry-point scripts must keep the executable bit in git (commits from Windows can drop it).
  while IFS= read -r f; do
    [[ "$(git ls-files -s -- "$f" | awk '{ print $1 }')" == 100755 ]] || {
      echo "not executable in the git index (git update-index --chmod=+x $f): $f"
      rc=1
    }
  done < <(git ls-files -- 'scripts/*.sh' | grep -v '^scripts/lib/')
  return "$rc"
}

# Versions that must agree across files (Node, PostgreSQL, kind/kubectl, exact npm pins).
check_version_consistency() {
  local rc=0 nvmrc engines f pg_digests node_from kind_minor kubectl_minor schema_minor
  load_versions
  nvmrc="$(tr -d '[:space:]' <.nvmrc)"
  [[ "$nvmrc" =~ ^[0-9]+$ ]] || {
    echo ".nvmrc must hold a major version only (got '$nvmrc')"
    rc=1
  }
  for f in package.json api/package.json web/package.json; do
    engines="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).engines?.node ?? "")' "$f")"
    [[ "$engines" == ">=$nvmrc <$((nvmrc + 1))" ]] || {
      echo "$f: engines.node must be '>=$nvmrc <$((nvmrc + 1))' (got '$engines')"
      rc=1
    }
  done
  # Exact versions only: a range in package.json would make the lockfile the only pin.
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  node -e '
    const fs = require("fs");
    let bad = 0;
    for (const file of process.argv.slice(1)) {
      const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
      for (const section of ["dependencies", "devDependencies", "optionalDependencies"]) {
        for (const [name, spec] of Object.entries(pkg[section] ?? {})) {
          if (!/^\d+\.\d+\.\d+$/.test(spec)) { console.log(`${file}: ${section}.${name} must be an exact version (got ${spec})`); bad = 1; }
        }
      }
    }
    process.exit(bad);
  ' package.json api/package.json web/package.json || rc=1
  node_from="$(grep -hoE '^FROM node:[^ ]+' api/Dockerfile web/Dockerfile | sort -u)"
  (($(wc -l <<<"$node_from") == 1)) || {
    printf 'both Dockerfiles must use the same node build image:\n%s\n' "$node_from"
    rc=1
  }
  [[ "$node_from" == "FROM node:${nvmrc}-alpine"* ]] || {
    echo "the build image must be node:${nvmrc}-alpine* (.nvmrc), got: $node_from"
    rc=1
  }
  pg_digests="$(grep -hoE 'postgres:17-alpine@sha256:[0-9a-f]{64}' compose.yaml .github/workflows/ci.yml deploy/k8s/overlays/local/postgres.yaml scripts/harness.sh | sort -u)"
  (($(wc -l <<<"$pg_digests") == 1)) || {
    printf 'compose.yaml, ci.yml, the local overlay and the harness must pin the same postgres:17-alpine digest:\n%s\n' "$pg_digests"
    rc=1
  }
  kind_minor="$(grep -oE 'kindest/node:v[0-9]+\.[0-9]+' kind/kind-config.yaml | sed 's/.*:v//')"
  kubectl_minor="${KUBECTL_VERSION%.*}"
  schema_minor="${K8S_SCHEMA_KUBERNETES_VERSION%.*}"
  [[ -n "$kind_minor" && "$kind_minor" == "$kubectl_minor" && "$kind_minor" == "$schema_minor" ]] || {
    echo "kind node image ($kind_minor), kubectl ($kubectl_minor) and kubeconform schemas ($schema_minor) must share the Kubernetes minor"
    rc=1
  }
  grep -qE "^  - role: control-plane$" kind/kind-config.yaml || {
    echo "kind/kind-config.yaml must declare the control-plane node"
    rc=1
  }
  return "$rc"
}

check_policy_identifiers() {
  local rc=0 out
  local -a files=()
  need git
  grep -qP 'x' <<<"x" 2>/dev/null || skip "grep -P (PCRE) is not available"
  # Lockfile, tool checksums and the schemas generated from pinned upstream CRDs (check crd-schemas)
  # hold hashes and upstream examples, not identifiers of this lab.
  mapfile -t files < <(visible_files | grep -vE '(^|/)(package-lock\.json|checksums\.txt)$|^deploy/k8s/schemas/')
  ((${#files[@]} > 0)) || return 0
  out="$(grep -noP '(?<![0-9A-Za-z-])[0-9]{12}(?![0-9A-Za-z-])' "${files[@]}" | grep -v ':123456789012$')" || true
  [[ -z "$out" ]] || {
    printf '12-digit account IDs must be the placeholder 123456789012:\n%s\n' "$out"
    rc=1
  }
  out="$(grep -noP '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' "${files[@]}" |
    grep -vP '@(example\.(com|org|net)|users\.noreply\.github\.com)$')" || true
  [[ -z "$out" ]] || {
    printf 'e-mail addresses must use example.com/example.org placeholders:\n%s\n' "$out"
    rc=1
  }
  out="$(grep -noP '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])' "${files[@]}" |
    grep -vP ':(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.0\.0\.0)')" || true
  [[ -z "$out" ]] || {
    printf 'IP addresses must be private or documentation ranges (RFC 1918 / RFC 5737):\n%s\n' "$out"
    rc=1
  }
  # Azure subscription, tenant, client and object IDs are GUIDs: only the all-zero placeholder, plus
  # the UUID test vector of the API request-id unit test (not an Azure identifier).
  out="$(grep -noiP '(?<![0-9a-z-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-z-])' "${files[@]}" |
    grep -v ':00000000-0000-0000-0000-000000000000$' |
    grep -vE '^api/test/unit/request-id\.test\.ts:[0-9]+:0f8fad5b[-]d9cb[-]469f[-]a165[-]70867728950e$')" || true
  [[ -z "$out" ]] || {
    printf 'GUIDs (subscription, tenant, client, object IDs) must be the placeholder 00000000-0000-0000-0000-000000000000:\n%s\n' "$out"
    rc=1
  }
  # The globally unique tx02v2 names end in substr(sha1(<subscription_id>), 0, 8) (docs/CONTRATO.md).
  out="$(grep -noP 'tx02v2-?lab-?[0-9a-f]{8}(?![0-9a-z])' "${files[@]}" | grep -vE ':tx02v2-?lab-?00000000$')" || true
  [[ -z "$out" ]] || {
    printf 'ACR, Key Vault and App Configuration names must use the 00000000 suffix placeholder:\n%s\n' "$out"
    rc=1
  }
  return "$rc"
}

# Nothing of another cloud may remain: dx02v2 started as a copy of the AWS app dx01v2. Only the
# docs that compare the lab family (README, ARQUITETURA, CHANGELOG) may name that cloud; this file
# and scripts/check-manifests.mjs hold the patterns themselves.
check_policy_cloud() {
  local rc=0 out
  local -a files=()
  need git
  out="$(visible_files | grep -iE '(^|[/._-])aws([/._-]|$)')" || true
  [[ -z "$out" ]] || {
    printf 'files of another cloud path:\n%s\n' "$out"
    rc=1
  }
  mapfile -t files < <(visible_files | grep -vxE 'README(\.pt-BR)?\.md|docs/ARQUITETURA\.md|CHANGELOG\.md|scripts/harness\.sh|scripts/check-manifests\.mjs|package-lock\.json')
  ((${#files[@]} > 0)) || return 0
  out="$(grep -nHiE '(^|[^a-z0-9])(aws|eks|ecr|rds|ssm|vpc|acm|cloudwatch|route ?53)([^a-z0-9]|$)|amazon|wafv2|elbv2|alb\.ingress|secrets manager|us-(east|west)-[12]|tx01v2' "${files[@]}")" || true
  [[ -z "$out" ]] || {
    printf 'leftovers of another cloud (dx02v2 is the Azure app; see docs/ARQUITETURA.md for the comparison):\n%s\n' "$out"
    rc=1
  }
  summary "no leftovers of another cloud in ${#files[@]} files (README, ARQUITETURA and CHANGELOG compare the lab family)"
  return "$rc"
}

check_policy_workflows() {
  local f rc=0 out ctx
  local -a files=()
  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
  ((${#files[@]} > 0)) || {
    echo "no workflows found"
    return 1
  }
  for f in "${files[@]}"; do
    out="$(awk -v file="$f" '
      function err(m) { printf "%s:%d: %s\n", file, NR, m; bad = 1 }
      /^permissions:/ { top_perm = 1; in_top_perm = 1; next }
      in_top_perm && /^  contents: read[[:space:]]*$/ { top_read = 1 }
      in_top_perm && /^[^[:space:]]/ { in_top_perm = 0 }
      /^concurrency:/ { concurrency = 1 }
      /^jobs:/ { in_jobs = 1; next }
      in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); jobs[job] = 1; next }
      in_jobs && /^    timeout-minutes:/ { timeout[job] = 1 }
      in_jobs && /^    runs-on: ubuntu-24\.04[[:space:]]*$/ { runs[job] = 1 }
      /^[[:space:]-]*uses:/ {
        ref = $0; sub(/^[[:space:]-]*uses:[[:space:]]*/, "", ref)
        if (ref ~ /^\.\//) next
        if (ref !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+@[0-9a-f]+[[:space:]]+#[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/) {
          err("pin actions to a full commit SHA with a trailing # vX.Y.Z comment: " ref)
        } else {
          sha = ref; sub(/^[^@]*@/, "", sha); sub(/[[:space:]].*$/, "", sha)
          if (length(sha) != 40) err("the commit SHA must have 40 characters: " ref)
        }
        if (ref ~ /^actions\/checkout@/) checkouts++
      }
      /persist-credentials: false/ { persist++ }
      /continue-on-error:[[:space:]]*true/ { err("continue-on-error: true is forbidden") }
      /\|\|[[:space:]]*(true|echo|:)([[:space:]]|$)/ { err("never swallow errors (|| true, || echo, || :)") }
      /aquasecurity\/(trivy-action|setup-trivy)/ { err("trivy-action/setup-trivy are forbidden; trivy comes from scripts/install-tools.sh") }
      /(^|[[:space:]])(image|uses):[[:space:]]*docker:\/\// { err("docker:// actions are not pinned by these rules; use an image digest in a service") }
      END {
        if (!top_perm || !top_read) { printf "%s: top-level permissions must be exactly contents: read\n", file; bad = 1 }
        if (!concurrency) { printf "%s: a top-level concurrency group is required\n", file; bad = 1 }
        for (j in jobs) {
          if (!timeout[j]) { printf "%s: job %s has no timeout-minutes\n", file, j; bad = 1 }
          if (!runs[j]) { printf "%s: job %s must use runs-on: ubuntu-24.04\n", file, j; bad = 1 }
        }
        if (checkouts != persist) { printf "%s: every actions/checkout needs persist-credentials: false\n", file; bad = 1 }
        exit bad
      }' "$f")" || {
      printf '%s\n' "$out"
      rc=1
    }
  done
  if grep -n 'id-token: write' .github/workflows/ci.yml; then
    echo "ci.yml must never request id-token: write (OIDC is for cloud workflows only)"
    rc=1
  fi
  for ctx in "${STABLE_CI_JOBS[@]}"; do
    grep -qE "^  ${ctx}:[[:space:]]*$" .github/workflows/ci.yml || {
      echo "ci.yml must keep the stable job id '$ctx' (required status check)"
      rc=1
    }
    grep -qF "\"context\": \"$ctx\"" .github/rulesets/main.json || {
      echo ".github/rulesets/main.json must require the status check '$ctx'"
      rc=1
    }
  done
  # v1 lessons: long-lived service principal secrets and workflow inputs pasted into shell.
  if grep -nE '^[[:space:]]*creds:|AZURE_CREDENTIALS|client-secret|ARM_CLIENT_SECRET' "${files[@]}"; then
    echo "Azure access is OIDC only (azure/login with client-id, tenant-id, subscription-id): no service principal secrets"
    rc=1
  fi
  if grep -nE '\$\{\{[[:space:]]*(github\.event\.)?inputs\.' "${files[@]}"; then
    echo "never interpolate workflow inputs into the workflow (pass data through env, validated by the script)"
    rc=1
  fi
  local wf=.github/workflows/deploy-azure.yml v
  if ! grep -qE '^  workflow_dispatch:[[:space:]]*$' "$wf" ||
    grep -qE '^  (push|pull_request|pull_request_target|schedule|workflow_run|workflow_call|repository_dispatch):' "$wf" ||
    grep -qE '^    inputs:' "$wf"; then
    echo "$wf must be workflow_dispatch only, without inputs (cloud workflow)"
    rc=1
  fi
  grep -qE '^    environment: lab$' "$wf" || {
    echo "$wf: the deploy job must use environment: lab (OIDC subject repo:<owner>/dx02v2:environment:lab)"
    rc=1
  }
  grep -qE '^  deploy:[[:space:]]*$' "$wf" || {
    echo "$wf: the job id must stay deploy (docs/PUBLICACAO.md)"
    rc=1
  }
  [[ "$(grep -c 'id-token: write' "$wf")" == 1 && "$(grep -cE '^      id-token: write$' "$wf")" == 1 ]] || {
    echo "$wf: id-token: write exactly once, in the permissions of the deploy job"
    rc=1
  }
  [[ "$(awk '/^    steps:/ { s = 1; next } s && /^      - name:/ { sub(/^      - name:[[:space:]]*/, ""); print; exit }' "$wf")" == 'Check repository variables' ]] || {
    echo "$wf: the first step must be 'Check repository variables'"
    rc=1
  }
  for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_APPCONFIG_ENDPOINT; do
    grep -qF "vars.$v }}" "$wf" || {
      echo "$wf: the variable check must cover vars.$v"
      rc=1
    }
  done
  grep -qE '^      - uses: azure/login@[0-9a-f]{40} # v3\.1\.0$' "$wf" || {
    echo "$wf: azure/login v3.1.0 pinned by commit SHA is required"
    rc=1
  }
  grep -qF 'bash scripts/install-tools.sh kubectl kubelogin' "$wf" || {
    echo "$wf: kubectl and kubelogin must come from scripts/install-tools.sh (.tools)"
    rc=1
  }
  return "$rc"
}

# Every image reference is pinned by digest; our own images are the only exception.
check_policy_images() {
  local rc=0 out
  out="$(grep -nE '^FROM ' api/Dockerfile web/Dockerfile | grep -vE 'FROM [^ ]+@sha256:[0-9a-f]{64}( AS [a-z-]+)?$' | grep -vE 'FROM (deps|build|prod-deps)( AS [a-z-]+)?$')" || true
  [[ -z "$out" ]] || {
    printf 'Dockerfile base images must be pinned by digest:\n%s\n' "$out"
    rc=1
  }
  out="$(grep -rnhE '^[[:space:]-]*image:[[:space:]]' compose.yaml deploy/k8s .github/workflows kind |
    grep -vE '@sha256:[0-9a-f]{64}' | grep -vE 'image:[[:space:]]+dx02v2-(api|web)(:local)?[[:space:]]*$')" || true
  [[ -z "$out" ]] || {
    printf 'images must be pinned by digest (only dx02v2-api/dx02v2-web are built here):\n%s\n' "$out"
    rc=1
  }
  grep -qE '"image": "[^"]+@sha256:[0-9a-f]{64}"' .devcontainer/devcontainer.json || {
    echo ".devcontainer/devcontainer.json: the base image must be pinned by digest"
    rc=1
  }
  if grep -nE '"ghcr.io/devcontainers/features/[^"@]+"' .devcontainer/devcontainer.json | grep -v '@sha256:'; then
    echo ".devcontainer/devcontainer.json: features must be pinned by digest"
    rc=1
  fi
  forbid ':latest([^A-Za-z0-9_.-]|$)' "never use :latest" '*' api/Dockerfile web/Dockerfile compose.yaml deploy kind .github .devcontainer || rc=1
  for f in api/Dockerfile web/Dockerfile; do
    [[ "$(grep -E '^USER ' "$f" | tail -n 1)" =~ ^USER\ [1-9][0-9]*:[1-9][0-9]*$ ]] || {
      echo "$f: the final stage must run as a numeric non-root USER uid:gid"
      rc=1
    }
  done
  return "$rc"
}

# Regressions of v1 that must never come back (docs/ARQUITETURA.md, "v1 -> v2").
check_policy_app() {
  local rc=0
  forbid "trust proxy['\"]?[[:space:]]*,[[:space:]]*true" "trust proxy must be a hop count (TRUST_PROXY_HOPS), never true" '*.ts' api/src || rc=1
  forbid '[[:space:]]style=|dangerouslySetInnerHTML' "no inline styles or raw HTML in the UI (CSP style-src 'self'; text rendered as text)" '*.tsx' web/src || rc=1
  forbid "from ['\"](cors|escape-html|xss|he|sanitize-html)['\"]" "no CORS middleware (same origin) and no HTML escaping before storing" '*.ts' api/src || rc=1
  forbid 'console\.(log|error|warn|info)' "the API logs through pino only" '*.ts' api/src || rc=1
  forbid 'localStorage|sessionStorage|document\.cookie' "the admin token stays in memory only" '*.ts*' web/src || rc=1
  forbid 'Strict-Transport-Security "max-age' "HSTS only through the map (HTTPS requests)" '*.conf' web/nginx || rc=1
  # A destination that is empty must stop the script, not delete what the path then resolves to.
  forbid 'rm -rf "\$[A-Za-z_]+"' "rm -rf of a bare variable in scripts/lib/k8s.sh: use the :? parameter expansion so an empty value stops the script" 'k8s.sh' scripts/lib || rc=1
  local loc includes
  loc="$(grep -cE '^[[:space:]]*location ' web/nginx/default.conf)"
  includes="$(grep -cE '^[[:space:]]*include /etc/nginx/snippets/security-headers\.conf;' web/nginx/default.conf)"
  ((loc > 0 && loc == includes)) || {
    echo "web/nginx/default.conf: every location ($loc) must include the security headers snippet (found $includes)"
    rc=1
  }
  grep -qE '^[[:space:]]*server_tokens off;' web/nginx/default.conf || {
    echo "web/nginx/default.conf: server_tokens off is required"
    rc=1
  }
  return "$rc"
}

check_trivyignore_policy() {
  local today max
  today="$(date -u +%F)"
  max="$(date_plus_days "$TRIVYIGNORE_MAX_DAYS")"
  awk -v today="$today" -v max="$max" '
    function flush() {
      if (id != "") {
        n++
        if (!st) { print "entry " id ": missing a non-empty statement"; bad = 1 }
        if (expiry !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { print "entry " id ": expired_at must be YYYY-MM-DD"; bad = 1 }
        else if (expiry < today) { print "entry " id ": expired on " expiry " (review or remove it)"; bad = 1 }
        else if (expiry > max) { print "entry " id ": expired_at " expiry " is after " max " (at most ~7 months ahead)"; bad = 1 }
        else { print "entry " id ": ok until " expiry }
      }
      id = ""; st = 0; expiry = ""
    }
    /^[[:space:]]*-[[:space:]]+id:/ { flush(); id = $NF; next }
    /^[[:space:]]+statement:[[:space:]]*[^[:space:]]/ { st = 1 }
    /^[[:space:]]+expired_at:/ { expiry = $NF; gsub(/["\047]/, "", expiry) }
    END { flush(); printf "%d ignore entries checked\n", n; exit bad }
  ' .trivyignore.yaml
}

# npm ci when the lockfile changed since the last install (always in strict mode): also proves
# that package-lock.json is in sync with every package.json (v1 shipped an out-of-sync lockfile).
check_npm_ci() {
  local stamp=node_modules/.dx02v2-lock.sha256 want
  need node npm
  want="$(sha256_of package-lock.json)"
  if ! strict && [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]]; then
    echo "node_modules matches package-lock.json ($want); npm ci not needed"
    return 0
  fi
  npm ci --no-audit --no-fund
  printf '%s\n' "$want" >"$stamp"
}

check_eslint() {
  need npx
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  npx --no-install eslint --max-warnings=0 .
}

check_prettier() {
  need npx
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  npx --no-install prettier --check .
}

check_typecheck() {
  need npm
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  npm run --silent typecheck --workspace "$1"
}

check_hadolint() {
  need hadolint
  hadolint --failure-threshold style api/Dockerfile web/Dockerfile
}

check_actionlint() {
  need actionlint shellcheck
  actionlint -shellcheck "$(command -v shellcheck)"
}

check_shellcheck() {
  local -a files=()
  need shellcheck
  mapfile -t files < <(find scripts -type f -name '*.sh' | sort)
  printf 'shellcheck: %s\n' "${files[@]}"
  shellcheck --external-sources --severity=style "${files[@]}"
}

check_kubeconform() {
  local dir="$HARNESS_WORK_DIR/k8s-kubeconform" overlay
  need kubectl kubeconform
  render_overlays "$dir"
  mkdir -p "$HARNESS_WORK_DIR/kubeconform-cache"
  for overlay in "${K8S_OVERLAYS[@]}"; do
    echo "== $overlay"
    kubeconform -strict -summary -output text \
      -kubernetes-version "$K8S_SCHEMA_KUBERNETES_VERSION" \
      -cache "$HARNESS_WORK_DIR/kubeconform-cache" \
      -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMA_REF/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
      -schema-location "$K8S_SCHEMA_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_SCHEMA_REF/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      "$dir/$overlay.yaml" | tee "$dir/$overlay.summary"
  done
  summary "kubeconform -strict (Kubernetes $K8S_SCHEMA_KUBERNETES_VERSION): $(for o in "${K8S_OVERLAYS[@]}"; do printf '%s: %s; ' "$o" "$(grep -oE '[0-9]+ resources found.*' "$dir/$o.summary")"; done)"
}

# The contract (docs/CONTRATO.md): manifests and the deploy script use exactly the agreed names.
check_contract_app() {
  local dir="$HARNESS_WORK_DIR/k8s-contract" rc=0 key keys thumb overlay example deploy=scripts/deploy-azure.sh
  need kubectl node
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  render_overlays "$dir"
  node scripts/check-manifests.mjs --params "$K8S_PARAMS_EXAMPLE" --local-params "$K8S_LOCAL_PARAMS_EXAMPLE" \
    local="$dir/local.yaml" azure="$dir/azure.yaml" azure-waf="$dir/azure-waf.yaml" \
    local-platform="$dir/local-platform.yaml" || rc=1
  # The deploy reads exactly the contract keys (no more, no less) under the contract prefix.
  grep -qxF 'APPCONFIG_PREFIX=tx02v2/lab/' "$deploy" || {
    echo "$deploy must read the App Configuration prefix tx02v2/lab/ (docs/CONTRATO.md)"
    rc=1
  }
  keys="$(awk '/^CONTRACT_KEYS=\(/ { s = 1; next } s && /^\)/ { exit } s { for (i = 1; i <= NF; i++) print $i }' "$deploy" | sort)"
  [[ "$keys" == "$(printf '%s\n' "${CONTRACT_APPCONFIG_KEYS[@]}" | sort)" ]] || {
    printf '%s must read exactly the contract keys; got:\n%s\n' "$deploy" "$keys"
    rc=1
  }
  for key in "CONTRACT_RESOURCE_GROUP=tx02v2-lab" "CONTRACT_CLUSTER=tx02v2-lab" "CONTRACT_DB_SECRET=tx02v2-lab-db-app" \
    "CONTRACT_ADMIN_TOKEN_SECRET=tx02v2-lab-app-admin-token" "CONTRACT_SECRET_STORE=azure-key-vault"; do
    grep -qxF "$key" "$deploy" || {
      echo "$deploy must check $key against App Configuration (docs/CONTRATO.md)"
      rc=1
    }
  done
  for thumb in "${CONTRACT_PG_CA_THUMBPRINTS[@]}"; do
    grep -qE "^  '$thumb https://[^ ']+\.crt'$" "$deploy" || {
      echo "$deploy must download and verify the root CA with SHA-1 thumbprint $thumb (docs/CONTRATO.md)"
      rc=1
    }
  done
  (($(grep -cE "^  '[0-9A-F]{40} https://" "$deploy") == ${#CONTRACT_PG_CA_THUMBPRINTS[@]})) || {
    echo "$deploy: the azure-pg-ca bundle must hold exactly the ${#CONTRACT_PG_CA_THUMBPRINTS[@]} contract roots"
    rc=1
  }
  grep -qF 'kubelogin convert-kubeconfig -l azurecli' "$deploy" || {
    echo "$deploy must convert the AKS kubeconfig with kubelogin (local accounts are disabled)"
    rc=1
  }
  if grep -nE 'get-credentials.*--admin|--overwrite-existing-tags|docker push .*:latest' "$deploy"; then
    echo "$deploy: no admin credentials, no tag overwrites"
    rc=1
  fi
  example=deploy/k8s/components/azure/params.example.env
  mkdir -p "$dir/gitops-patches"
  for overlay in azure azure-waf; do
    if node scripts/render-gitops-application.mjs azure "$overlay" "$example" "$example" \
      >"$dir/gitops-patches/$overlay.json"; then
      node scripts/check-gitops-renderer.mjs "$dir/gitops-patches/$overlay.json" "$dir/$overlay.yaml" || rc=1
    else
      rc=1
    fi
  done
  expected_mode="DEPLOY_MODE=\"\${DEPLOY_MODE:-gitops}\""
  if ! grep -qF 'DEPLOY_MODE: gitops' .github/workflows/deploy-azure.yml ||
    ! grep -qF 'contents: write' .github/workflows/deploy-azure.yml ||
    grep -qE '^    inputs:' .github/workflows/deploy-azure.yml ||
    ! grep -qF "$expected_mode" scripts/deploy-azure.sh; then
    echo "deploy-azure must default to the GitOps branch publishing mode"
    rc=1
  fi
  expected_push="git -C \"\$tmp/repo\" push --quiet origin \"HEAD:refs/heads/\$branch\""
  if ! grep -qF "$expected_push" scripts/publish-gitops.sh ||
    grep -q -- '--force' scripts/publish-gitops.sh; then
    echo "publish-gitops.sh must push the cloud branch without force"
    rc=1
  fi
  summary "contract: ${#CONTRACT_APPCONFIG_KEYS[@]} App Configuration keys, ${#CONTRACT_PG_CA_THUMBPRINTS[@]} root CA thumbprints, manifests of ${K8S_OVERLAYS[*]}"
  return "$rc"
}

# The JSON schemas in deploy/k8s/schemas are exactly what scripts/update-crd-schemas.sh generates
# from the pinned ALB Controller CRDs image (digest-verified download, no Docker needed).
check_crd_schemas() {
  need curl node tar
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  bash scripts/update-crd-schemas.sh --check
}

check_trivy_config() {
  local dir="$HARNESS_WORK_DIR/trivy-config"
  need trivy kubectl
  rm -rf "$dir"
  render_overlays "$dir/k8s"
  mkdir -p "$dir/docker/api" "$dir/docker/web"
  cp api/Dockerfile "$dir/docker/api/Dockerfile"
  cp web/Dockerfile "$dir/docker/web/Dockerfile"
  trivy config --quiet --skip-check-update --exit-code 1 --severity HIGH,CRITICAL \
    --cache-dir "$HARNESS_WORK_DIR/trivy-cache" --ignorefile .trivyignore.yaml "$dir"
}

check_gitleaks() {
  local dir="$HARNESS_WORK_DIR/gitleaks-tree"
  need gitleaks git
  if git rev-parse --verify -q HEAD >/dev/null; then
    echo "repository has commits: scanning the full history (gitleaks git)"
    gitleaks git --no-banner --redact --verbose --log-level warn .
  fi
  # The files that would be committed (tracked + untracked, minus .gitignore): never node_modules,
  # .env or other ignored local files.
  echo "scanning the working tree files visible to git (gitleaks dir)"
  rm -rf "$dir"
  mkdir -p "$dir"
  visible_files | while IFS= read -r f; do
    [[ -f "$f" ]] && printf '%s\0' "$f"
  done | tar --null -T - -cf - | tar -xf - -C "$dir"
  gitleaks dir --no-banner --redact --verbose --log-level warn "$dir"
}

# ---------------------------------------------------------------------------------------------
# Test checks
# ---------------------------------------------------------------------------------------------

coverage_summary() { # SUMMARY_JSON WORKSPACE
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  node -e '
    const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).total;
    console.log(`SUMMARY: ${process.argv[2]} coverage: lines ${t.lines.pct}%, branches ${t.branches.pct}%, statements ${t.statements.pct}%`);
  ' "$1" "$2"
}

test_counts() { # LOG WORKSPACE
  local line
  line="$(sed -E 's/\x1b\[[0-9;]*m//g' "$1" | grep -E '^[[:space:]]+Tests[[:space:]]+[0-9]+' | tail -n 1 | tr -s ' ')"
  summary "$2 tests:${line#*Tests}"
}

# The coverage reports go to HARNESS_WORK_DIR, like every other harness output: nothing generated
# lands in the repository (a synced folder such as OneDrive suffers from the churn).
run_vitest() { # WORKSPACE
  local out="$HARNESS_WORK_DIR/vitest-$1.log" reports status=0
  reports="$(cd "$HARNESS_WORK_DIR" && pwd)/coverage-$1"
  (cd "$1" && npx --no-install vitest run --coverage --coverage.reportsDirectory="$reports") 2>&1 | tee "$out" || status=$?
  test_counts "$out" "$1"
  [[ -f "$reports/coverage-summary.json" ]] && coverage_summary "$reports/coverage-summary.json" "$1"
  return "$status"
}

check_test_api() {
  local name port password ready=0 i
  need node npx
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  if [[ -n "${DB_HOST:-}" ]]; then
    # The integration tests drop and recreate tables: never against DB_* exported for other work.
    [[ "${DB_NAME:-}" =~ ^[A-Za-z0-9_]+_test$ ]] || {
      echo "DB_HOST is set, but DB_NAME '${DB_NAME:-}' does not end in _test: the integration tests drop and recreate tables, so they run only against a test database (unset DB_HOST and the harness starts a throwaway PostgreSQL)"
      return 1
    }
    echo "integration tests use the database from DB_* (DB_HOST=$DB_HOST, DB_NAME=$DB_NAME)"
    run_vitest api
    return
  fi
  need_docker
  name="dx02v2-test-pg-$$-$RANDOM"
  password="$(rand_hex 16)"
  trap 'docker rm -f "$name" >/dev/null 2>&1 || :' EXIT
  echo "DB_HOST is not set: starting a throwaway $TEST_POSTGRES_IMAGE ($name)"
  docker run -d --rm --name "$name" -p 127.0.0.1::5432 \
    -e POSTGRES_DB=dx02v2_test -e POSTGRES_USER=dx02v2 -e POSTGRES_PASSWORD="$password" \
    "$TEST_POSTGRES_IMAGE" >/dev/null
  for i in $(seq 1 60); do
    if docker exec "$name" pg_isready -h 127.0.0.1 -U dx02v2 -d dx02v2_test >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  ((ready)) || {
    docker logs "$name" | tail -n 40
    echo "the throwaway PostgreSQL did not become ready in ${i}s"
    return 1
  }
  port="$(docker port "$name" 5432/tcp | head -n 1 | awk -F: '{ print $NF }')"
  DB_HOST=127.0.0.1 DB_PORT="$port" DB_NAME=dx02v2_test DB_USER=dx02v2 DB_PASSWORD="$password" run_vitest api
}

check_test_web() {
  need node npx
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  run_vitest web
}

# ---------------------------------------------------------------------------------------------
# Build checks
# ---------------------------------------------------------------------------------------------

check_npm_build() {
  need npm
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  npm run --silent build --workspaces
}

check_image() { # api|web
  local ref
  ref="$(image_ref "$1")"
  need_docker
  if [[ "$IMAGES_PREBUILT" == 1 ]]; then
    docker image inspect "$ref" >/dev/null || {
      echo "IMAGES_PREBUILT=1 but $ref does not exist"
      return 1
    }
    echo "using the prebuilt image $ref"
  else
    docker build -f "$1/Dockerfile" --build-arg GIT_SHA="$(git_sha)" -t "$ref" .
  fi
  summary "$ref: $(docker image inspect "$ref" --format '{{.Size}}' | awk '{ printf "%.0f MB", $1 / 1000000 }')"
}

# Runtime properties the Dockerfiles promise: numeric non-root user, OCI labels, and for the API
# no npm/npx/corepack and no shell in the final filesystem.
check_image_policy() { # api|web
  local ref user listing rc=0 container
  ref="$(image_ref "$1")"
  need_docker
  docker image inspect "$ref" >/dev/null 2>&1 || skip "$ref does not exist (check image:$1)"
  user="$(docker image inspect "$ref" --format '{{.Config.User}}')"
  [[ "$user" =~ ^[1-9][0-9]*(:[1-9][0-9]*)?$ ]] || {
    echo "$ref runs as '$user' (numeric non-root uid expected)"
    rc=1
  }
  for label in org.opencontainers.image.source org.opencontainers.image.revision; do
    [[ -n "$(docker image inspect "$ref" --format "{{ index .Config.Labels \"$label\" }}")" ]] || {
      echo "$ref: missing label $label"
      rc=1
    }
  done
  if [[ "$1" == api ]]; then
    container="$(docker create "$ref")"
    listing="$(docker export "$container" | tar -t)"
    docker rm "$container" >/dev/null
    if grep -E '(^|/)(npm|npx|corepack)(/|$)' <<<"$listing" | grep -v '^app/node_modules/' | head -n 5 | grep .; then
      echo "$ref: npm/npx/corepack found in the runtime image"
      rc=1
    fi
    if grep -E '^(bin|usr/bin)/(sh|bash|ash|busybox)$' <<<"$listing"; then
      echo "$ref: the API runtime image must not contain a shell"
      rc=1
    fi
  else
    # v1 published a 970 KB sourcemap: the page ships without any.
    container="$(docker create "$ref")"
    listing="$(docker export "$container" | tar -t)"
    docker rm "$container" >/dev/null
    if grep -E '^usr/share/nginx/html/.*\.map$' <<<"$listing"; then
      echo "$ref: sourcemaps must not be served (web/vite.config.ts sourcemap: false)"
      rc=1
    fi
    grep -qE '^usr/share/nginx/html/index\.html$' <<<"$listing" || {
      echo "$ref: /usr/share/nginx/html/index.html is missing"
      rc=1
    }
  fi
  return "$rc"
}

check_trivy_image() { # api|web
  local ref counts
  ref="$(image_ref "$1")"
  need trivy
  need_docker
  docker image inspect "$ref" >/dev/null 2>&1 || skip "$ref does not exist (check image:$1)"
  trivy image --quiet --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    --cache-dir "$HARNESS_WORK_DIR/trivy-cache" --ignorefile .trivyignore.yaml \
    --format table "$ref" | tee "$HARNESS_WORK_DIR/trivy-$1.txt"
  # Informational: every finding, including unfixed ones and LOW/MEDIUM (the gate is the scan above).
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  counts="$(trivy image --quiet --cache-dir "$HARNESS_WORK_DIR/trivy-cache" --skip-db-update --format json "$ref" | node -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const c = {}; for (const r of JSON.parse(s).Results ?? []) for (const v of r.Vulnerabilities ?? []) c[v.Severity] = (c[v.Severity] ?? 0) + 1;
      console.log(Object.entries(c).map(([k, v]) => `${k} ${v}`).join(", ") || "none");
    });')"
  summary "trivy $ref: 0 fixable HIGH/CRITICAL (gate); all findings incl. unfixed: $counts"
}

# ---------------------------------------------------------------------------------------------
# End-to-end
# ---------------------------------------------------------------------------------------------

check_kind_e2e() {
  need kind kubectl node
  need_docker
  bash scripts/e2e-kind.sh
}

check_platform_e2e() {
  need kubectl node git ssh
  need_docker
  bash scripts/e2e-platform.sh
}

# Heavy (Docker-in-Docker with 7 GB): meant for the CI runner, never part of `all`.
check_platform_small_e2e() {
  need tar
  need_docker
  bash scripts/e2e-platform-small.sh
}

# The alert rules of the local-platform component, tested with promtool (series the API exports and
# kube-state-metrics; docs/HARNESS.md).
check_promtool_rules() {
  local dir="$HARNESS_WORK_DIR/promtool"
  need promtool node
  [[ -d node_modules ]] || skip "node_modules is missing (check npm-ci)"
  mkdir -p "$dir"
  node -e '
    const { parse } = require("yaml");
    const fs = require("fs");
    const docs = fs.readFileSync(process.argv[1], "utf8").split(/^---$/m).map((d) => parse(d));
    const rule = docs.find((d) => d && d.kind === "PrometheusRule");
    fs.writeFileSync(process.argv[2], JSON.stringify({ groups: rule.spec.groups }, null, 2));
  ' deploy/k8s/components/local-platform/monitoring.yaml "$dir/dx02v2.rules.json"
  cp deploy/k8s/components/local-platform/alerts-test.yaml "$dir/alerts-test.yaml"
  promtool check rules "$dir/dx02v2.rules.json"
  (cd "$dir" && promtool test rules alerts-test.yaml)
}

register_checks() {
  register static tool-versions check_tool_versions
  register static repo-structure check_repo_structure
  register static version-consistency check_version_consistency
  register static policy-identifiers check_policy_identifiers
  register static policy-workflows check_policy_workflows
  register static policy-images check_policy_images
  register static policy-app check_policy_app
  register static policy-cloud check_policy_cloud
  register static trivyignore-policy check_trivyignore_policy
  register static npm-ci check_npm_ci
  register static eslint check_eslint
  register static prettier check_prettier
  register static typecheck:api "check_typecheck api"
  register static typecheck:web "check_typecheck web"
  register static hadolint check_hadolint
  register static actionlint check_actionlint
  register static shellcheck check_shellcheck
  register static crd-schemas check_crd_schemas
  register static kubeconform check_kubeconform
  register static contract-app check_contract_app
  register static promtool-rules check_promtool_rules
  register static trivy-config check_trivy_config
  register static gitleaks check_gitleaks
  register test npm-ci check_npm_ci
  register test test:api check_test_api
  register test test:web check_test_web
  register build npm-ci check_npm_ci
  register build npm-build check_npm_build
  register build image:api "check_image api"
  register build image:web "check_image web"
  register build image-policy:api "check_image_policy api"
  register build image-policy:web "check_image_policy web"
  register build trivy-image:api "check_trivy_image api"
  register build trivy-image:web "check_trivy_image web"
  register e2e kind-e2e check_kind_e2e
  register platform platform-e2e check_platform_e2e
  register platform-small platform-small-e2e check_platform_small_e2e
}

# ---------------------------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a FAILED=()

run_check() {
  local name=$1 cmd=$2 log rc start secs status reason="" lines
  local -a parts=()
  read -ra parts <<<"$cmd"
  log="$HARNESS_WORK_DIR/logs/${name//[^A-Za-z0-9._-]/_}.log"
  start=$SECONDS
  set +e
  (
    set -euo pipefail
    cd "$REPO_ROOT"
    "${parts[@]}"
  ) >"$log" 2>&1
  rc=$?
  set -e
  secs=$((SECONDS - start))
  case "$rc" in
    0) status=PASS ;;
    "$SKIP_CODE")
      reason="$(sed -n 's/^SKIP_REASON: //p' "$log" | tail -n 1)"
      if strict; then
        status=FAIL
        reason="$reason (SKIP is not allowed with HARNESS_STRICT=1)"
      else
        status=SKIP
      fi
      ;;
    *) status=FAIL ;;
  esac
  printf '%s %s (%ss)%s\n' "$status" "$name" "$secs" "${reason:+ - $reason}"
  sed -n 's/^SUMMARY: /    /p' "$log"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED+=("$name")
      ;;
  esac
  if [[ "$status" == FAIL || "$HARNESS_VERBOSE" == 1 ]]; then
    lines="$(wc -l <"$log")"
    if ((lines > 400)); then
      echo "    ... last 400 of $lines lines (full log: $log)"
    fi
    tail -n 400 "$log" | sed 's/^/    /'
  fi
}

list_checks() {
  local i
  echo "stages:"
  echo "  static  policies, npm ci, eslint, prettier, tsc, hadolint, actionlint, shellcheck, CRD schemas, kubeconform, contract, promtool rules, trivy config, gitleaks"
  echo "  test    API unit + integration tests (real PostgreSQL 17) and web tests, with coverage gates"
  echo "  build   npm build, docker images, image policy, trivy image gate (HIGH/CRITICAL, fixable)"
  echo "  e2e     kind cluster: manifests, PSA restricted, smoke test, NetworkPolicy enforcement"
  echo "  platform the app on the full tx02v2 local platform (GitOps, mesh, observability, policies, backup, chaos)"
  echo "  platform-small the same e2e on the small platform size, inside Docker limited to 7 GB (heavy: CI only)"
  echo "  all     static + test + build + e2e"
  echo "checks:"
  for i in "${!CHECK_NAME[@]}"; do
    printf '  %-7s %s\n' "${CHECK_STAGE[$i]}" "${CHECK_NAME[$i]}"
  done
}

usage() {
  echo "usage: $0 <stage>...   (stages: static, test, build, e2e, platform, platform-small, all, list)" >&2
  exit 2
}

main() {
  local arg stage i start_all=$SECONDS
  local -a stages=()
  declare -A seen=()
  (($# > 0)) || usage
  register_checks
  for arg in "$@"; do
    case "$arg" in
      static | test | build | e2e | platform | platform-small) stages+=("$arg") ;;
      all) stages+=(static test build e2e) ;;
      list)
        list_checks
        return 0
        ;;
      *) usage ;;
    esac
  done
  mkdir -p "$HARNESS_WORK_DIR/logs"
  echo "harness: stages=${stages[*]} strict=$HARNESS_STRICT work_dir=$HARNESS_WORK_DIR${HARNESS_ONLY:+ only=$HARNESS_ONLY}"
  for stage in "${stages[@]}"; do
    for i in "${!CHECK_NAME[@]}"; do
      [[ "${CHECK_STAGE[$i]}" == "$stage" && -z "${seen[${CHECK_NAME[$i]}]:-}" ]] || continue
      [[ -z "$HARNESS_ONLY" || "${CHECK_NAME[$i]}" =~ $HARNESS_ONLY ]] || continue
      seen[${CHECK_NAME[$i]}]=1
      run_check "${CHECK_NAME[$i]}" "${CHECK_CMD[$i]}"
    done
  done
  echo "summary: $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks, $PASS_COUNT PASS, $FAIL_COUNT FAIL, $SKIP_COUNT SKIP ($((SECONDS - start_all))s, strict=$HARNESS_STRICT)"
  if ((PASS_COUNT + FAIL_COUNT + SKIP_COUNT == 0)); then
    echo "no check matched HARNESS_ONLY='$HARNESS_ONLY'"
    return 1
  fi
  if ((FAIL_COUNT > 0)); then
    echo "failed: ${FAILED[*]}"
    return 1
  fi
}

main "$@"
