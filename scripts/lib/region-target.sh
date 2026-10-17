# shellcheck shell=bash
# The resource group is shared; the runtime, contract store, image registry and secret names differ.
select_region_target() {
  LAB_TARGET="${1:-primary}"
  case "$LAB_TARGET" in
    primary)
      CONTRACT_CLUSTER=tx02v2-lab
      CONTRACT_DB_SECRET=tx02v2-lab-db-app
      CONTRACT_ADMIN_TOKEN_SECRET=tx02v2-lab-app-admin-token
      GITOPS_BRANCH=gitops/azure
      APPCONFIG_ENDPOINT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}\.azconfig\.io/?$'
      ACR_PATTERN='^tx02v2lab[0-9a-f]{8}\.azurecr\.io$'
      KEYVAULT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}\.vault\.azure\.net/?$'
      ;;
    secondary)
      CONTRACT_CLUSTER=tx02v2-lab-dr
      CONTRACT_DB_SECRET=tx02v2-lab-dr-db-app
      CONTRACT_ADMIN_TOKEN_SECRET=tx02v2-lab-dr-app-admin-token
      GITOPS_BRANCH=gitops/azure-dr
      APPCONFIG_ENDPOINT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}-dr\.azconfig\.io/?$'
      ACR_PATTERN='^tx02v2lab[0-9a-f]{8}dr\.azurecr\.io$'
      KEYVAULT_PATTERN='^https://tx02v2-lab-[0-9a-f]{8}-dr\.vault\.azure\.net/?$'
      ;;
    *) die 'LAB_TARGET must be primary or secondary' ;;
  esac
  export CONTRACT_CLUSTER CONTRACT_DB_SECRET CONTRACT_ADMIN_TOKEN_SECRET
  export APPCONFIG_ENDPOINT_PATTERN ACR_PATTERN KEYVAULT_PATTERN
  export LAB_TARGET GITOPS_BRANCH
}
