# Contrato tx02v2 <-> dx02v2 — versão 2 (2026-10-14)

Versão 2: o OpenTelemetry Collector da camada de plataforma do tx02v2 recebe os traces do app. A versão
1 (2026-10-11) não tinha traces.

Interface entre a infraestrutura (`tx02v2`) e a aplicação (este repositório), na parte que o app usa.
A fonte da verdade é o
[`docs/CONTRATO.md` do tx02v2](https://github.com/maringelix/tx02v2/blob/main/docs/CONTRATO.md):
em caso de divergência, vale aquele arquivo. Qualquer mudança exige PRs coordenados nos dois
repositórios e incremento da versão.

## Como o contrato é verificado aqui

| O quê | Onde | Status |
|---|---|---|
| Nomes de Services, portas, probes, Secrets, ConfigMap, Gateway (classe, anotação, frontend, listener), HTTPRoute (rotas), HealthCheckPolicies, WebApplicationFirewallPolicy, ExternalSecrets, HPA, NetworkPolicies, labels, só tipos que a Role `dx02v2-deployer` pode escrever | check `contract-app` (`scripts/check-manifests.mjs` sobre os overlays renderizados `azure` e `azure-waf`) | `verificado localmente` |
| Endpoint OTLP da versão 2 no ConfigMap da API e NetworkPolicy só até o Collector (namespace `observability`, porta 4318) | check `contract-app` | `verificado localmente` |
| Manifests válidos para Kubernetes 1.36, para os CRDs do ALB Controller 1.12.2 (Gateway API v1.5.1 standard, `alb.networking.azure.io/v1`) e para o CRD `ExternalSecret` (`external-secrets.io/v1`) | checks `crd-schemas` e `kubeconform` (estrito) | `verificado localmente` |
| O deploy lê exatamente as 15 chaves abaixo, com o prefixo `tx02v2/lab/`, confere os valores fixos e monta o `azure-pg-ca` com as três raízes do contrato (thumbprints SHA-1 conferidos) | check `contract-app` (sobre `scripts/deploy-azure.sh`) | `verificado localmente` |
| Formatos dos valores da App Configuration (imagens no ACR, ID e frontend do AGC, ID da política de WAF ou `none`, CIDRs das subnets) | `k8s_validate_params` em `scripts/lib/k8s.sh` e `scripts/deploy-azure.sh` | `verificado localmente` |
| Valores fixos (`resource-group`, `cluster-name`, nomes dos segredos, ClusterSecretStore) iguais aos da App Configuration; preflight de API groups e RBAC no cluster | `scripts/deploy-azure.sh` falha antes de construir ou aplicar qualquer coisa | `não executado em nuvem (v2)` |
| Comportamento real na Azure | `docs/RUNBOOK.md` | `não executado em nuvem (v2)` |

## Identificadores

| Item | Valor |
|---|---|
| Região Azure | variável Terraform `location` do tx02v2, padrão `eastus2` (chave `location` abaixo) |
| Projeto / ambiente / prefixo | `tx02v2` / `lab` / `tx02v2-lab` |
| Grupos de recursos | `tx02v2-lab` (recursos do lab; o deploy confere a chave `resource-group`) |
| Sufixo dos nomes globais | `substr(sha1(<subscription_id>), 0, 8)` (nos exemplos deste repositório: `00000000`) |
| Cluster AKS | `tx02v2-lab`, Kubernetes `1.36`, contas locais desligadas, Entra ID com Azure RBAC, OIDC issuer e workload identity, Azure CNI Overlay com dataplane Cilium (aplica NetworkPolicy) |
| Namespace do app | `dx02v2` — criado pela camada de plataforma do tx02v2 com os labels `pod-security.kubernetes.io/enforce=restricted` e `pod-security.kubernetes.io/enforce-version=latest`. Os overlays `azure*` não criam o namespace; o overlay `local` cria um equivalente para o kind |
| RBAC Kubernetes do deployer | Role `dx02v2-deployer` + RoleBinding `dx02v2-deployers` no namespace `dx02v2`; sujeito `kind: User` com o object ID da identidade `dx02v2-gha-deploy` (mais os object IDs de `app_deployer_principal_ids`) |
| Traces (OpenTelemetry) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP; `OTEL_EXPORTER_OTLP_ENDPOINT` do componente `azure`). O Collector é instalado pela camada de plataforma do tx02v2 e grava os spans no Application Insights `tx02v2-lab-traces` com a identidade `tx02v2-lab-otel`; o app não recebe nenhum papel Azure para isso |
| ACR | `tx02v2lab<sufixo>`, Basic, usuário admin e pull anônimo desligados; repositórios `dx02v2/api` e `dx02v2/web`; tag = SHA git completo (40 caracteres) do dx02v2. O Basic não tem imutabilidade de tags: o deploy recusa sobrescrever uma tag existente |
| Identidade OIDC do deploy | `dx02v2-gha-deploy` (user-assigned, no grupo `tx02v2-bootstrap`) |

Regras da Role `dx02v2-deployer` (namespace `dx02v2`), que limitam o que os overlays `azure*` podem
conter (o check `contract-app` recusa qualquer outro tipo):

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch
- core: services, configmaps, serviceaccounts → get, list, watch, create, update, patch, delete;
  pods, pods/log, events, endpoints → get, list, watch; secrets → get, list, watch (o ESO escreve
  os segredos; o deployer nunca os escreve)
- `networking.k8s.io`: networkpolicies → CRUD completo
- `gateway.networking.k8s.io`: gateways, httproutes → CRUD completo
- `alb.networking.azure.io`: `healthcheckpolicy`, `webapplicationfirewallpolicy` → CRUD completo
  (são os `spec.names.plural` dos CRDs do ALB Controller 1.12.2, iguais ao singular; uma regra RBAC
  com `healthcheckpolicies`/`webapplicationfirewallpolicies` não casaria com nada)
- `autoscaling`: horizontalpodautoscalers → CRUD completo; `policy`: poddisruptionbudgets → CRUD completo
- `external-secrets.io`: externalsecrets → CRUD completo

## OIDC do GitHub

Credencial federada da identidade `dx02v2-gha-deploy`: issuer `https://token.actions.githubusercontent.com`,
audience `api://AzureADTokenExchange`, sujeito exato `repo:<owner>/dx02v2:environment:lab` (dono
configurável no tx02v2, `github_owner`, sem padrão). Por isso o job do `deploy-azure.yml` usa
`environment: lab` (o check `policy-workflows` exige).

Papéis Azure de `dx02v2-gha-deploy` (atribuídos pelo root do lab do tx02v2): `AcrPush` no registry;
`Azure Kubernetes Service Cluster User Role` no cluster (para obter o kubeconfig);
`App Configuration Data Reader` no store do contrato. Nada no Key Vault. Acesso Kubernetes só pela
RoleBinding acima.

## App Configuration `tx02v2-lab-<sufixo>` (Free, autenticação local desligada, chaves sem label, prefixo `tx02v2/lab/`)

O endpoint do store é um output do tx02v2 e vira a variável `AZURE_APPCONFIG_ENDPOINT` do GitHub
neste repositório.

| Chave | Valor | Uso no dx02v2 |
|---|---|---|
| `location` | região Azure | conferida (formato) |
| `resource-group` | `tx02v2-lab` | conferida; `az aks get-credentials` |
| `cluster-name` | `tx02v2-lab` | conferida; `az aks get-credentials` |
| `vnet-cidr` | CIDR da VNet | conferida (formato) |
| `agc-subnet-cidr` | subnet delegada ao Application Gateway for Containers (o tráfego AGC → pods sai dela) | NetworkPolicies `web-ingress-from-agc` e `api-ingress-from-agc` (`AGC_SUBNET_CIDR`, precisa ser /24) |
| `postgres-subnet-cidr` | subnet delegada ao PostgreSQL Flexible Server | NetworkPolicy `api-egress-to-postgres-subnet` (`POSTGRES_SUBNET_CIDR`) |
| `acr/login-server` | `<nome do acr>.azurecr.io` | imagens `dx02v2/api` e `dx02v2/web` (`API_IMAGE`, `WEB_IMAGE`) |
| `keyvault/uri` | URI do Key Vault | conferida (formato; o ESO do tx02v2 usa o vault) |
| `db/secret-name` | `tx02v2-lab-db-app` | conferida contra o ExternalSecret `db-credentials` |
| `app/admin-token-secret-name` | `tx02v2-lab-app-admin-token` | conferida contra o ExternalSecret `app-secrets` |
| `eso/cluster-secret-store` | `azure-key-vault` | conferida contra o `secretStoreRef` dos ExternalSecrets |
| `agc/id` | resource ID do Application Gateway for Containers | anotação `alb.networking.azure.io/alb-id` do Gateway (`AGC_ID`); a assinatura do ID precisa ser a do `az` logado |
| `agc/frontend-name` | nome do frontend | `spec.addresses` do Gateway, tipo `alb.networking.azure.io/alb-frontend` (`AGC_FRONTEND`; ver a nota 1) |
| `waf/policy-id` | resource ID da política de WAF, ou o literal `none` quando o tx02v2 roda com `enable_waf = false` | WebApplicationFirewallPolicy `dx02v2` (`WAF_POLICY_ID`, overlay `azure-waf`); com `none`, overlay `azure` e a política antiga é apagada |
| `deploy/principal-id` | object ID de `dx02v2-gha-deploy` | conferida (formato) |

## Key Vault `tx02v2-lab-<sufixo>` (autorização RBAC; valores nunca no state/plan)

- `tx02v2-lab-db-app`: JSON com valores string `username`, `password`, `host`, `port`, `dbname`.
- `tx02v2-lab-app-admin-token`: string pura, 48 caracteres alfanuméricos aleatórios.
- A identidade do ESO `tx02v2-lab-eso` tem `Key Vault Secrets User` só neste vault; o deployer não
  lê o Key Vault.

## Camada de plataforma (instalada pelo `platform/install.sh` do tx02v2)

- ALB Controller (Application Gateway for Containers) no namespace `azure-alb-system`, GatewayClass
  `azure-alb-external`. Os schemas de `deploy/k8s/schemas` vêm do ALB Controller 1.12.2: mantenha a
  mesma versão do tx02v2 (`docs/SUSTENTACAO.md`).
- External Secrets Operator no namespace `external-secrets`; ClusterSecretStore `azure-key-vault`
  (provider `azurekv`, `authType: WorkloadIdentity`), utilizável só a partir do namespace `dx02v2`.
- Namespace `dx02v2`, Role e RoleBinding acima. O metrics-server do AKS atende o HPA da API.

## Runtime do app (dx02v2)

- Secret `db-credentials`: chaves `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  (Azure: ExternalSecret de `tx02v2-lab-db-app`, uma propriedade JSON por chave; kind e compose:
  gerado em tempo de execução com valores aleatórios por `scripts/e2e-kind.sh` e `scripts/dev-env.sh`).
- Secret `app-secrets`: chave `ADMIN_TOKEN` (Azure: ExternalSecret de `tx02v2-lab-app-admin-token`).
- TLS do banco na Azure: `DB_SSL_MODE=verify-full`, `DB_SSL_CA_FILE=/etc/azure-pg-ca/ca.pem` a partir
  do ConfigMap `azure-pg-ca`, criado pelo deploy. O bundle é a concatenação PEM de três raízes (o
  documento de TLS do Azure Database for PostgreSQL exige pelo menos as duas primeiras e recomenda
  todas as raízes da Azure). O deploy baixa cada uma em DER, confere o thumbprint SHA-1 e **recusa**
  um arquivo diferente; os SHA-256 abaixo foram calculados em 2026-10-11 a partir dos downloads:

  | Raiz | URL (DER) | SHA-1 (contrato) | SHA-256 (calculado) | Validade |
  |---|---|---|---|---|
  | DigiCert Global Root G2 | `https://cacerts.digicert.com/DigiCertGlobalRootG2.crt` | `DF3C24F9BFD666761B268073FE06D1CC8D4F82A4` | `CB3CCBB76031E5E0138F8DD39A23F9DE47FFC35E43C1144CEA27D46A5AB1CB5F` | 2038-01-15 |
  | Microsoft RSA Root Certificate Authority 2017 | `https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt` | `73A5E64A3BFF8316FF0EDCCC618A906E4EAE4D74` | `C741F70F4B2A8D88BF2E71C14122EF53EF10EBA0CFA5E64CFA20F418853073E0` | 2042-07-18 |
  | Microsoft ECC Root Certificate Authority 2017 | `https://www.microsoft.com/pkiops/certs/Microsoft%20ECC%20Root%20Certificate%20Authority%202017.crt` | `999A64C37FF47D9FAB95F14769891460EEC4C3C5` | `358DF39D764AF9E1B766E9C972DF352EE15CFAC227AF6AD1D70E8E4A6EDCBA02` | 2042-07-18 |

  Local: `DB_SSL_MODE=disable`. Com `APP_ENV=lab` a API recusa qualquer modo diferente de `verify-full`.
- Services: `api` (porta 3000 http, 9464 métricas), `web` (porta 8080).
- Tráfego (só Azure): Gateway `dx02v2` (classe `azure-alb-external`, anotação
  `alb.networking.azure.io/alb-id` = `agc/id`, frontend `agc/frontend-name`), listener HTTP na porta
  80 (HTTPS `planejado`); HTTPRoute `dx02v2`: `/api` → `api:3000`, `/` → `web:8080`;
  HealthCheckPolicies `web` (`/healthz`) e `api` (`/readyz`); WebApplicationFirewallPolicy `dx02v2`
  apontando para o Gateway com `waf/policy-id` (omitida com `none`).
- Política de WAF (do tx02v2): modo Prevention, regras gerenciadas DRS 2.1 + Bot Manager 1.1, inspeção
  do corpo ligada com limite de 128 KB — então corpos grandes chegam à API, que responde 413 ela
  mesma (o smoke manda 70 KB; ver a nota 3). Nenhuma regra personalizada pode bloquear o smoke test;
  um limite de taxa, se existir, precisa ser >= 300 requisições por minuto por cliente.
- NetworkPolicies na Azure: entrada em web:8080 e api:3000 só a partir de `agc-subnet-cidr`; saída da
  api para `postgres-subnet-cidr`:5432; DNS (base).
- PostgreSQL Flexible Server 17, porta 5432, só acesso privado (subnet delegada + zona DNS privada),
  `require_secure_transport = on`, TLS >= 1.2.

## Notas da implementação (2026-10-11, incorporadas ao contrato v1)

Encontradas ao implementar o lado do app contra a documentação oficial e os CRDs do ALB Controller
1.12.2. Todas foram incorporadas ao `docs/CONTRATO.md` do tx02v2 antes da primeira publicação dele,
então o contrato continua na versão 1; ficam aqui como registro de por que o texto é assim.

1. **Frontend do AGC.** O contrato fala em anotação `alb.networking.azure.io/alb-frontend` no Gateway;
   essa anotação é da Ingress API. Na Gateway API (modo "bring your own"), os guias oficiais usam a
   anotação `alb.networking.azure.io/alb-id` e `spec.addresses` com o tipo
   `alb.networking.azure.io/alb-frontend` — é o que este repositório implementa.
2. **Nomes dos recursos para RBAC.** Os CRDs do ALB Controller 1.12.2 declaram os plurais
   `healthcheckpolicy` e `webapplicationfirewallpolicy` (iguais ao singular). Uma regra RBAC com
   `healthcheckpolicies`/`webapplicationfirewallpolicies` não casa com eles; o preflight do deploy
   (`kubectl auth can-i create healthcheckpolicy.alb.networking.azure.io`) acusaria a falta.
3. **Tamanho do corpo do smoke.** O contrato diz que o smoke manda ~12 KB; ele manda 70 KB (abaixo dos
   128 KB do WAF, acima dos 10 kb da API), então a conclusão (413 da própria API) se mantém.
4. **Lacunas (agora no contrato do tx02v2).** `host` em `tx02v2-lab-db-app` é o FQDN do servidor (o
   `verify-full` confere o nome); a identidade kubelet do AKS tem `AcrPull` no registry; os nós são
   x86-64 (as imagens são `linux/amd64`); a subnet do AGC com Azure CNI Overlay é exatamente /24 (o
   deploy recusa outro prefixo); e cada principal de `app_deployer_principal_ids` (deploy a partir de
   um laptop) recebe os mesmos papéis Azure da `dx02v2-gha-deploy` (AcrPush, Azure Kubernetes Service
   Cluster User Role e App Configuration Data Reader) além da RoleBinding.

## Lab local (contrato local do tx02v2, versão 2)

O deploy local (scripts/deploy-local.sh, docs/LAB_LOCAL.md) lê o ConfigMap `lab-system/lab-contract`
da plataforma local do tx02v2, exige a versão `2` e recusa valores diferentes dos fixados no overlay
`local-platform`:
`registry` = `registry.tx02v2.local`, `db.secret-name` = `tx02v2-lab-db-app`,
`app.admin-token-secret-name` = `tx02v2-lab-app-admin-token` (chave `token`; no Key Vault é uma string
pura), `eso.cluster-secret-store` = `local-secrets`, `gateway.class` = `istio`, `tls.cluster-issuer` =
`lab-ca`, `argocd.project` = `dx02v2`, `monitoring.prometheus-service-account` =
`monitoring/kube-prometheus-stack-prometheus`, `tracing.otlp-endpoint` =
`http://opentelemetry-collector.monitoring.svc:4318` (versão 2: o `OTEL_EXPORTER_OTLP_ENDPOINT` da API
e as NetworkPolicies até o Collector). Do contrato ele lê ainda `registry-push`
(`localhost:5002`), `network-cidr` (`10.251.0.0/24`), `db.endpoint-ip` (`10.251.0.11`),
`db.ca-configmap`, `gitops.push-url`, `gitops.read-url` e `gitops.push-key-secret`. O overlay só usa os
kinds que o AppProject `dx02v2` aceita (check `contract-app`). Diferença de borda: o Gateway local
mantém um `X-Request-Id` externo (`SMOKE_EDGE=istio`); o AGC gera o próprio. A fonte da verdade é o
`docs/CONTRATO.md` do tx02v2.

## Mudando o contrato

1. Abra PRs nos dois repositórios, com links cruzados, e incremente a versão no título dos dois
   arquivos `docs/CONTRATO.md`.
2. Atualize os checks que cobrem o item (tabela "Como o contrato é verificado aqui"):
   `scripts/check-manifests.mjs`, `scripts/deploy-azure.sh`, `scripts/lib/k8s.sh`, `scripts/harness.sh`.
3. Faça o merge do lado que publica (tx02v2) antes do lado que consome (este), salvo remoções
   (ao contrário).
