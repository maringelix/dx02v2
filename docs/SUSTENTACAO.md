# Sustentação do dx02v2

Como manter o repositório saudável sem conta na nuvem: rotinas, calendário de fim de suporte e
procedimentos passo a passo. Datas e versões verificadas em 2026-10-11.

## 1. Objetivo e escopo

Cobre o código do app (API, página, migrações), as dependências npm, as imagens base, os manifests,
os schemas gerados dos CRDs, os scripts e workflows, as ferramentas do harness, a paridade com o
`dx01v2` e as rodadas opcionais em nuvem. A infraestrutura (AKS, Application Gateway for Containers,
WAF, PostgreSQL, Key Vault, App Configuration, camada de plataforma) é do `tx02v2`, com a sustentação
descrita lá.

## 2. Estado atual

- Estágios `static`, `test`, `build` e `e2e` `verificado no CI` (jobs `static`, `test`, `images` e
  `e2e` verdes no GitHub) e também em containers Linux locais.
- Deploy na Azure: `não executado em nuvem (v2)`; `scripts/deploy-azure.sh` foi exercitado só com
  `az`/`kubectl`/`kubelogin`/`docker` simulados.
- Contrato com o tx02v2: versão 1 (`docs/CONTRATO.md`), espelho da parte do app do
  `docs/CONTRATO.md` do tx02v2; as notas de implementação foram incorporadas ao contrato antes da
  primeira publicação do tx02v2.
- App: o do `dx01v2` no commit `22e69c4`, com as diferenças da seção 5.10.
- Exceções de scanner: nenhuma (`.trivyignore.yaml` vazio).

## 3. Rotinas

| Quando | O quê | Como |
|---|---|---|
| Semanal (automático) | CI agendado (segunda 06:00 UTC) roda todos os jobs, inclusive o trivy das imagens e o `crd-schemas` | Falhou? Seção 6. Causas típicas: CVE novo numa imagem base ou dependência, URL que mudou, rede |
| Mensal | PRs do Dependabot (npm, Docker, actions, pre-commit) | Playbook "Dependency updater" do `AGENTS.md`; um PR por grupo, CI verde antes do merge; o mesmo bump no `dx01v2` |
| Trimestral | Ferramentas do harness (inclusive kubelogin), digests das imagens (PostgreSQL, kind, devcontainer), versões de plataforma (Node.js, nginx, Kubernetes/AKS), ALB Controller e Gateway API (mesma versão do tx02v2), schemas do kubeconform, `azure/login`, ignores perto de vencer, **paridade com o dx01v2** | Seções 4 e 5; registre no CHANGELOG |
| Por rodada em nuvem: antes | Ler o custo (README e `docs/CUSTOS.md` do tx02v2), CI verde no commit, tx02v2 aplicado e com a plataforma instalada, variáveis do GitHub | `docs/RUNBOOK.md` |
| Por rodada em nuvem: durante | Anotar horários, saída do smoke test e problemas; não deixar a rodada aberta de um dia para o outro | `docs/RUNBOOK.md` |
| Por rodada em nuvem: depois | destroy do tx02v2, checagem de sobras limpa, issue `cloud_run_report`, matriz de status só com evidência | `docs/RUNBOOK.md`, seção 7 |

## 4. Calendário de fim de suporte

| Componente | Versão | Fim do suporte | Fonte | Ação |
|---|---|---|---|---|
| Node.js | 24 (`.nvmrc`; imagens com 24.21.0) | 2028-04-30 | [calendário do Node.js](https://github.com/nodejs/Release#release-schedule) | Migrar para o 26 (seção 5.3) com folga, depois de ele virar LTS, junto com o dx01v2 |
| Node.js | 26 | LTS a partir de 2026-10-28; fim em 2029-04-30 | idem | Candidato na primeira revisão trimestral depois de 2026-10-28 |
| TypeScript | 6.0.3 | sem data publicada | [typescript-eslint: versões suportadas](https://typescript-eslint.io/users/dependency-versions) | Manter dentro de `>=4.8.4 <6.1.0` (typescript-eslint 8.71); o `dependabot.yml` ignora minors e majors do `typescript` |
| React / Vite / Vitest | 19.3 / 8.3 / 5.0 | sem calendário publicado | react.dev, vite.dev, vitest.dev | Majors chegam como PRs individuais do Dependabot; ler o guia de migração |
| Express | 5.3 | linha 5.x ativa | [política de suporte do Express](https://expressjs.com/en/support/) | Acompanhar pelo Dependabot |
| PostgreSQL | 17 (`postgres:17-alpine`, imagem com 17.11) | 2029-11-08 (comunidade) | [versionamento do PostgreSQL](https://www.postgresql.org/support/versioning/) | A major segue o PostgreSQL Flexible Server do tx02v2 (contrato); trocar compose, CI, kind e harness juntos |
| nginx (web) | 1.30 estável (`nginxinc/nginx-unprivileged:1.30.5-alpine3.24-slim`) | até a próxima estável (1.32, prevista para ~abril de 2027) | [nginx.org](https://nginx.org/en/download.html) | Mudar para a nova linha estável na revisão trimestral seguinte ao lançamento |
| Alpine (build e runtime do web) | 3.24 | ~2028-05 | [releases do Alpine](https://alpinelinux.org/releases/) | Acompanha os digests do node e do nginx-unprivileged |
| Distroless (runtime da API) | `nodejs24-debian13:nonroot` | segue o Debian 13 (segurança até ~2028-08) e o Node.js 24 | [distroless](https://github.com/GoogleContainerTools/distroless) | Não voltar para a variante `debian12` (parou no Node.js 24.14.0) |
| Kubernetes (kind, kubectl, schemas) e AKS | 1.36 (nó `v1.36.4`, kubectl 1.36.5) | AKS 1.36: fim de vida em 2027-06-30 (suporte de 12 meses a partir do GA de junho de 2026; LTS até 2028-06) | [versões do AKS](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions), [releases do Kubernetes](https://kubernetes.io/releases/) | Mudar junto com o tx02v2 (mudança de minor é mudança de contrato), seção 5.5 |
| kind | v0.33.0 (padrão do kind: Kubernetes 1.37.0) | sem política de fim de suporte | [releases do kind](https://github.com/kubernetes-sigs/kind/releases) | Trimestral; a imagem do nó vem das notas da release, por digest |
| ALB Controller (Application Gateway for Containers) | 1.12.2 (Helm), Gateway API v1.5.1 standard; schemas em `deploy/k8s/schemas` | sem data publicada; o add-on do AKS 1.36 usa a linha 1.11.x | [release notes do ALB Controller](https://learn.microsoft.com/azure/application-gateway/for-containers/alb-controller-release-notes) | Mesma versão da camada de plataforma do tx02v2; mudou lá, rode a seção 5.7 |
| kubelogin | 0.2.21 | sem política de fim de suporte | [releases do kubelogin](https://github.com/Azure/kubelogin/releases) | Trimestral (seção 5.1) |
| `azure/login` | v3.1.0 (`a641126d1b8aa4d1fa005f4f92df94a3a4c4c906`) | sem data publicada | [releases do azure/login](https://github.com/Azure/login/releases) | Dependabot de actions; confira o SHA (seção 5.8) |
| Raízes de CA do PostgreSQL | DigiCert Global Root G2 (até 2038-01-15), Microsoft RSA e ECC Root CA 2017 (até 2042-07-18) | validade dos certificados | [Azure Certificate Authority details](https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details) | Trimestral: conferir a página e o documento de TLS do PostgreSQL; mudar uma raiz é mudança de contrato |
| Runners e devcontainer | Ubuntu 24.04 LTS (runners), Debian 13 (`javascript-node:24-trixie`) | Ubuntu 24.04: 2029-04 | ubuntu.com, debian.org | Trocar antes do fim |
| Exceções do trivy | nenhuma | — | `.trivyignore.yaml` | Seção 5.9 quando houver |

## 5. Procedimentos

### 5.1 Ferramenta do harness (trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl, kubelogin)

```bash
scripts/update-tool-checksums.sh kubelogin 0.2.22   # baixa o arquivo de checksums oficial da release
make tools && HARNESS_STRICT=1 make verify build
git diff tools/                                     # versions.env + checksums.txt
```

O script lê o arquivo de checksums publicado na release exata (shellcheck não publica: o script baixa
os três artefatos e calcula o SHA256). Leia as release notes antes; para o trivy, achados novos podem
aparecer só com a ferramenta nova.

### 5.2 Dependências npm

PRs do Dependabot: confira o CI e as release notes. À mão, sempre com versão exata e o lock junto:

```bash
npm install --save-exact --workspace api express@5.3.1   # ou --workspace web, ou sem workspace (raiz)
HARNESS_STRICT=1 make verify build && make e2e
```

Restrições: `typescript` dentro da faixa do `typescript-eslint`; `@types/node` na major do Node.js de
`.nvmrc`; `@vitejs/plugin-react` compatível com a major do Vite. Um PR do Dependabot que quebra uma
dessas restrições falha no `npm ci` (ERESOLVE) e deve ser fechado com um comentário, nunca forçado
com `--legacy-peer-deps`. Faça o mesmo bump no `dx01v2` (seção 5.10).

### 5.3 Major do Node.js (por exemplo 24 → 26)

1. `.nvmrc` e `engines.node` dos três `package.json` (`>=26 <27`); `@types/node` 26.
2. Imagem de build `node:26-alpine<versão>` nos dois Dockerfiles (mesmo digest) e runtime
   `gcr.io/distroless/nodejs26-debian13:nonroot` na API.
3. Devcontainer `javascript-node:26-*` por digest.
4. `HARNESS_STRICT=1 make verify build && make e2e`; o check `version-consistency` acusa o que faltar.

### 5.4 Digests de imagens

```bash
docker buildx imagetools inspect node:24-alpine3.24              # e nginxinc/nginx-unprivileged:1.30-alpine-slim
docker buildx imagetools inspect gcr.io/distroless/nodejs24-debian13:nonroot
docker buildx imagetools inspect postgres:17-alpine
docker buildx imagetools inspect mcr.microsoft.com/devcontainers/javascript-node:24-trixie
```

Use o digest do índice multiplataforma e atualize o comentário com a tag e a data. O digest do
PostgreSQL aparece em `compose.yaml`, `.github/workflows/ci.yml`,
`deploy/k8s/overlays/local/postgres.yaml` e `scripts/harness.sh` (o `version-consistency` exige o
mesmo nos quatro). Confira a versão real dentro da imagem, porque tags podem parar de ser
reconstruídas. Os digests das imagens do app são os mesmos do dx01v2: mude nos dois.

### 5.5 Kubernetes, kind e AKS

1. kind: `scripts/update-tool-checksums.sh kind <versão>`; a imagem do nó (`kind/kind-config.yaml`)
   vem das notas da release, sempre com `@sha256`.
2. kubectl na mesma minor do nó: `scripts/update-tool-checksums.sh kubectl <versão>`.
3. `K8S_SCHEMA_KUBERNETES_VERSION` em `scripts/harness.sh` (e um `K8S_SCHEMA_REF` que tenha essa
   versão). O `version-consistency` exige a mesma minor no nó, no kubectl e nos schemas.
4. A minor do AKS é do tx02v2 (contrato): mude os dois repositórios juntos.

### 5.6 Gate do trivy vermelho (imagens)

1. Leia a tabela do check `trivy-image:*` (pacote, versão instalada, versão corrigida).
2. Pacote do sistema (Alpine/Debian): atualize o digest da imagem base (5.4); se a correção ainda não
   chegou à imagem, espere a reconstrução ou troque de tag.
3. Pacote npm: atualize a dependência (5.2); se a vulnerável for transitiva, um `overrides` no
   `package.json` da raiz com versão exata, explicado no PR.
4. Sem correção aplicável e risco aceito: exceção temporária (seção 5.9 e `docs/GUARDRAILS.md`),
   nunca `--severity` mais baixo nem o gate desligado.

### 5.7 Schemas do kubeconform (catálogos e CRDs do ALB Controller)

- `K8S_SCHEMA_REF` (yannh/kubernetes-json-schema) e `CRD_SCHEMA_REF` (datreeio/CRDs-catalog, usado só
  para o `ExternalSecret`) em `scripts/harness.sh` apontam para commits fixos:
  `gh api 'repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/externalsecret_v1.json&per_page=1'`.
- Gateway API e `alb.networking.azure.io` vêm de `deploy/k8s/schemas`, gerados da imagem de CRDs do
  ALB Controller (`deploy/k8s/schemas/source.env`: versão e digest). Quando o tx02v2 mudar o ALB
  Controller:

  ```bash
  scripts/update-crd-schemas.sh 1.12.3      # resolve o digest da tag, reescreve source.env e os .json
  HARNESS_STRICT=1 make verify              # crd-schemas, kubeconform e contract-app
  git diff deploy/k8s/schemas               # revise: mudanças de campo podem exigir ajuste nos manifests
  ```

  Atualize a data em `source.env` e a linha do ALB Controller na seção 4. Nunca edite os `.json`.

### 5.8 Actions

Fora do Dependabot: `gh api repos/<o>/<r>/git/ref/tags/<tag>`; se `object.type == "tag"`, siga
`gh api repos/<o>/<r>/git/tags/<sha>`; use o SHA do commit com `# vX.Y.Z` e confirme que ele existe
(`gh api repos/<o>/<r>/commits/<sha>`; o v1 fixou um SHA inexistente do `azure/login`).

### 5.9 Revisão das exceções do trivy

Para cada entrada de `.trivyignore.yaml` perto do `expired_at`: o motivo ainda vale? Se sim, renove
por até ~7 meses com a justificativa atualizada; se não, corrija e remova a entrada.

### 5.10 Paridade com o dx01v2 e o dx03v2 (trimestral e a cada mudança de app)

O app (`api/`, `web/`, `e2e/`), a `base` dos manifests e o overlay `local` têm de continuar iguais aos
do `dx01v2` e do `dx03v2` (o app do Google Cloud, copiado deste repositório), a menos dos nomes.
Compare com a `main` do dx01v2 (abaixo) e repita o mesmo procedimento com o dx03v2:

```bash
ref="$(mktemp -d)"
git clone --quiet https://github.com/maringelix/dx01v2.git "$ref/dx01v2"
for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
  mkdir -p "$ref/norm/$d" && cp -R "$ref/dx01v2/$d/." "$ref/norm/$d/"
done
grep -rlI dx01v2 "$ref/norm" | xargs -r sed -i 's/dx01v2/dx02v2/g'
for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
  diff -ru -x node_modules -x dist -x coverage "$ref/norm/$d" "$d"
done
rm -rf "$ref"
```

Diferenças esperadas (só estas): `e2e/smoke.mjs` e `e2e/lib.mjs` (`SMOKE_EDGE` no lugar do
`SMOKE_BEHIND_WAF`, CSP exata em `/api`); `api/test/integration/rate-limit.test.ts` (só comentários:
os casos do AGC e do load balancer do Google Cloud estão nos três repositórios do app);
`api/test/unit/config.test.ts` (caminho de exemplo do CA); comentários em
`api/src/app.ts`, `api/src/server.ts`, `web/src/api.ts`, `web/vite.config.ts`,
`web/nginx/default.conf` e nos manifests da `base` e do `local`. Qualquer outra diferença é deriva:
porte a correção para o repositório que ficou para trás (um PR em cada) ou registre no CHANGELOG por
que ela é só da Azure.

## 6. Resposta a problemas

| Situação | Primeiros passos |
|---|---|
| CI vermelho | Leia o primeiro `FAIL` (o log do check vem logo abaixo). Corrija no código; nunca enfraqueça o check. Reproduza com `HARNESS_STRICT=1 make verify build` e `make e2e` |
| Vulnerabilidade | Gate do trivy: 5.6. Alerta do Dependabot ou advisory: atualize por PR (nos dois repositórios do app). Reporte privado: `SECURITY.md` |
| Credencial exposta | Local: `scripts/dev-env.sh --force` e `docker compose -p dx02v2-dev down -v`. Azure: gire o valor no Key Vault (tx02v2), espere o ESO sincronizar (até 1 h) e `kubectl -n dx02v2 rollout restart deployment/api`. Identidade do GitHub: remova a credencial federada (tx02v2). Reescrever histórico é decisão do mantenedor |
| Alerta de custo | Siga o tx02v2 (checagem de sobras, destroy); o app só programa o Gateway no AGC do tx02v2, mas o AGC cobra enquanto existir |
| Sobras após o destroy | Runbook do tx02v2; registre no `cloud_run_report` |
| Download das raízes de CA ou dos CRDs recusado | Um thumbprint ou digest diferente nunca é aceito: confira as fontes oficiais; mudar uma raiz é mudança de contrato; mudar o ALB Controller é a seção 5.7 |

## 7. Registro de execuções em nuvem

Toda rodada gera uma issue com o template `cloud_run_report` (data, região, commits, versão do ALB
Controller, passos, duração, custo observado, saída do smoke test, problemas, sobras). A matriz de
status do README só muda com essa evidência.

## 8. Responsáveis

Mantenedor: @maringelix (decisões, merges, rodadas em nuvem). Agentes de IA seguem o `AGENTS.md`.
