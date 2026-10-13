# dx02v2

Metade de aplicação do lab de DevOps na Azure: um mural de mensagens pequeno (API Express 5, página React 19, PostgreSQL 17) com containers, manifests Kubernetes e um teste ponta a ponta em kind.

[![ci](https://github.com/maringelix/dx02v2/actions/workflows/ci.yml/badge.svg)](https://github.com/maringelix/dx02v2/actions/workflows/ci.yml)

[English](README.md)

## O que é

Um lab público e educacional para clonar ou fazer fork e aprender como um app web pequeno é
construído, testado, empacotado e publicado em Kubernetes com segurança. Tudo é provado por um
harness local que não precisa de conta na nuvem: lint, checagem de tipos, testes unitários e de
integração contra um PostgreSQL de verdade, build das imagens com gate de vulnerabilidades e um teste
ponta a ponta em um cluster kind local. O caminho Azure (AKS construído pelo `tx02v2`, tráfego pelo
Application Gateway for Containers) está pronto, mas **nunca rodou na nuvem** — a matriz de status
diz exatamente o que está provado e como.

Este repositório roda o mesmo aplicativo do `dx01v2` (o par da AWS), para a comparação entre nuvens
ser justa: só o destino do deploy muda. Como os dois ficam em sincronia está no
[docs/ARQUITETURA.md](docs/ARQUITETURA.md).

A família do lab (v2):

| Repositório | Nuvem | Papel | Status |
|---|---|---|---|
| [`tx01v2`](https://github.com/maringelix/tx01v2) | AWS | infraestrutura (Terraform, EKS, RDS, camada de plataforma) | veja a matriz de status dele |
| [`dx01v2`](https://github.com/maringelix/dx01v2) | AWS | aplicação (o mesmo app deste repositório) | veja a matriz de status dele |
| [`tx02v2`](https://github.com/maringelix/tx02v2) | Azure | infraestrutura (Terraform, AKS, PostgreSQL Flexible Server, Application Gateway for Containers, camada de plataforma) | irmão deste repositório, veja a matriz de status dele |
| `dx02v2` (este repositório) | Azure | aplicação (construída sobre o `docs/CONTRATO.md`) | ver matriz de status |
| [`tx03v2`](https://github.com/maringelix/tx03v2) | GCP | infraestrutura (Terraform, GKE Autopilot, Cloud SQL, Cloud Armor) | veja a matriz de status dele |
| [`dx03v2`](https://github.com/maringelix/dx03v2) | GCP | aplicação (o mesmo app deste repositório) | veja a matriz de status dele |

## Matriz de status

| Capacidade | Status | Evidência |
|---|---|---|
| Lint, formatação e checagem de tipos (eslint, prettier, tsc para `api` e `web`) | `verificado no CI` | `make static` (`eslint`, `prettier`, `typecheck:*`); job `static` do CI |
| Dockerfiles, workflows e scripts (hadolint, actionlint, shellcheck) | `verificado no CI` | `make static` (`hadolint`, `actionlint`, `shellcheck`) |
| Manifests Kubernetes: render do kustomize + kubeconform estrito (local, azure, azure-waf) com schemas de Gateway API e Application Gateway for Containers gerados dos CRDs do ALB Controller fixado, asserções de contrato e de hardening, trivy config | `verificado no CI` | `make static` (`crd-schemas`, `kubeconform`, `contract-app`, `trivy-config`) |
| Scan de segredos e políticas do repositório (sem identificadores reais nem GUIDs, actions e imagens fixadas, regressões do v1, sem restos do caminho AWS) | `verificado no CI` | `make static` (`gitleaks`, `policy-*`, `repo-structure`, `version-consistency`) |
| Testes unitários + de integração da API contra um PostgreSQL 17 real (gate de cobertura: linhas >= 80 %, branches >= 70 %) | `verificado no CI` | `make test` (`test:api`); job `test` do CI |
| Testes da página com Testing Library + jsdom (gate de cobertura: linhas >= 70 %) | `verificado no CI` | `make test` (`test:web`); job `test` do CI |
| Imagens: build, usuário numérico não root, sem npm nem shell no runtime da API, gate do trivy HIGH/CRITICAL | `verificado no CI` | `make build`; job `images` do CI |
| Stack do compose (PostgreSQL → migrate → api → web em 127.0.0.1) + smoke test | `verificado localmente` | `scripts/dev-env.sh`, `scripts/compose-smoke.sh` (manual, fora do CI) |
| Ponta a ponta no kind: Pod Security `restricted`, smoke test pelo nginx, enforcement de NetworkPolicy | `verificado no CI` | `make e2e` (`scripts/e2e-kind.sh`); job `e2e` do CI |
| Deploy na Azure (push no ACR, AKS do tx02v2, ExternalSecrets do Key Vault, Application Gateway for Containers + política de WAF, smoke test por ele) | `não executado em nuvem (v2)` | `.github/workflows/deploy-azure.yml`, `scripts/deploy-azure.sh`, `docs/RUNBOOK.md` |
| HTTPS no listener do Application Gateway for Containers | `planejado` | precisa de um Secret TLS; fora do contrato v1 (`docs/CONTRATO.md`) |
| Configurações do repositório como código (ruleset, environment `lab`) | `planejado` | `scripts/repo-guardrails.sh`, `docs/PUBLICACAO.md` |
| Overlay `local-platform` para o lab local do tx02v2: render do kustomize + kubeconform estrito, asserções contra o contrato local e os kinds do AppProject `dx02v2`, cinco regras de alerta testadas com promtool | `verificado localmente` | `make static` (`kubeconform`, `contract-app`, `promtool-rules`) num contêiner Linux; ainda não no CI |
| **O app na plataforma local completa do tx02v2** (kind + ACR, PostgreSQL Flexible Server, armazenamento de objetos, load balancer e servidor git emulados): imagens no registry do lab, GitOps com Argo CD (Synced, Healthy, self-heal) | `verificado localmente` | `make e2e-platform` (`scripts/deploy-local.sh`, `scripts/e2e-platform.sh`, `docs/LAB_LOCAL.md`); job `e2e-platform` do CI |
| HTTPS pelo load balancer emulado e um Gateway do Istio (cert-manager, CA do lab), smoke test de fora do mesh (`SMOKE_EDGE=istio`); TLS `verify-full` no banco | `verificado localmente` | `make e2e-platform` (sonda `smoke`) |
| Istio ambient: mTLS `STRICT`, `AuthorizationPolicy` por identidade, NetworkPolicies com HBONE; Prometheus, dashboard do Grafana, Loki; Gatekeeper, Trivy Operator, HPA 2-4; ensaio de backup + restore do banco; experimento de chaos | `verificado localmente` | `make e2e-platform` (sondas `mesh`, `observability`, `trivy`, `hpa`, `backup`, `chaos`) |

As linhas `verificado no CI` rodam em todo pull request, em todo push para a `main` e toda semana
(jobs do CI na coluna Evidência); a linha do compose é verificada só localmente. A linha da Azure só
muda com uma issue `cloud_run_report` (data, região, commits, custo, saída do smoke test, sobras).

## Arquitetura

```mermaid
flowchart LR
  browser((Navegador)) -->|"/ e /api (mesma origem)"| edge["borda: nginx do web localmente,<br/>Application Gateway for Containers na Azure"]
  edge -->|"/ → web:8080"| web["web: nginx-unprivileged :8080<br/>SPA + cabeçalhos de segurança"]
  edge -->|"/api → api:3000"| api["api: Express 5, Node.js 24<br/>distroless, não root"]
  web -->|"/api/ → api:3000 (local)"| api
  api -->|"Pool pg, TLS verify-full na Azure"| db[("PostgreSQL 17")]
  migrate["migrate (mesma imagem)<br/>advisory lock"] --> db
  prom["Prometheus (namespace monitoring)"] -.->|":9464 /metrics"| api
```

- Local (compose) e kind: um proxy reverso (o nginx do web) na frente da API (`TRUST_PROXY_HOPS=1`).
- Azure: o Application Gateway for Containers (com a política de WAF do tx02v2) manda `/api` para a
  API e `/` para o web pela Gateway API; ele acrescenta o endereço do cliente ao `X-Forwarded-For`,
  então continua havendo exatamente um salto confiável. Os segredos vêm do Key Vault pelo External
  Secrets; namespace, identidades, AGC, PostgreSQL e camada de plataforma são do tx02v2.
- Decisões de design, diagramas por ambiente e as tabelas dx01v2 ↔ dx02v2 e v1 → v2:
  [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Início rápido (grátis, local)

Você precisa de Docker e do devcontainer ou de Linux/WSL 2 com bash >= 4.4, Node.js 24 (`.nvmrc`),
curl, unzip, xz, git e make.

```bash
git clone https://github.com/maringelix/dx02v2.git && cd dx02v2
make tools                     # ferramentas fixadas em .tools/, SHA256 conferido
HARNESS_STRICT=1 make verify   # checks estáticos + testes (sobe um PostgreSQL descartável no Docker)
make build                     # as duas imagens + gate do trivy
make e2e                       # cluster kind dx02v2-e2e: deploy, smoke test, sondas de NetworkPolicy
```

Rodar o app:

```bash
scripts/dev-env.sh                                  # .env com segredos aleatórios (ignorado pelo git)
docker compose -p dx02v2-dev up -d --build --wait   # http://127.0.0.1:8080
scripts/compose-smoke.sh                            # o mesmo smoke test do kind e da Azure
docker compose -p dx02v2-dev down -v
```

No Windows ou macOS, abra a pasta no devcontainer (`.devcontainer/devcontainer.json`, com
Docker-in-Docker); ele roda `make tools` sozinho. Nada aqui toca a Azure. Referência da API com
exemplos em curl: [docs/API.md](docs/API.md).

## Caminho em nuvem (custa dinheiro)

**Custo primeiro:** o app roda no lab do tx02v2, e o maior item dele é o Application Gateway for
Containers com o WAF: cerca de US$0,28 por hora (um frontend, uma associação, cerca de uma unidade de
capacidade; US$0,155 por hora sem o WAF), ou seja, cerca de US$204 por mês se esquecido, além dos
nós do AKS e do PostgreSQL. Preços de referência (Azure Retail Prices API, eastus2, 2026-10-11) —
confira o [documento de custos do tx02v2](https://github.com/maringelix/tx02v2/blob/main/docs/CUSTOS.md)
e a calculadora oficial. Use uma assinatura dedicada com orçamento e destrua no mesmo dia.

Siga o [docs/RUNBOOK.md](docs/RUNBOOK.md): bootstrap/apply/plataforma do tx02v2 → variáveis do
GitHub do dx02v2 → workflow `deploy-azure` (ou `scripts/deploy-azure.sh`) → smoke test pelo
Application Gateway for Containers → destroy do tx02v2 + checagem de sobras → issue
`cloud_run_report`.

## Harness

| Alvo | O que roda | Quando |
|---|---|---|
| `make help` | lista os alvos | a qualquer momento |
| `make tools` | `scripts/install-tools.sh`: trivy 0.75.0, hadolint 2.15.1, actionlint 1.7.12, shellcheck 0.11.0, kubeconform 0.8.0, gitleaks 8.30.1, kind 0.33.0, kubectl 1.36.5, kubelogin 0.2.21, promtool 3.15.0 | uma vez, e depois de atualizar uma ferramenta |
| `make static` | `scripts/harness.sh static` | antes de cada push |
| `make test` | `scripts/harness.sh test` (PostgreSQL 17 real: `DB_*` ou um container descartável) | antes de cada push |
| `make verify` | static + test | antes de cada PR |
| `make build` | `scripts/harness.sh build`: build npm, imagens, política das imagens, gate do trivy | quando código, Dockerfiles ou dependências mudam |
| `make e2e` | `scripts/harness.sh e2e`: cluster kind, smoke test, sondas de NetworkPolicy | quando manifests, imagens ou o app mudam |
| `make e2e-platform` | `scripts/harness.sh platform`: o app na plataforma local completa do tx02v2 (clona o tx02v2 em `deploy/local/tx02v2.ref`), sempre destruída no fim (job `e2e-platform` do CI) | mudanças em manifests, imagens ou no app; precisa de Docker com 8 GB |
| `make all` | todos os estágios | antes de um merge importante |
| `make clean` | remove `.tools/`, saída de build, cobertura, `node_modules` e dados temporários | — |

`scripts/harness.sh list` mostra todos os checks. Detalhes: [docs/HARNESS.md](docs/HARNESS.md).

## Documentação

| Documento | Conteúdo |
|---|---|
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | diagramas (local, kind, Azure), decisões, dx01v2 ↔ dx02v2, v1 → v2 |
| [docs/API.md](docs/API.md) | endpoints, erros, exemplos em curl |
| [docs/CONTRATO.md](docs/CONTRATO.md) | contrato tx02v2 ⇄ dx02v2 v1 (lado do app; fonte da verdade no tx02v2) |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | desenvolvimento local, compose, e2e no kind, deploy na Azure |
| [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md) | o app na plataforma local do tx02v2 (deploy GitOps, sondas, limites) |
| [docs/GUARDRAILS.md](docs/GUARDRAILS.md) | regras, aplicação, exceções, limites |
| [docs/HARNESS.md](docs/HARNESS.md) | checks, modo estrito, problemas comuns |
| [docs/SUSTENTACAO.md](docs/SUSTENTACAO.md) | rotinas, calendário de fim de suporte, procedimentos de atualização, paridade com o dx01v2 |
| [docs/PUBLICACAO.md](docs/PUBLICACAO.md) | checklist para tornar o repositório público |

## Contribuindo

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) e o [AGENTS.md](AGENTS.md) (também para humanos).
Vulnerabilidades: [SECURITY.md](SECURITY.md).

## Licença

[MIT](LICENSE) — Copyright (c) 2025-2026 Bruno Maringeli.
