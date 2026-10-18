# dx02v2 harness

The harness checks this repository's claims without a cloud account. Checks live in
`scripts/harness.sh`; Makefile and CI call it. CI uses the same checks with `HARNESS_STRICT=1`.

For the full profile and `local-platform` overlay, `kubeconform` validates HTTPRoutes against
the experimental Gateway API v1.6.3 bundle, SHA256-verified through
`deploy/k8s/schemas/source.env`. Ingress overlays `azure`/`azure-waf` retain schemas generated
from ALB Controller CRDs. Waypoint `retry` exists only in the experimental channel.

## Layers

| Layer | Command | What it proves | What it does not prove | Runs |
|---|---|---|---|---|
| Tools | `make tools` | `tools/versions.env` versions of trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl, kubelogin, promtool; verified SHA256 | — | local, CI |
| Versions | `tool-versions`, `version-consistency` | pinned PATH in strict mode; consistent Node.js/PostgreSQL/Kubernetes across files; exact npm versions | — | local, CI |
| Structure and evidence | `repo-structure` | required files, status labels, LF, UTF-8 without BOM or UTF-16, README <= 250 lines, executable Git-index bits | documentation accuracy | local, CI |
| Policies | `policy-identifiers`, `policy-workflows`, `policy-images`, `policy-app`, `policy-cloud`, `trivyignore-policy` | no real GUIDs/name suffixes/IPs/emails; pinned actions/images; manual deploy, secretless OIDC, pinned azure/login; v1 regressions for trust proxy, CORS, inline styles, HSTS, console; no unrelated cloud path; expiring ignores | author intent | local, CI |
| Dependencies | `npm-ci` | lockfile matches all three package.json files; strict mode always executes npm ci | dependency safety; see trivy | local, CI |
| Lint, format and types | `eslint`, `prettier`, `typecheck:api`, `typecheck:web` | type-aware typescript-eslint, React hooks, formatting, strict TypeScript | behavior | local, CI |
| Dockerfiles, workflows, scripts | `hadolint`, `actionlint` with shellcheck, `shellcheck` | Dockerfile practices, valid YAML/bash, style-level checks | cloud behavior | local, CI |
| CRD schemas | `crd-schemas` | generated schemas exactly match digest-pinned ALB Controller CRD image; every download verified | tx02v2 installs that same version | local, CI; network |
| Manifests | `kubeconform`, `contract-app`, `promtool-rules`, `trivy-config` | strict valid local, Azure core/full, WAF core/full and local-platform renders; Kubernetes 1.36, Gateway API v1.5.1 standard for ALB, alb.networking.azure.io/v1, ExternalSecret; experimental waypoint channel; contract/hardening assertions, deploy contract keys/fixed values/CA roots; no HIGH/CRITICAL configuration findings | admission/runtime, actual ALB Controller | local, CI; network |
| Secrets | `gitleaks` | no recognized secrets; full history when commits exist, plus visible worktree | secrets outside detector patterns | local, CI |
| API tests | `test:api` | unit/integration supertest against real app/PostgreSQL 17: idempotent migrations, create/list/delete, 400/401/404/413/415/429/503, forged nginx/AGC XFF cannot bypass rate limit, readyz 200/503, DB recovery, graceful shutdown; >=80% lines and >=70% branches | Azure PostgreSQL TLS, multiple replicas | local/CI; Docker or DB_* |
| Page tests | `test:web` | list, successful/failed submission, validation, admin mode with mocked fetch; >=70% lines | real browser and browser-enforced CSP | local, CI |
| Build | `npm-build`, `image:*`, `image-policy:*` | tsc/vite builds, both images, numeric non-root user, OCI labels, no npm/npx/corepack or shell in API runtime, no web sourcemaps | runtime; see e2e | local/CI; Docker |
| Image vulnerabilities | `trivy-image:*` | no fixable HIGH/CRITICAL findings | unfixed CVEs, zero-days | local/CI; Docker/network |
| DevSecOps | CodeQL, SonarQube, trivy fs, Gitleaks, OWASP ZAP | CodeQL SARIF gate, Sonar Quality Gate and negative fixture, filesystem/image scans, historic-secret detection, DAST baseline against disposable Compose | weaknesses outside scanner rules, cloud behavior | CI static/test/images; make dast |
| Release/attestations | `publish-images`, `verify-release-bundle.sh` | publishes tested image IDs; validates SPDX SBOM/provenance/signer; Azure deploy pins promoted digests | actual deploy and AKS runtime | manual workflows; release not yet published |
| End to end | `kind-e2e` (`scripts/e2e-kind.sh`) | kind 1.36 rollout/migration initContainer, restricted Pod Security enforcement, nginx smoke (headers, API, 201/400/401/204/404/413/429, forged XFF, request ID), permitted/blocked NetworkPolicy probes | AKS, AGC, WAF, ESO, Key Vault, Flexible Server, Cilium | local/CI; Docker |
| Cloud | deploy-azure workflow and contract-app | locally validated overlays and Application patches; real sync remains unexecuted | Azure and cloud smoke | not run in the cloud (v2) |

Compose smoke (`scripts/compose-smoke.sh`) uses the same `e2e/smoke.mjs` but runs manually outside
CI; see `docs/RUNBOOK.md`. Before the first push, `scripts/deploy-azure.sh` was exercised end to
end using stubbed az/kubectl/kubelogin/docker, real CA-root downloads/thumbprint checks, and
`SMOKE_EDGE=agc` smoke against Compose behind an AGC-like proxy. This is a local verification,
not a harness check or cloud execution.

## CI jobs

| Job (ci.yml) | Target | Harness stage |
|---|---|---|
| `static` | make tools && make static | static |
| `test` | CodeQL security-extended, make test against disposable PostgreSQL 17, real disposable SonarQube Quality Gate/negative fixture; SARIF artifact | test |
| `images` | buildx/GitHub cache, make tools && make build, ZAP baseline against disposable Compose; artifact contains both images | build + dast |
| `e2e` | load artifact, install kind/kubectl, make e2e with E2E_SKIP_BUILD=1; diagnostics artifact on failure | e2e |
| `continuity` | load the scanned images; independent A/B recovery, fencing and failback | continuity |
| `e2e-platform` | load artifact; make e2e-platform with E2E_SKIP_BUILD=1; clone deploy/local/tx02v2.ref, start full platform, GitOps deploy and probes (LOCAL_LAB.md); diagnostics | platform |
| `e2e-platform-small` | same artifact/probes with LOCAL_SIZE=small in 7-GB Docker-in-Docker, no swap; memory peaks/OOM summary and diagnostics; not a required ruleset check | platform-small |

`static`, `test`, `images`, `e2e` and `e2e-platform` are stable required ruleset IDs
(`.github/rulesets/main.json`; platform added 2026-10-13). `policy-workflows` prevents accidental
changes. Release verification additionally requires the source CI continuity result.
`promtool-rules` runs `promtool check rules`/`promtool test rules` for local-platform alerts.
`platform-small-e2e` never belongs to `all`: it is heavy and intended for CI runners.

## Strict mode

`HARNESS_STRICT=1`, set in CI/devcontainer, turns every SKIP into FAIL, requires pinned PATH
versions and always executes npm ci. Without strict mode, only a missing local prerequisite
(tool, stopped Docker) can skip a check; the reason is always printed.

| Variable | Effect |
|---|---|
| `HARNESS_VERBOSE=1` | print passing-check output |
| `HARNESS_ONLY=<regex>` | local debugging filter, never used in CI; e.g. HARNESS_ONLY='^eslint$' scripts/harness.sh static |
| `HARNESS_WORK_DIR` | logs, rendered manifests, caches; default $TMPDIR/dx02v2-harness |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | integration DB; without DB_HOST, create/remove disposable postgres:17-alpine on a random localhost port; with DB_HOST, DB_NAME must end _test because tests recreate tables |
| `IMAGE_TAG` | built/scanned image tag; default e2e, used by local overlay |
| `IMAGES_PREBUILT=1` | build stage checks prebuilt CI images instead of rebuilding |
| `E2E_SKIP_BUILD=1`, `KEEP_CLUSTER=1`, `E2E_DIAGNOSTICS_DIR`, `E2E_KIND_INTERNAL=1` | see scripts/e2e-kind.sh header |

## Adding a check

1. Write `check_<name>` in `scripts/harness.sh`, returning 0/PASS or nonzero/FAIL.
   Use `need <tool>`, `need_docker` or `skip "<reason>"` only for missing prerequisites.
   `summary "<text>"` prints a result even on success.
2. Register in the correct stage (static/test/build/e2e or the relevant platform/continuity stage).
3. Run `scripts/harness.sh list`, `HARNESS_STRICT=1 make verify` and the check's stage.
4. Update this table, `docs/GUARDRAILS.md` if applicable, and CHANGELOG.

For a new tool, add official URLs to `scripts/lib/tools.sh`, pin `tools/versions.env` and run
`scripts/update-tool-checksums.sh <tool> <version>`.

## Windows and macOS

- Windows: use the digest-pinned Node.js 24/Docker-in-Docker devcontainer, or Ubuntu WSL 2.
  Git Bash is unsupported; installed tools are Linux/macOS binaries.
- Apple Silicon macOS: `brew install bash` (system bash 3.2 is insufficient; >=4.4 required)
  or use the devcontainer. Supported tool platforms: linux_amd64, linux_arm64, darwin_arm64.
- Standalone container using host Docker, as in local verification: use
  `mcr.microsoft.com/devcontainers/javascript-node:24-trixie` pinned by digest, Docker/buildx/compose
  copied from official `docker:29-cli`, repo at /work, host Docker socket and named volumes for
  node_modules/.tools/dist outside OneDrive-like synchronized directories.
  Coverage already uses HARNESS_WORK_DIR:

```bash
docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work \
  -v dx02v2-nm-root:/work/node_modules -v dx02v2-nm-api:/work/api/node_modules \
  -v dx02v2-nm-web:/work/web/node_modules -v dx02v2-tools:/work/.tools \
  -v dx02v2-out-api-dist:/work/api/dist -v dx02v2-out-web-dist:/work/web/dist \
  -v dx02v2-npm-cache:/root/.npm -v /var/run/docker.sock:/var/run/docker.sock \
  --network <postgres-network> -e DB_HOST=<postgres-container> -e DB_NAME=dx02v2_test \
  -e DB_USER=... -e DB_PASSWORD <image-above> bash -c "make tools && make verify build"
```

Inside a container, the disposable DB and kind-published 127.0.0.1 belong to the host.
Point DB_* to PostgreSQL on the same Docker network; e2e needs E2E_KIND_INTERNAL=1
(the script joins network kind and uses the API server's internal address).
For different file ownership add
`-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*`.

## Data outside the repository

HARNESS_WORK_DIR (default $TMPDIR/dx02v2-harness), or temporary directories, contains logs,
coverage-api/coverage-web, rendered manifests, gitleaks' copied tree, downloaded CRDs and
trivy/kubeconform caches. Only ignored .tools/, node_modules/ and */dist/ remain in the repo;
*/coverage/ appears only with manual npm run test:coverage. `make clean` removes these.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| SKIP tool-versions - missing tools | tools not installed | make tools |
| FAIL npm-ci | lock/package.json mismatch | npm install and commit both; never hand-edit lock |
| FAIL test:api: integration tests need DB_HOST | no Docker or DB_* | start Docker or provide PostgreSQL 17 DB_* |
| FAIL test:api: DB_NAME does not end in _test | DB_* targets another database | env -u DB_HOST make test, or choose *_test |
| FAIL test:api: coverage below threshold | untested new code | add tests; never lower threshold |
| FAIL trivy-image:* | newly fixable HIGH/CRITICAL CVE | MAINTENANCE.md section 5.6 |
| FAIL trivyignore-policy: expired | exception expired | fix or renew with a fresh justification |
| FAIL crd-schemas | hand-edited schemas or generator changed | regenerate from source.env version; commit results |
| FAIL crd-schemas: download/digest mismatch | network or unexpected Microsoft registry content | investigate; never accept changed digest |
| FAIL kubeconform: missing schema | network or incompatible pinned catalog schema | inspect network and pinned catalog commits in harness |
| FAIL contract-app | manifest/deploy script violates contract/hardening | fix; coordinate contract changes with tx02v2 |
| FAIL policy-cloud | unrelated-cloud path outside README/ARCHITECTURE/CHANGELOG | remove or describe in Azure terms |
| FAIL kind-e2e | rollout/smoke/probe failure | inspect summary/E2E_DIAGNOSTICS_DIR and CI e2e-diagnostics; KEEP_CLUSTER=1 make e2e for investigation |
| FAIL gitleaks | secret or false positive | remove/rotate credentials; use obvious placeholder SHA/GUID; pre-first-commit scan covers Git-visible files |
| FAIL policy-identifiers | real GUID/suffix/account/email/IP | use 00000000-0000-0000-0000-000000000000, tx02v2lab00000000, you@example.com, 203.0.113.10/32 |

## R10: capacity and FinOps

See [Capacity and SLO](FINOPS.md) for bounded load, HPA up/down, PDB/drain, rightsizing,
PostgreSQL pool saturation and showback. Docker evidence runs in Actions; not run in the cloud (v2).
