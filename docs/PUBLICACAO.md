# Publicação do dx02v2

Checklist para tornar o repositório público com as proteções do padrão v2. Siga na ordem; cada item
tem o comando ou o lugar onde é verificado.

## Antes de publicar

- [ ] `HARNESS_STRICT=1 make verify build` e `make e2e` verdes no devcontainer ou em Linux.
- [ ] Bit executável nos scripts de entrada antes do primeiro commit (o Windows não o grava):
      `git add --chmod=+x scripts/compose-smoke.sh scripts/deploy-azure.sh scripts/dev-env.sh scripts/e2e-kind.sh scripts/harness.sh scripts/install-tools.sh scripts/render-k8s.sh scripts/repo-guardrails.sh scripts/update-crd-schemas.sh scripts/update-tool-checksums.sh`
      (o check `repo-structure` confere o índice do git).
- [ ] Primeiro commit feito e enviado para `main` (privado) e CI verde (`static`, `test`, `images`, `e2e`).
- [ ] `gitleaks git` limpo no histórico completo (o check `gitleaks` faz isso quando há commits).
- [ ] Nenhum identificador real: `policy-identifiers` verde (GUIDs, sufixos, IPs, e-mails) e uma
      leitura humana de `docs/`.
- [ ] Matriz de status do README conferida: `verificado localmente` só vira `verificado no CI` depois
      do primeiro CI verde (a linha do compose continua local); o deploy na Azure continua
      `não executado em nuvem (v2)` até um `cloud_run_report`.
- [ ] Descrição e tópicos do repositório (`gh repo edit maringelix/dx02v2 --description ... --add-topic kubernetes`).

## Publicar

- [ ] `gh repo edit maringelix/dx02v2 --visibility public --accept-visibility-change-consequences`
- [ ] `scripts/repo-guardrails.sh maringelix/dx02v2`: alertas de vulnerabilidade, security updates do
      Dependabot, squash-only, `delete_branch_on_merge`, `GITHUB_TOKEN` só leitura por padrão (sem
      aprovar PRs), ruleset `main`, secret scanning + push protection, private vulnerability
      reporting e environment `lab` (revisor: o dono; só `main`). O script imprime o que foi
      aplicado, pulado e o que falhou.
- [ ] Settings > Actions > General: aprovação obrigatória para workflows de PRs de forks de
      colaboradores externos (manual).

## Ruleset `main` (`.github/rulesets/main.json`)

- Bloqueia deleção e force-push; exige PR (0 aprovações para mantenedor solo,
  `dismiss_stale_reviews_on_push`, `required_review_thread_resolution`), merge só squash.
- Checks obrigatórios (modo estrito, app GitHub Actions): `static`, `test`, `images` e `e2e`.
- Bypass: papel de admin do repositório, modo `pull_request` — **só para emergência** (por exemplo,
  um check quebrado por fator externo bloqueando uma correção de segurança). Registre o motivo no PR.

## Ids de jobs estáveis

Mudar um id quebra a proteção. Ids atuais:

| Workflow | Job | Exigido pelo ruleset |
|---|---|---|
| `ci.yml` | `static` | sim |
| `ci.yml` | `test` | sim |
| `ci.yml` | `images` | sim |
| `ci.yml` | `e2e` | sim |
| `deploy-azure.yml` | `deploy` | não (só `workflow_dispatch`, environment `lab`; o check `policy-workflows` exige o id) |

## Depois de publicar

- [ ] CI verde em `main` público e badge funcionando; atualize a matriz (`verificado no CI`).
- [ ] Variáveis do GitHub (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
      `AZURE_APPCONFIG_ENDPOINT`) só depois do bootstrap e do apply do tx02v2 (`docs/RUNBOOK.md`,
      seção 6).
- [ ] Primeira rodada em nuvem registrada com `cloud_run_report`.
