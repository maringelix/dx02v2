# Guardrails do dx02v2

Um guardrail é uma regra mais o mecanismo que a faz valer — automático sempre que possível. Este
documento lista as regras do repositório, onde cada uma é aplicada e o que elas não garantem.
Tipos: `bloqueante` (falha o harness/CI), `alerta` (notifica), `processo` (disciplina humana/agente).

## Regras

| ID | Regra | Por quê | Onde é aplicada | Tipo |
|---|---|---|---|---|
| SEC-01 | Nenhum segredo no repositório | repositório público; histórico é para sempre | `gitleaks` (harness, pre-commit) | bloqueante |
| SEC-02 | Sem identificadores reais: GUIDs só `00000000-0000-0000-0000-000000000000` (assinatura, tenant, client e object IDs), sufixo dos nomes do tx02v2 só `00000000`, IDs de 12 dígitos só `123456789012`, e-mails `example.com`, IPs privados ou RFC 5737 | evita expor assinaturas, identidades e pessoas | check `policy-identifiers` | bloqueante |
| SEC-03 | Credenciais locais geradas em tempo de execução com valores aleatórios (`scripts/dev-env.sh`, `scripts/e2e-kind.sh`); `.env` ignorado pelo git; `.env.example` só com placeholders; nenhum `Secret` nos manifests | nada de senha padrão copiada para todo lado | `.gitignore`, `gitleaks`, `contract-app` | bloqueante |
| SEC-04 | GitHub → Azure só por OIDC (`azure/login` com a managed identity `dx02v2-gha-deploy`, sujeito imutável do environment `lab`, com os IDs do dono e do repositório); `id-token: write` só no job `deploy` do `deploy-azure.yml`, nunca no `ci.yml`; nada de `creds:`, `client-secret` ou inputs interpolados | sem segredos de service principal; nenhum outro workflow obtém credenciais (erros do v1); um nome de conta apagado e registrado de novo não herda o lab | `policy-workflows`; `scripts/repo-guardrails.sh` confere o `sub` do repositório | bloqueante |
| SEC-05 | Token de admin com 32+ caracteres, comparado em tempo constante; sem token configurado a rota responde 503 `admin_disabled` | nada de token curto nem comparação que vaza tempo | `api/src/config.ts`, testes `admin-auth`, `config`, `messages` | bloqueante |
| SEC-06 | Logs redigem `Authorization`, `Cookie` e campos `password`/`token`; o deploy mascara no GitHub Actions o token do smoke e os identificadores lidos da App Configuration | segredos e IDs não vão parar em logs públicos | `api/src/logger.ts` + teste `logger`; `scripts/deploy-azure.sh` | bloqueante / processo |
| SEC-07 | O TLS do banco na Azure só confia nas três raízes do contrato, baixadas e conferidas pelo thumbprint SHA-1; `verify-full` obrigatório com `APP_ENV=lab` | um download adulterado não vira raiz de confiança | `scripts/deploy-azure.sh`; `contract-app` (thumbprints); teste `config` | bloqueante |
| SEC-08 | Testes e scripts só agem no que é do lab: os testes de integração, que apagam e recriam tabelas, só aceitam um banco cujo nome termina em `_test`; o `scripts/deploy-local.sh` só faz deploy no contexto `kind-tx02v2-local` | quem faz fork roda o harness na própria máquina, onde `DB_*` e o contexto atual do kubectl podem apontar para outro trabalho | `requireTestDatabase` (`api/test/integration/helpers.ts`) + teste `test-database`; check `test:api`; `require_lab_context` (`scripts/deploy-local.sh`) | bloqueante |
| SEC-09 | O smoke test nunca manda o token de admin por HTTP puro para outra máquina: com HTTPS ou em `127.0.0.1` ele manda; senão pula só a chamada que precisa do token (o `deploy-azure.sh` nem lê o token, porque o frontend do AGC só fala HTTP) | o frontend do lab sem certificado é a internet | `e2e/smoke.mjs`, `scripts/deploy-azure.sh` | bloqueante |
| SEC-10 | `rm -rf` em `scripts/lib/k8s.sh` só com variável não vazia (`${dest:?}`, `${tmp:?}`) | um destino vazio não pode apagar o que o caminho passa a ser | `policy-app` | bloqueante |
| SUP-01 | Ferramentas do harness com versão e SHA256 fixados; divergência é erro fatal | cadeia de suprimentos | `scripts/install-tools.sh`, `tools/checksums.txt` | bloqueante |
| SUP-02 | Toda action fixada por SHA de 40 caracteres com comentário `# vX.Y.Z` | tags podem ser movidas; o v1 fixou um SHA inexistente do `azure/login` | `policy-workflows` | bloqueante |
| SUP-03 | Toda imagem por digest (Dockerfiles, compose, manifests, CI, kind, devcontainer e features); nada de `:latest` | erro do v1: trivy `latest` malicioso em março de 2026 | `policy-images` | bloqueante |
| SUP-04 | npm com versões exatas em todos os `package.json` e `package-lock.json` em sincronia | lockfile fora de sincronia quebra builds | `version-consistency`, `npm-ci` (`npm ci` sempre no modo estrito) | bloqueante |
| SUP-05 | trivy só via `scripts/install-tools.sh` (nunca `trivy-action`/`setup-trivy`, GHSA-69fq-xp46-6x23) | incidente de cadeia de suprimentos de março de 2026 | `policy-workflows` | bloqueante |
| SUP-06 | Imagens sem vulnerabilidades HIGH/CRITICAL com correção disponível | o que é publicado não carrega CVE conhecido e corrigível | `trivy-image:api`, `trivy-image:web` | bloqueante |
| SUP-07 | Versões coerentes entre arquivos: Node.js (`.nvmrc`, `engines`, imagem de build), digest do PostgreSQL (compose, CI, kind, harness), minor do Kubernetes (kind, kubectl, schemas) | uma atualização pela metade não passa | `version-consistency` | bloqueante |
| SUP-08 | Dependabot mensal (npm, docker, actions, pre-commit), minor+patch agrupados, majors separados | nada apodrece em silêncio | `.github/dependabot.yml` | alerta |
| SUP-09 | Schemas dos CRDs (Gateway API, Application Gateway for Containers) gerados dos CRDs do ALB Controller fixado por digest, nunca editados à mão | o kubeconform valida contra o que o cluster recebe | `crd-schemas` (`scripts/update-crd-schemas.sh --check`) | bloqueante |
| K8S-01 | Manifests renderizados válidos com kubeconform estrito e schemas fixados (Kubernetes 1.36, Gateway API v1.5.1 standard, `alb.networking.azure.io/v1`, `ExternalSecret`) | manifest inválido não chega ao cluster | `kubeconform` | bloqueante |
| K8S-02 | Pods conforme Pod Security `restricted`: `runAsNonRoot`, uid numérico, seccomp `RuntimeDefault`, sem escalada de privilégio, `drop: [ALL]`, `readOnlyRootFilesystem`, sem token de service account, sem `hostPath`/host namespaces, requests e limite de memória | menor privilégio; o namespace do AKS impõe `restricted` | `contract-app`; no kind, o e2e prova que um pod privilegiado é rejeitado | bloqueante |
| K8S-03 | NetworkPolicies: nega tudo (entrada e saída) e libera só DNS, web → api:3000, api → PostgreSQL:5432 (local) ou a subnet do PostgreSQL (Azure), a subnet do AGC → web:8080 e api:3000 (um CIDR por regra, sem `except`) e métricas só do namespace `monitoring` | um pod comprometido não alcança o banco; erro do v1: regra sem `from` e saída para qualquer IP | `contract-app`; sondas do e2e no kind | bloqueante |
| K8S-04 | Overlays `azure*` só com os tipos que a Role `dx02v2-deployer` pode escrever, só a anotação `alb.networking.azure.io/alb-id` (no Gateway) e o label `app.kubernetes.io/part-of: dx02v2` em tudo; namespace e RBAC são do tx02v2 | o deploy roda com privilégio mínimo | `contract-app`; preflight `kubectl auth can-i` do deploy | bloqueante |
| K8S-05 | `trivy config` sem achados HIGH/CRITICAL nos manifests renderizados e nos Dockerfiles | segurança da configuração | `trivy-config` | bloqueante |
| K8S-06 | Tráfego Azure só pelo Gateway `dx02v2` (HTTP 80, uma HTTPRoute: `/api` → api:3000, `/` → web:8080) com HealthCheckPolicies `/healthz` e `/readyz` e, com o WAF, a WebApplicationFirewallPolicy no Gateway inteiro | nada fica exposto fora do contrato | `contract-app` | bloqueante |
| APP-01 | `trust proxy` é uma contagem de saltos (`TRUST_PROXY_HOPS`), nunca `true`; o rate limit usa `req.ip` | `X-Forwarded-For` falso não fura o limite | `policy-app`; teste `rate-limit` (inclui o formato do AGC); smoke (429 com XFF falso diferente a cada requisição) | bloqueante |
| APP-02 | Sem middleware de CORS (mesma origem) e sem escapar HTML antes de gravar; a UI renderiza texto como texto | erro do v1: CORS fixo em localhost | `policy-app`; testes de integração e smoke (texto com `<b>` volta igual) | bloqueante |
| APP-03 | UI sem estilos nem scripts inline (CSP `script-src 'self'; style-src 'self'`) e sem sourcemaps publicados | erros do v1: `unsafe-inline` e sourcemap público | `policy-app`; smoke; `image-policy:web` | bloqueante |
| APP-04 | Cabeçalhos de segurança em toda resposta do nginx, inclusive assets e erros; HSTS só para requisições HTTPS; `server_tokens off` | erro do v1: HSTS com preload em HTTP | `policy-app`; smoke | bloqueante |
| APP-05 | Erros sempre em JSON `{"error":{"code","message","requestId"}}`, sem detalhes internos: 400, 413, 404, 415, 429, 500, 503 | erro do v1: tudo virava 500 | testes de integração; smoke | bloqueante |
| APP-06 | A API loga só pelo pino (JSON, com request ID em cada linha) | logs estruturados e redigidos | `policy-app` (nada de `console.*`); eslint `no-console` | bloqueante |
| APP-07 | O token de admin fica só em memória no navegador | nada de credencial em `localStorage`/cookie | `policy-app` | bloqueante |
| APP-08 | Imagem da API distroless, sem shell nem npm/npx/corepack; as duas imagens com uid:gid numérico não root e labels OCI `source`/`revision` | menor superfície de ataque | `policy-images`, `image-policy:api`, `image-policy:web`, `hadolint` | bloqueante |
| APP-09 | Cobertura mínima: API linhas >= 80 % e branches >= 70 %; web linhas >= 70 %; os testes exercitam o código real | erro do v1: `expect(true).toBe(true)` | limites do vitest (`test:api`, `test:web`) | bloqueante |
| APP-10 | Migrações aplicadas nunca são editadas (checksum em `schema_migrations`); uma por transação, sob advisory lock | réplicas e initContainers concorrentes não corrompem o schema | `api/src/migrate.ts`; teste `migrations` | bloqueante |
| APP-11 | Contrato com o tx02v2 versionado; mudanças em PRs coordenados nos dois repositórios | os dois lados evoluem juntos | `docs/CONTRATO.md`, `contract-app` | processo |
| APP-12 | O app é o mesmo do dx01v2: mudanças em `api/`, `web/` e `e2e/` vão para os dois repositórios | a comparação entre nuvens continua justa | template de PR; rotina de paridade (`docs/SUSTENTACAO.md`) | processo |
| APP-13 | Nada do caminho da outra nuvem do dx01v2 volta (arquivos, manifests, workflows, scripts, docs); só README, ARQUITETURA e CHANGELOG comparam a família | o repositório descreve só o que faz | `policy-cloud`; `contract-app` (manifests renderizados) | bloqueante |
| CUSTO-01 | Deploy só por `workflow_dispatch`, sem inputs, e environment `lab` (revisor obrigatório); o workflow usa GitOps e `contents: write` fica só no job de deploy | intenção explícita e push limitado ao job de deploy | `policy-workflows`, `scripts/publish-gitops.sh` | bloqueante |
| CUSTO-02 | Rodada em nuvem termina no mesmo dia com o destroy do tx02v2 + checagem de sobras e um relatório `cloud_run_report` | o AGC com WAF (o maior item), o AKS e o PostgreSQL cobram por hora | `docs/RUNBOOK.md` | processo |
| CUSTO-03 | O deploy nunca sobrescreve uma tag do ACR e falha antes do build se a plataforma ou a RBAC não estiverem prontas | nada de imagem trocada nem build pago à toa | `scripts/deploy-azure.sh` | bloqueante (no deploy) |
| CI-01 | O CI é o harness: as checagens vivem em `scripts/harness.sh` e os jobs só chamam `make <alvo>` | o que passa local passa no CI | revisão de PR; `ci.yml` | processo |
| CI-02 | Sem `continue-on-error: true`, `\|\| true`, `\|\| echo` em workflows | gates honestos; erro do v1: job de "lint" que só rodava `npm install` | `policy-workflows` | bloqueante |
| CI-03 | `permissions: contents: read` no topo, `timeout-minutes`, `concurrency`, `ubuntu-24.04`, `persist-credentials: false` | menor privilégio e previsibilidade | `policy-workflows` | bloqueante |
| CI-04 | `HARNESS_STRICT=1` no CI: todo SKIP vira FAIL e as versões das ferramentas precisam bater; o CI não usa segredos | nada é pulado em silêncio; erro do v1: job vermelho por um segredo que nunca existiu | `ci.yml`, `scripts/harness.sh` | bloqueante |
| CI-05 | O job `e2e` testa exatamente as imagens que o job `images` construiu e escaneou (artefato) | o que vai para o cluster é o que passou no trivy | `ci.yml` | processo |
| CI-06 | CI semanal agendado (segunda 06:00 UTC) | detecta CVEs novos, ignores vencidos e URLs quebradas | `ci.yml` | alerta |
| MUD-01 | `main` protegido por ruleset: PR obrigatório, checks `static`, `test`, `images` e `e2e` estritos, sem force-push | toda mudança passa pelo harness | `.github/rulesets/main.json` + `scripts/repo-guardrails.sh` | bloqueante (depois de publicado) |
| MUD-02 | Ignore de scanner só com `statement` e `expired_at` em até ~7 meses | exceções revisadas | `trivyignore-policy` | bloqueante |
| MUD-03 | Conventional Commits; um assunto por PR; CHANGELOG `[Unreleased]` atualizado | histórico legível | template de PR | processo |
| DOC-01 | README e docs só afirmam o que é verificado, com os rótulos exatos; sem auto-elogios; texto UTF-8 com LF | erro do v1: README/CHANGELOG com afirmações falsas e manifests em UTF-16 | `repo-structure` (rótulos, auto-elogios, tamanho do README, LF, UTF-8 sem BOM); revisão | bloqueante |
| DOC-02 | Docs atualizadas na mesma mudança do código | docs não envelhecem | template de PR | processo |
| AGT-01 | Agentes de IA nunca executam ações que alteram a nuvem sem pedido humano explícito na tarefa | dinheiro e segurança | `AGENTS.md` | processo |
| AGT-02 | Agentes não enfraquecem gates, não baixam cobertura e não adicionam ignores sem justificativa e validade | o harness só vale se for respeitado | `AGENTS.md`; checks acima | processo |
| LOC-01 | No lab local o app entra só pelo GitOps (Argo CD, AppProject `dx02v2`); o deploy não aplica manifests do app direto no cluster | um único dono do namespace (v1 tinha dois) | `scripts/deploy-local.sh`; sonda `gitops` | bloqueante (job `e2e-platform`) |
| LOC-02 | No lab local: mTLS `STRICT`, `AuthorizationPolicy` por identidade e NetworkPolicies com HBONE e as sondas do kubelet do ambient | zero trust com identidade, não só por IP | `contract-app` (`local-platform`); sonda `mesh` | bloqueante |
| LOC-03 | Toda regra de alerta usa uma série que o app ou o kube-state-metrics exporta e tem teste no promtool | v1 alertava sobre séries inexistentes | `promtool-rules`; sonda `observability` | bloqueante |
| AGT-03 | Agentes param e perguntam nos casos listados em `AGENTS.md` | decisões caras são humanas | `AGENTS.md` | processo |

## Exceções

Uma exceção é um ignore de scanner. Para adicionar uma:

1. Confirme que o achado é uma escolha deliberada do lab ou que não há como corrigi-lo agora (não um
   defeito a corrigir).
2. Adicione a entrada em `.trivyignore.yaml` com `id`, `paths` ou `purls` (o mais restrito possível),
   `statement` (por que é aceitável e o que compensa o risco) e `expired_at` em até ~7 meses.
3. Explique a exceção no PR. O check `trivyignore-policy` rejeita entradas sem justificativa, sem
   validade, vencidas ou longas demais; o trivy deixa de aplicar uma entrada vencida.

As outras exclusões são fixas e explicadas no próprio check: o `policy-identifiers` não examina
`package-lock.json`, `tools/checksums.txt` e `deploy/k8s/schemas` (hashes e exemplos dos CRDs
oficiais, garantidos pelo `crd-schemas`) e aceita um UUID de teste da API; o `policy-cloud` deixa
README, ARQUITETURA e CHANGELOG nomearem a outra nuvem, porque comparam a família.

Exceções atuais do trivy (verificado em 2026-10-11): nenhuma. O gate das imagens usa
`--ignore-unfixed`: vulnerabilidades sem correção publicada e as de severidade LOW/MEDIUM não falham o
build; o harness imprime a contagem completa no resumo de `trivy-image:*` para acompanhamento.

## Limites (o que NÃO é garantido)

- Nada do v2 rodou na Azure: o deploy, o ExternalSecrets com o Key Vault, o Gateway no Application
  Gateway for Containers, a política de WAF, o TLS com o PostgreSQL (`verify-full`) e o preflight de
  RBAC foram renderizados, validados e exercitados com `az`/`kubectl`/`kubelogin`/`docker` simulados,
  não contra a nuvem.
- O e2e prova o enforcement de NetworkPolicy com o kindnet do kind (kube-network-policies), não com o
  Cilium do AKS; as regras por CIDR (subnet do AGC e do PostgreSQL) só existem nos overlays `azure*`.
- O rate limit de escrita fica em memória por réplica da API: com N réplicas o limite efetivo chega a
  N vezes o configurado.
- O token de admin é um segredo único e compartilhado (sem usuários, sem rotação automática); trocar o
  valor no Key Vault exige reiniciar os pods da API depois da sincronização do ESO.
- O smoke test pelo AGC lê o token de admin do Secret `app-secrets` (o deployer pode ler Secrets) e o
  mascara nos logs do GitHub Actions; quem pode disparar o deploy pode ver o token.
- As tags do ACR Basic são mutáveis: o deploy nunca faz push sobre uma tag existente, mas não prova
  quem a publicou; quem tem `AcrPush` no registry poderia trocar a imagem de um commit.
- Os tokens do Azure CLI obtidos no começo do deploy valem cerca de uma hora; um deploy que passe
  disso falha nas últimas chamadas ao cluster.
- `trivy --ignore-unfixed` não bloqueia CVEs sem correção; o agendamento semanal os reavalia.
- Não há HTTPS na Azure ainda (listener HTTP no AGC, `planejado`); localmente também não há TLS.
- Antes do primeiro commit, o `gitleaks` examina só os arquivos visíveis ao git (versionados e não
  ignorados); depois, todo o histórico.
- O bit executável dos scripts só é checado para arquivos já no índice do git.

## Como verificar

```bash
make tools                  # ferramentas fixadas em .tools/
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list     # todos os checks e estágios
```
