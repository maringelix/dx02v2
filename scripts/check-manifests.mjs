// Structural checks of the rendered Kubernetes manifests against contract v1 (docs/CONTRATO.md)
// and the hardening rules of docs/GUARDRAILS.md. Used by the harness check `contract-app`.
//   node scripts/check-manifests.mjs --params <params.env> local=<file> azure=<file> azure-waf=<file>
import { readFileSync } from 'node:fs';
import { parseAllDocuments } from 'yaml';

const NAMESPACE = 'dx02v2';
// Kinds the deployer Role of tx02v2 may write (contract v1). Secrets are written by ESO only.
const DEPLOYER_KINDS = new Set([
  'ConfigMap',
  'Deployment',
  'ExternalSecret',
  'Gateway',
  'HTTPRoute',
  'HealthCheckPolicy',
  'HorizontalPodAutoscaler',
  'NetworkPolicy',
  'PodDisruptionBudget',
  'Service',
  'ServiceAccount',
  'WebApplicationFirewallPolicy',
]);
// dx02v2 started as a copy of the AWS app dx01v2: nothing of that path may come back.
const OTHER_CLOUD =
  /(^|[^a-z0-9])(aws|eks|ecr|rds|elbv2|wafv2|tx01v2)([^a-z0-9]|$)|amazonaws|alb\.ingress\.kubernetes\.io/i;
// The only annotation the azure overlays may carry (contract v1); deploy-params is dropped by kustomize.
const AGC_ID_ANNOTATION = 'alb.networking.azure.io/alb-id';

const failures = [];
let assertions = 0;
const check = (ok, message) => {
  assertions++;
  if (!ok) {
    failures.push(message);
  }
};
// Deep equality that ignores object key order (kustomize prints keys alphabetically); array order
// still matters.
const canonical = (value) => {
  if (Array.isArray(value)) {
    return value.map(canonical);
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
};
const eq = (actual, expected, message) =>
  check(
    JSON.stringify(canonical(actual)) === JSON.stringify(canonical(expected)),
    `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );

function parseArgs(argv) {
  const files = {};
  let params;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--params') {
      params = argv[++i];
    } else {
      const [name, file] = argv[i].split('=');
      files[name] = file;
    }
  }
  if (params === undefined || Object.keys(files).length === 0) {
    console.error('usage: node scripts/check-manifests.mjs --params <params.env> <overlay>=<rendered.yaml>...');
    process.exit(2);
  }
  return { params: readParams(params), files };
}

function readParams(file) {
  const out = {};
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line);
    if (match) {
      out[match[1]] = match[2];
    }
  }
  return out;
}

function load(file) {
  const text = readFileSync(file, 'utf8');
  const docs = parseAllDocuments(text);
  for (const doc of docs) {
    if (doc.errors.length > 0) {
      throw new Error(`${file}: ${doc.errors[0].message}`);
    }
  }
  return { text, objs: docs.map((doc) => doc.toJS()).filter((obj) => obj !== null) };
}

const find = (objs, kind, name) => objs.find((o) => o.kind === kind && o.metadata?.name === name);
const all = (objs, kind) => objs.filter((o) => o.kind === kind);

function podChecks(where, workload) {
  const spec = workload.spec?.template?.spec ?? {};
  const pod = spec.securityContext ?? {};
  check(pod.runAsNonRoot === true, `${where}: pod securityContext.runAsNonRoot must be true`);
  check(
    Number.isInteger(pod.runAsUser) && pod.runAsUser > 0,
    `${where}: pod securityContext.runAsUser must be a non-root uid`,
  );
  eq(pod.seccompProfile?.type, 'RuntimeDefault', `${where}: seccompProfile`);
  check(spec.automountServiceAccountToken === false, `${where}: automountServiceAccountToken must be false`);
  for (const key of ['hostNetwork', 'hostPID', 'hostIPC']) {
    check(spec[key] !== true, `${where}: ${key} is forbidden`);
  }
  for (const volume of spec.volumes ?? []) {
    check(volume.hostPath === undefined, `${where}: hostPath volume ${volume.name} is forbidden`);
  }
  for (const c of [...(spec.initContainers ?? []), ...(spec.containers ?? [])]) {
    const sc = c.securityContext ?? {};
    const name = `${where}/${c.name}`;
    check(sc.allowPrivilegeEscalation === false, `${name}: allowPrivilegeEscalation must be false`);
    check(sc.readOnlyRootFilesystem === true, `${name}: readOnlyRootFilesystem must be true`);
    check(sc.privileged !== true, `${name}: privileged is forbidden`);
    check((sc.capabilities?.drop ?? []).includes('ALL'), `${name}: capabilities.drop must include ALL`);
    check((sc.capabilities?.add ?? []).length === 0, `${name}: no capabilities may be added`);
    check(
      c.resources?.requests?.cpu !== undefined && c.resources?.requests?.memory !== undefined,
      `${name}: cpu/memory requests`,
    );
    check(c.resources?.limits?.memory !== undefined, `${name}: memory limit`);
  }
  return spec;
}

function probePath(container, probe) {
  return container?.[probe]?.httpGet?.path;
}

function commonChecks(overlay, { text, objs }) {
  check(
    !OTHER_CLOUD.test(text),
    `${overlay}: rendered manifests mention another cloud (${OTHER_CLOUD.exec(text)?.[0]})`,
  );
  for (const o of objs) {
    if (o.kind !== 'Namespace') {
      eq(o.metadata?.namespace, NAMESPACE, `${overlay}: ${o.kind}/${o.metadata?.name} namespace`);
    }
    check(
      o.kind !== 'Secret',
      `${overlay}: Secret ${o.metadata?.name} must not be in git (created at runtime or by ESO)`,
    );
  }

  const api = find(objs, 'Deployment', 'api');
  const web = find(objs, 'Deployment', 'web');
  check(api !== undefined && web !== undefined, `${overlay}: Deployments api and web`);
  if (api === undefined || web === undefined) {
    return;
  }
  const apiSpec = podChecks(`${overlay}: Deployment/api`, api);
  const webSpec = podChecks(`${overlay}: Deployment/web`, web);
  const apiContainer = apiSpec.containers?.find((c) => c.name === 'api');
  const migrate = apiSpec.initContainers?.find((c) => c.name === 'migrate');
  const webContainer = webSpec.containers?.find((c) => c.name === 'web');

  eq(apiSpec.serviceAccountName, 'api', `${overlay}: api serviceAccountName`);
  eq(webSpec.serviceAccountName, 'web', `${overlay}: web serviceAccountName`);
  eq(migrate?.args, ['dist/migrate.js'], `${overlay}: initContainer migrate args`);
  eq(migrate?.image, apiContainer?.image, `${overlay}: migrate uses the api image`);
  eq(apiContainer?.args, ['dist/server.js'], `${overlay}: api args`);
  eq(
    (apiContainer?.ports ?? []).map((p) => [p.name, p.containerPort]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: api container ports`,
  );
  eq(probePath(apiContainer, 'startupProbe'), '/healthz', `${overlay}: api startupProbe`);
  eq(probePath(apiContainer, 'livenessProbe'), '/healthz', `${overlay}: api livenessProbe`);
  eq(probePath(apiContainer, 'readinessProbe'), '/readyz', `${overlay}: api readinessProbe`);
  eq(probePath(webContainer, 'readinessProbe'), '/healthz', `${overlay}: web readinessProbe`);
  eq(apiContainer?.lifecycle?.preStop?.sleep?.seconds, 5, `${overlay}: api preStop sleep`);
  for (const c of [migrate, apiContainer]) {
    const refs = (c?.envFrom ?? []).map((e) => e.configMapRef?.name ?? `secret:${e.secretRef?.name}`);
    eq(refs, ['app-config', 'secret:db-credentials'], `${overlay}: ${c?.name} envFrom`);
  }
  const adminToken = apiContainer?.env?.find((e) => e.name === 'ADMIN_TOKEN')?.valueFrom?.secretKeyRef;
  eq(
    adminToken && { name: adminToken.name, key: adminToken.key },
    { name: 'app-secrets', key: 'ADMIN_TOKEN' },
    `${overlay}: ADMIN_TOKEN source`,
  );
  eq(webContainer?.ports?.[0]?.containerPort, 8080, `${overlay}: web container port`);

  const apiService = find(objs, 'Service', 'api');
  const webService = find(objs, 'Service', 'web');
  eq(
    (apiService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: Service api ports`,
  );
  eq(
    (webService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [['http', 8080]],
    `${overlay}: Service web ports`,
  );
  for (const name of ['api', 'web']) {
    eq(
      find(objs, 'ServiceAccount', name)?.automountServiceAccountToken,
      false,
      `${overlay}: ServiceAccount ${name} token`,
    );
    eq(find(objs, 'PodDisruptionBudget', name)?.spec?.minAvailable, 1, `${overlay}: PDB ${name} minAvailable`);
  }

  const deny = find(objs, 'NetworkPolicy', 'default-deny-all');
  eq(deny?.spec?.podSelector, {}, `${overlay}: default-deny-all selects every pod`);
  eq(deny?.spec?.policyTypes, ['Ingress', 'Egress'], `${overlay}: default-deny-all policyTypes`);
  check(
    deny?.spec?.ingress === undefined && deny?.spec?.egress === undefined,
    `${overlay}: default-deny-all has no rules`,
  );
  const dns = find(objs, 'NetworkPolicy', 'allow-dns-egress');
  eq(
    dns?.spec?.egress?.[0]?.to?.[0]?.podSelector?.matchLabels,
    { 'k8s-app': 'kube-dns' },
    `${overlay}: DNS egress target`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'web-egress-to-api')?.spec?.egress?.[0]?.ports,
    [{ protocol: 'TCP', port: 3000 }],
    `${overlay}: web -> api:3000`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
    { 'app.kubernetes.io/name': 'web' },
    `${overlay}: api accepts web`,
  );
  const metrics = find(objs, 'NetworkPolicy', 'api-metrics-from-monitoring')?.spec?.ingress?.[0];
  eq(
    metrics?.from?.[0]?.namespaceSelector?.matchLabels,
    { 'kubernetes.io/metadata.name': 'monitoring' },
    `${overlay}: metrics source`,
  );
  eq(metrics?.ports, [{ protocol: 'TCP', port: 9464 }], `${overlay}: metrics port`);
  return { apiSpec, apiContainer, migrate, webContainer };
}

function localChecks({ objs }) {
  const ns = find(objs, 'Namespace', NAMESPACE);
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce'], 'restricted', 'local: PSA enforce');
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce-version'], 'latest', 'local: PSA enforce-version');
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq([config.APP_ENV, config.DB_SSL_MODE, config.TRUST_PROXY_HOPS], ['kind', 'disable', '1'], 'local: app-config');
  const pg = find(objs, 'StatefulSet', 'postgres');
  const spec = pg === undefined ? {} : podChecks('local: StatefulSet/postgres', pg);
  eq(spec.securityContext?.runAsUser, 70, 'local: postgres uid');
  check(
    /^postgres:17-alpine@sha256:[0-9a-f]{64}$/.test(spec.containers?.[0]?.image ?? ''),
    'local: postgres image pinned by digest',
  );
  check(
    (spec.volumes ?? []).every((v) => v.emptyDir !== undefined),
    'local: postgres uses emptyDir volumes only',
  );
  for (const d of ['api', 'web']) {
    const pod = find(objs, 'Deployment', d)?.spec?.template?.spec;
    for (const c of [...(pod?.initContainers ?? []), ...(pod?.containers ?? [])]) {
      eq([c.image, c.imagePullPolicy], [`dx02v2-${d}:e2e`, 'Never'], `local: ${d}/${c.name} image`);
    }
  }
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-postgres')?.spec?.egress?.[0]?.ports,
    [{ protocol: 'TCP', port: 5432 }],
    'local: api -> postgres:5432',
  );
  eq(
    find(objs, 'NetworkPolicy', 'postgres-ingress-from-api')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
    { 'app.kubernetes.io/name': 'api' },
    'local: postgres accepts api only',
  );
}

function azureChecks(overlay, { objs }, params, waf) {
  for (const o of objs) {
    check(DEPLOYER_KINDS.has(o.kind), `${overlay}: ${o.kind} is outside what the dx02v2-deployer Role may write`);
    eq(
      o.metadata?.labels?.['app.kubernetes.io/part-of'],
      'dx02v2',
      `${overlay}: ${o.kind}/${o.metadata?.name} part-of label`,
    );
    const annotations = Object.keys(o.metadata?.annotations ?? {});
    eq(
      annotations,
      o.kind === 'Gateway' ? [AGC_ID_ANNOTATION] : [],
      `${overlay}: ${o.kind}/${o.metadata?.name} annotations (only the AGC ID on the Gateway)`,
    );
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/azure-pg-ca/ca.pem', '1'],
    `${overlay}: app-config`,
  );
  const api = find(objs, 'Deployment', 'api');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'azure-pg-ca', configMap: { name: 'azure-pg-ca' } }], `${overlay}: azure-pg-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'azure-pg-ca', mountPath: '/etc/azure-pg-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts azure-pg-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  eq(
    find(objs, 'Deployment', 'web')?.spec?.template?.spec?.containers?.[0]?.image,
    params.WEB_IMAGE,
    `${overlay}: web image from params`,
  );

  // Gateway API on Application Gateway for Containers, bring-your-own deployment (contract v1).
  const gateways = all(objs, 'Gateway');
  eq(
    gateways.map((g) => g.metadata?.name),
    ['dx02v2'],
    `${overlay}: exactly one Gateway`,
  );
  const gateway = find(objs, 'Gateway', 'dx02v2');
  eq(gateway?.spec?.gatewayClassName, 'azure-alb-external', `${overlay}: GatewayClass`);
  eq(gateway?.metadata?.annotations?.[AGC_ID_ANNOTATION], params.AGC_ID, `${overlay}: AGC ID from params`);
  eq(
    gateway?.spec?.addresses,
    [{ type: 'alb.networking.azure.io/alb-frontend', value: params.AGC_FRONTEND }],
    `${overlay}: AGC frontend from params`,
  );
  eq(
    gateway?.spec?.listeners,
    [{ name: 'http', protocol: 'HTTP', port: 80, allowedRoutes: { namespaces: { from: 'Same' } } }],
    `${overlay}: one HTTP listener on 80 (HTTPS planned)`,
  );
  eq(
    all(objs, 'HTTPRoute').map((r) => r.metadata?.name),
    ['dx02v2'],
    `${overlay}: exactly one HTTPRoute`,
  );
  const route = find(objs, 'HTTPRoute', 'dx02v2')?.spec;
  eq(route?.parentRefs, [{ name: 'dx02v2', sectionName: 'http' }], `${overlay}: HTTPRoute parent`);
  check(route?.hostnames === undefined, `${overlay}: HTTPRoute without hostnames (generated AGC FQDN)`);
  eq(
    (route?.rules ?? []).map((r) => [
      r.matches?.length,
      r.matches?.[0]?.path?.type,
      r.matches?.[0]?.path?.value,
      r.filters,
      r.backendRefs?.map((b) => [b.name, b.port, b.kind ?? 'Service', b.weight]),
    ]),
    [
      [1, 'PathPrefix', '/api', undefined, [['api', 3000, 'Service', undefined]]],
      [1, 'PathPrefix', '/', undefined, [['web', 8080, 'Service', undefined]]],
    ],
    `${overlay}: HTTPRoute rules (/api -> api:3000, / -> web:8080)`,
  );
  // One HealthCheckPolicy per Service of the HTTPRoute (contract v1: web /healthz, api /readyz).
  eq(
    all(objs, 'HealthCheckPolicy')
      .map((p) => p.metadata?.name)
      .sort(),
    ['api', 'web'],
    `${overlay}: HealthCheckPolicies`,
  );
  for (const [name, path] of [
    ['web', '/healthz'],
    ['api', '/readyz'],
  ]) {
    const policy = find(objs, 'HealthCheckPolicy', name)?.spec;
    eq(policy?.targetRef, { group: '', kind: 'Service', name }, `${overlay}: HealthCheckPolicy ${name} target`);
    eq(policy?.default?.http?.path, path, `${overlay}: HealthCheckPolicy ${name} path`);
    eq(
      policy?.default?.http?.match?.statusCodes,
      [{ start: 200, end: 299 }],
      `${overlay}: HealthCheckPolicy ${name} status codes`,
    );
    check(policy?.default?.port === undefined, `${overlay}: HealthCheckPolicy ${name} probes the HTTPRoute port`);
    check(policy?.default?.useTLS !== true, `${overlay}: HealthCheckPolicy ${name} is plain HTTP like the Service`);
    check(policy?.override === undefined, `${overlay}: HealthCheckPolicy ${name} override is not supported by AGC`);
  }
  const wafPolicies = all(objs, 'WebApplicationFirewallPolicy');
  if (waf) {
    eq(
      wafPolicies.map((p) => p.metadata?.name),
      ['dx02v2'],
      `${overlay}: one WebApplicationFirewallPolicy`,
    );
    const policy = wafPolicies[0]?.spec;
    eq(
      policy?.targetRef,
      { group: 'gateway.networking.k8s.io', kind: 'Gateway', name: 'dx02v2' },
      `${overlay}: WAF policy targets the whole Gateway`,
    );
    eq(policy?.webApplicationFirewall, { id: params.WAF_POLICY_ID }, `${overlay}: WAF policy ID from params`);
    check(params.WAF_POLICY_ID !== 'none', `${overlay}: rendered with a WAF policy ID`);
  } else {
    eq(wafPolicies.length, 0, `${overlay}: no WebApplicationFirewallPolicy without the WAF`);
  }

  const store = { kind: 'ClusterSecretStore', name: 'azure-key-vault' };
  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(db?.secretStoreRef, store, `${overlay}: db-credentials store`);
  eq(db?.target, { name: 'db-credentials', creationPolicy: 'Owner' }, `${overlay}: db-credentials target`);
  eq(
    (db?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [
      ['DB_HOST', 'tx02v2-lab-db-app', 'host'],
      ['DB_PORT', 'tx02v2-lab-db-app', 'port'],
      ['DB_NAME', 'tx02v2-lab-db-app', 'dbname'],
      ['DB_USER', 'tx02v2-lab-db-app', 'username'],
      ['DB_PASSWORD', 'tx02v2-lab-db-app', 'password'],
    ],
    `${overlay}: db-credentials mapping`,
  );
  const app = find(objs, 'ExternalSecret', 'app-secrets')?.spec;
  eq(app?.secretStoreRef, store, `${overlay}: app-secrets store`);
  eq(app?.target, { name: 'app-secrets', creationPolicy: 'Owner' }, `${overlay}: app-secrets target`);
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx02v2-lab-app-admin-token', undefined]],
    `${overlay}: app-secrets mapping`,
  );

  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq(
    [
      hpa?.scaleTargetRef?.name,
      hpa?.minReplicas,
      hpa?.maxReplicas,
      hpa?.metrics?.[0]?.resource?.target?.averageUtilization,
    ],
    ['api', 2, 4, 70],
    `${overlay}: HPA`,
  );
  for (const [name, direction, cidr, port] of [
    ['web-ingress-from-agc', 'ingress', params.AGC_SUBNET_CIDR, 8080],
    ['api-ingress-from-agc', 'ingress', params.AGC_SUBNET_CIDR, 3000],
    ['api-egress-to-postgres-subnet', 'egress', params.POSTGRES_SUBNET_CIDR, 5432],
  ]) {
    const spec = find(objs, 'NetworkPolicy', name)?.spec;
    const rules = spec?.[direction] ?? [];
    const peers = direction === 'ingress' ? rules[0]?.from : rules[0]?.to;
    eq(spec?.policyTypes, [direction === 'ingress' ? 'Ingress' : 'Egress'], `${overlay}: NetworkPolicy ${name} type`);
    eq(
      [rules.length, peers, rules[0]?.ports],
      [1, [{ ipBlock: { cidr } }], [{ protocol: 'TCP', port }]],
      `${overlay}: NetworkPolicy ${name} (one CIDR from params, one port, no except)`,
    );
  }
}

const { params, files } = parseArgs(process.argv.slice(2));
for (const [overlay, file] of Object.entries(files)) {
  const rendered = load(file);
  commonChecks(overlay, rendered);
  if (overlay === 'local') {
    localChecks(rendered);
  } else if (overlay === 'azure' || overlay === 'azure-waf') {
    azureChecks(overlay, rendered, params, overlay === 'azure-waf');
  } else {
    failures.push(`unknown overlay ${overlay}`);
  }
}

if (failures.length > 0) {
  console.log(failures.map((f) => `FAIL ${f}`).join('\n'));
  console.log(`${failures.length} of ${assertions} assertions failed`);
  process.exit(1);
}
console.log(
  `SUMMARY: contract and hardening checks: ${assertions} assertions passed (${Object.keys(files).join(', ')})`,
);
