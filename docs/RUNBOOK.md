# Runbook do dx02v2

Passo a passo para desenvolver e testar o app localmente (npm, compose, kind) e para publicá-lo no
cluster AKS do tx02v2. O caminho local é grátis e `verificado localmente`; o deploy na Azure nunca foi
executado (`não executado em nuvem (v2)`): você será a primeira evidência.

## 1. Pré-requisitos locais

- Docker e o devcontainer (`.devcontainer/devcontainer.json`, com Docker-in-Docker), ou Linux/WSL 2
  com Docker, bash >= 4.4, Node.js 24 (`.nvmrc`), curl, unzip, xz, git e make.
- `make tools` instala trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl e
  kubelogin fixados em `.tools/`.
- Portas locais: 8080 (compose, `WEB_PORT`, só 127.0.0.1), 15432 (PostgreSQL de desenvolvimento, só
  127.0.0.1), 5173 (Vite, só 127.0.0.1) e 3000/9464 (API em desenvolvimento, todas as interfaces).

## 2. Desenvolvimento com npm workspaces

Um único `package-lock.json` na raiz; os workspaces são `api` e `web`.

```bash
npm ci
# PostgreSQL 17 descartável em 127.0.0.1:15432, senha e token aleatórios só nesta sessão do shell
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx02v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx02v2 -e POSTGRES_USER=dx02v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx02v2 DB_USER=dx02v2
node api/src/migrate.ts            # migrações (o Node.js 24 executa TypeScript direto)
npm run dev --workspace api        # API na porta 3000, métricas na 9464, recarrega ao salvar
npm run dev --workspace web        # outro terminal: Vite em http://127.0.0.1:5173 (/api → :3000)
docker rm -f dx02v2-dev-pg         # ao terminar
```

Comandos úteis: `npm run lint`, `npm run typecheck`, `npm run format`, `npm run build`; testes:
`npm run test:coverage --workspace web` e, para a API, que usa o banco de `DB_*` e **apaga e recria
as tabelas**, um banco cujo nome termina em `_test` (os testes recusam qualquer outro nome):

```bash
docker exec dx02v2-dev-pg createdb -U dx02v2 dx02v2_test
DB_NAME=dx02v2_test npm run test:coverage --workspace api
```

O gate completo é `HARNESS_STRICT=1 make verify`: sem `DB_HOST` ele sobe um PostgreSQL descartável;
com `DB_*` exportadas, usa esse banco e recusa um `DB_NAME` que não termine em `_test` (neste shell:
`env -u DB_HOST HARNESS_STRICT=1 make verify`).

## 3. Stack do compose (projeto `dx02v2-dev`)

```bash
scripts/dev-env.sh                                  # .env com DB_PASSWORD e ADMIN_TOKEN aleatórios (600)
docker compose -p dx02v2-dev up -d --build --wait   # db → migrate → api → web
scripts/compose-smoke.sh                            # e2e/smoke.mjs contra http://127.0.0.1:8080
docker compose -p dx02v2-dev down -v                # remove containers, rede e volume do banco
```

- Só o web é publicado (`127.0.0.1:${WEB_PORT:-8080}`); a API e o banco ficam em redes internas.
- Containers com root filesystem somente leitura, `cap_drop: [ALL]` e `no-new-privileges`.
- O modo admin da página aceita o `ADMIN_TOKEN` do `.env` (fica só na memória da aba).
- Trocar os segredos: `scripts/dev-env.sh --force` e depois `down -v` (o volume guarda a senha antiga).
- Outra porta: `WEB_PORT=18080 scripts/dev-env.sh --force`.

## 4. Ponta a ponta no kind (`make e2e`)

```bash
make tools
make e2e                         # cria dx02v2-e2e, testa e apaga o cluster
KEEP_CLUSTER=1 make e2e          # mantém o cluster para investigar
kind get kubeconfig --name dx02v2-e2e > /tmp/dx02v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx02v2-e2e.kubeconfig kubectl -n dx02v2 get pods,svc,networkpolicy
kind delete cluster --name dx02v2-e2e
```

O script (`scripts/e2e-kind.sh`) constrói as imagens `dx02v2-api:e2e` e `dx02v2-web:e2e`, cria o
cluster a partir de `kind/kind-config.yaml` (nó v1.36.4 por digest), carrega as imagens, cria os
Secrets com valores aleatórios, aplica `deploy/k8s/overlays/local`, espera os rollouts, prova que o
namespace rejeita um pod privilegiado, roda o smoke test por um port-forward para `svc/web` e testa
as NetworkPolicies com pods descartáveis. Em caso de falha, os diagnósticos ficam em
`$TMPDIR/dx02v2-harness/e2e-diagnostics`.

## 5. Azure: pré-requisitos

> **Custo**: o app roda no lab do tx02v2, e o maior item é o Application Gateway for Containers com o
> WAF (cerca de US$0,28 por hora; US$0,155 sem o WAF; preços de referência da Azure Retail Prices API,
> eastus2, 2026-10-11), além dos nós do AKS e do PostgreSQL. Ver o `docs/CUSTOS.md` do tx02v2 e a
> calculadora oficial. Destrua no mesmo dia.

1. tx02v2: bootstrap, apply e plataforma concluídos (runbook do tx02v2): ALB Controller com a
   GatewayClass `azure-alb-external`, External Secrets Operator com o ClusterSecretStore
   `azure-key-vault`, namespace `dx02v2` com a Role `dx02v2-deployer` e a RoleBinding
   `dx02v2-deployers`. O object ID da identidade `dx02v2-gha-deploy` precisa estar na RoleBinding (o
   tx02v2 faz isso); para deploy a partir de um laptop, o seu object ID também (`app_deployer_principal_ids`
   do tx02v2), além dos papéis Azure da seção 6.
2. Repositório dx02v2 público com `scripts/repo-guardrails.sh` aplicado (environment `lab` com
   revisor obrigatório e só `main`; o sujeito OIDC aceito pela credencial federada é
   `repo:<owner>/dx02v2:environment:lab`).
3. Variáveis do GitHub (seção 6).

## 6. Variáveis do GitHub e papéis Azure

Settings > Secrets and variables > Actions > **Variables** (aparecem nos logs: nada privado; o
workflow confere o formato antes de tudo e o `azure/login` mascara o client ID).

| Variável | Exemplo | Uso |
|---|---|---|
| `AZURE_CLIENT_ID` | `00000000-0000-0000-0000-000000000000` | client ID da managed identity `dx02v2-gha-deploy` (output do bootstrap do tx02v2) |
| `AZURE_TENANT_ID` | `00000000-0000-0000-0000-000000000000` | tenant do Entra ID |
| `AZURE_SUBSCRIPTION_ID` | `00000000-0000-0000-0000-000000000000` | assinatura do lab (precisa ser a do `agc/id` da App Configuration) |
| `AZURE_APPCONFIG_ENDPOINT` | `https://tx02v2-lab-00000000.azconfig.io` | endpoint do store do contrato (output do tx02v2) |

Papéis Azure do principal que faz o deploy (o tx02v2 atribui à `dx02v2-gha-deploy`): `AcrPush` no
registry, `Azure Kubernetes Service Cluster User Role` no cluster e `App Configuration Data Reader` no
store. A partir de um laptop, o seu usuário precisa dos mesmos três papéis: o tx02v2 os atribui a
cada object ID em `app_deployer_principal_ids`, junto com a RoleBinding (`docs/CONTRATO.md`).

## 7. Deploy

No Actions, abra `deploy-azure`, escolha a branch `main`, selecione `mode=gitops` (padrão) e aprove
o environment `lab`. O modo GitOps exige o perfil `full` do tx02v2, a Application `dx02v2` no Argo
CD e permissão para publicar `gitops/azure`. Use `mode=push` somente se o Argo CD não estiver
gerenciando o app.

O job confere as variáveis, instala `kubectl`/`kubelogin`, autentica com `azure/login` e roda
`scripts/deploy-azure.sh`, que:

1. lê as 15 chaves `tx02v2/lab/*` da App Configuration e confere grupo de recursos, cluster, segredos e formatos;
2. obtém kubeconfig temporário, confere API groups, a RBAC do namespace e, no modo GitOps, o direito de atualizar a Application `dx02v2`;
3. faz login no ACR, reaproveita tags existentes, constrói e publica as imagens `linux/amd64` que faltam;
4. cria o ConfigMap `azure-pg-ca` com as três raízes verificadas e renderiza/valida o overlay `azure-waf` ou `azure`. Em `mode=gitops`, configura os valores reais na Application, publica o commit do app com `params.env` de exemplo na branch `gitops/azure` e pede refresh ao Argo CD. Em `mode=push`, aplica o overlay com `kubectl apply -k`;
5. no modo GitOps, espera a Application estar `Synced` e `Healthy` no commit publicado; depois espera ExternalSecrets e rollouts e confere as imagens SHA nos Deployments;
6. espera o Gateway `Programmed` e, com WAF, a política `Accepted`; roda `e2e/smoke.mjs` pelo AGC. Como o frontend só fala HTTP, o token de admin não é lido nem enviado.

De um laptop, faça `az login`, selecione a assinatura do lab e configure a autenticação Git para publicar a branch:

    make tools
    AZURE_APPCONFIG_ENDPOINT=https://tx02v2-lab-<sufixo>.azconfig.io scripts/deploy-azure.sh

Sem Argo CD, use `DEPLOY_MODE=push AZURE_APPCONFIG_ENDPOINT=... scripts/deploy-azure.sh`.

## 8. Conferir

```bash
az aks get-credentials --resource-group tx02v2-lab --name tx02v2-lab --file /tmp/dx02v2-lab.kubeconfig
kubelogin convert-kubeconfig -l azurecli --kubeconfig /tmp/dx02v2-lab.kubeconfig
export KUBECONFIG=/tmp/dx02v2-lab.kubeconfig
kubectl -n dx02v2 get pods,gateway,httproute,externalsecrets,hpa
kubectl -n dx02v2 get healthcheckpolicy,webapplicationfirewallpolicy
curl -fsS "http://$(kubectl -n dx02v2 get gateway dx02v2 -o jsonpath='{.status.addresses[0].value}')/api/info"
```

Traces (contrato v2): depois de algumas requisições, o serviço `dx02v2-api` aparece no Application
Insights `tx02v2-lab-traces` (Transaction search). O caminho é API →
`opentelemetry-collector.observability` (OTLP/HTTP, porta 4318) → Application Insights; o Collector, a
identidade e o papel são do tx02v2.

## 9. Desligar

O teardown é o do tx02v2 (workflow de destroy + checagem de sobras), que remove o AGC, o AKS, o
PostgreSQL e o ACR. Para tirar só a entrada do app e manter o cluster:
`kubectl -n dx02v2 delete gateway dx02v2` (o AGC e o frontend continuam do tx02v2 e continuam
cobrando).

## 10. Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `the App Configuration key ... is missing` | tx02v2 não aplicado, ou endpoint errado | aplique o tx02v2 ou corrija `AZURE_APPCONFIG_ENDPOINT` |
| `cannot read the App Configuration keys` | sem `App Configuration Data Reader` no store | papéis da seção 6 |
| `logged in to another subscription` | `az` em outra assinatura | `az account set --subscription <assinatura do lab>` |
| `AADSTS700024: Client assertion is not within its valid time range` | o token OIDC do GitHub expirou antes de o `az` obter um token novo | rode o workflow de novo; não coloque passos lentos entre o `azure/login` e o deploy |
| `the cluster does not serve ...` | camada de plataforma do tx02v2 não instalada | rode o workflow de plataforma do tx02v2 |
| `this principal cannot deploy to namespace dx02v2 (...)` | sem RoleBinding `dx02v2-deployers` para este object ID, ou regra faltando na Role | confira a plataforma do tx02v2; a Role usa os plurais dos CRDs do AGC, `healthcheckpolicy` e `webapplicationfirewallpolicy` (`docs/CONTRATO.md`) |
| `docker login to ... failed` | sem `AcrPush` no registry | papéis da seção 6 |
| `refusing https://...: SHA-1 thumbprint ...` | a raiz baixada não é a do contrato | pare: confira a página "Azure Certificate Authority details"; mudar a raiz é mudança de contrato |
| ExternalSecret não fica `Ready` | ClusterSecretStore, identidade do ESO ou segredo ausente | `kubectl -n dx02v2 describe externalsecret db-credentials`; confira a plataforma do tx02v2 |
| initContainer `migrate` falha com erro de TLS | ConfigMap `azure-pg-ca` ausente, ou `host` do segredo não é o FQDN do servidor | o script recria o ConfigMap; confira o `host` em `tx02v2-lab-db-app` |
| Gateway sem `Programmed` | ALB Controller, `agc/id` ou `agc/frontend-name` errados | `kubectl -n dx02v2 describe gateway dx02v2` (eventos do controller) |
| WebApplicationFirewallPolicy sem `Accepted` | SecurityPolicy do AGC no tx02v2, ou política em outra assinatura/região | `kubectl -n dx02v2 describe webapplicationfirewallpolicy dx02v2` |
| Smoke com 403 em tudo | regra do WAF (Bot Manager, regra personalizada) | logs do WAF no tx02v2; nenhuma regra pode bloquear o smoke (contrato) |
| Smoke falha em `X-Request-Id` | o AGC não substituiu o `x-request-id` como a documentação descreve | registre no `cloud_run_report`; a asserção muda nos dois repositórios só com evidência |
| `ImagePullBackOff` | a identidade kubelet do AKS sem `AcrPull` no registry | o tx02v2 atribui esse papel no apply (contrato); confira o apply e as atribuições do registry |
| Nenhum trace no Application Insights | Collector ausente (plataforma antiga do tx02v2, contrato v1) ou o Entra ID recusou a ingestão | `kubectl -n observability get pods`; logs do Collector (`kubectl -n observability logs deployment/opentelemetry-collector`); a API nunca falha por isso: os spans só se perdem |

## 11. Registro

Abra uma issue com o template **Cloud run report**: data, região, commits do dx02v2/tx02v2, versão do
ALB Controller, passos, duração, custo observado, saída do smoke test, problemas e a saída (redigida)
da checagem de sobras do tx02v2.
