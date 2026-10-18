// Structural checks of the rendered Kubernetes manifests against contract v4 (docs/CONTRACT.md)
// and the hardening rules of docs/GUARDRAILS.md. Used by the harness check `contract-app`.
//   node scripts/check-manifests.mjs --params <params.env> --local-params <params.env> local=<file> azure=<file>
//     azure-waf=<file> azure-full=<file> azure-waf-full=<file> local-platform=<file>
import { readFileSync } from 'node:fs';
import { parseAllDocuments } from 'yaml';

const NAMESPACE = 'dx02v2';
// Kinds the deployer Role of tx02v2 may write (docs/CONTRACT.md). Secrets are written by ESO only.
const DEPLOYER_KINDS = new Set([
  'ConfigMap',
  'AuthorizationPolicy',
  'Deployment',
  'DestinationRule',
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
// The only annotation the azure overlays may carry (docs/CONTRACT.md); deploy-params is dropped by kustomize.
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
  let localParams;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--params') {
      params = argv[++i];
    } else if (argv[i] === '--local-params') {
      localParams = argv[++i];
    } else {
      const [name, file] = argv[i].split('=');
      files[name] = file;
    }
  }
  if (params === undefined || Object.keys(files).length === 0) {
    console.error(
      'usage: node scripts/check-manifests.mjs --params <params.env> [--local-params <params.env>] <overlay>=<rendered.yaml>...',
    );
    process.exit(2);
  }
  return {
    params: readParams(params),
    files,
    localParams: localParams === undefined ? undefined : readParams(localParams),
  };
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
  for (const key of ['cost.lab/owner', 'cost.lab/environment']) {
    check(
      typeof workload.spec?.template?.metadata?.labels?.[key] === 'string' &&
        workload.spec.template.metadata.labels[key].length > 0,
      where + ': mandatory showback label ' + key,
    );
  }
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
  const waypointFull = overlay.endsWith('-full') || overlay === 'local-platform';
  const appEgress = find(objs, 'NetworkPolicy', 'web-egress-to-api')?.spec?.egress?.[0];
  if (waypointFull) {
    eq(
      appEgress?.to?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx02v2-waypoint' },
      `${overlay}: web reaches the API through the namespace waypoint`,
    );
    eq(appEgress?.ports, [{ protocol: 'TCP', port: 15008 }], `${overlay}: web egress uses HBONE only`);
    eq(
      find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx02v2-waypoint' },
      `${overlay}: API accepts the waypoint, not direct web traffic`,
    );
  } else {
    eq(appEgress?.ports, [{ protocol: 'TCP', port: 3000 }], `${overlay}: web -> api:3000`);
    eq(
      find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
      { 'app.kubernetes.io/name': 'web' },
      `${overlay}: api accepts web`,
    );
  }
  const metrics = find(objs, 'NetworkPolicy', 'api-metrics-from-monitoring')?.spec?.ingress?.[0];
  if (waypointFull) {
    eq(
      metrics?.from?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx02v2-waypoint' },
      `${overlay}: metrics requests use the waypoint`,
    );
    eq(metrics?.ports, [{ protocol: 'TCP', port: 15008 }], `${overlay}: metrics use HBONE`);
  } else {
    eq(
      metrics?.from?.[0]?.namespaceSelector?.matchLabels,
      { 'kubernetes.io/metadata.name': 'monitoring' },
      `${overlay}: metrics source`,
    );
    eq(metrics?.ports, [{ protocol: 'TCP', port: 9464 }], `${overlay}: metrics port`);
  }
  return { apiSpec, apiContainer, migrate, webContainer };
}

function localChecks({ objs }) {
  const ns = find(objs, 'Namespace', NAMESPACE);
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce'], 'restricted', 'local: PSA enforce');
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce-version'], 'latest', 'local: PSA enforce-version');
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq([config.APP_ENV, config.DB_SSL_MODE, config.TRUST_PROXY_HOPS], ['kind', 'disable', '1'], 'local: app-config');
  eq(config.OTEL_EXPORTER_OTLP_ENDPOINT, undefined, 'local: no trace exporter on kind (no Collector there)');
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
  const full = overlay.endsWith('-full');
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

  // Gateway API on Application Gateway for Containers, bring-your-own deployment (docs/CONTRACT.md).
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
  const httpListener = {
    name: 'http',
    protocol: 'HTTP',
    port: 80,
    ...(full ? { hostname: params.DNS_HOSTNAME } : {}),
    allowedRoutes: { namespaces: { from: 'Same' } },
  };
  const httpsListener = {
    name: 'https',
    protocol: 'HTTPS',
    port: 443,
    hostname: params.DNS_HOSTNAME,
    tls: { mode: 'Terminate', certificateRefs: [{ name: 'dx02v2-tls' }] },
    allowedRoutes: { namespaces: { from: 'Same' } },
  };
  eq(gateway?.spec?.listeners, full ? [httpListener, httpsListener] : [httpListener], `${overlay}: Gateway listeners`);
  eq(
    all(objs, 'HTTPRoute')
      .map((r) => r.metadata?.name)
      .sort(),
    full ? ['dx02v2', 'dx02v2-http-redirect', 'mesh-demo'] : ['dx02v2'],
    `${overlay}: external route and optional mesh exercise route`,
  );
  const route = find(objs, 'HTTPRoute', 'dx02v2')?.spec;
  eq(route?.parentRefs, [{ name: 'dx02v2', sectionName: full ? 'https' : 'http' }], `${overlay}: HTTPRoute parent`);
  eq(route?.hostnames, full ? [params.DNS_HOSTNAME] : undefined, `${overlay}: HTTPRoute hostname`);
  if (full) {
    check(params.DNS_HOSTNAME !== 'disabled', `${overlay}: public DNS hostname is required for HTTPS`);
    const redirect = find(objs, 'HTTPRoute', 'dx02v2-http-redirect')?.spec;
    eq(redirect?.parentRefs, [{ name: 'dx02v2', sectionName: 'http' }], `${overlay}: HTTP redirect parent`);
    eq(redirect?.hostnames, [params.DNS_HOSTNAME], `${overlay}: HTTP redirect hostname`);
    eq(
      redirect?.rules,
      [{ filters: [{ type: 'RequestRedirect', requestRedirect: { scheme: 'https', statusCode: 301 } }] }],
      `${overlay}: HTTP redirects to HTTPS without an app backend`,
    );
  }
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
  // One HealthCheckPolicy per Service of the HTTPRoute (contract: web /healthz, api /readyz).
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
  const acmePolicy = find(objs, 'NetworkPolicy', 'acme-solver-ingress-from-agc')?.spec;
  if (full) {
    eq(
      acmePolicy,
      {
        podSelector: { matchLabels: { 'acme.cert-manager.io/http01-solver': 'true' } },
        policyTypes: ['Ingress'],
        ingress: [
          {
            from: [{ ipBlock: { cidr: params.AGC_SUBNET_CIDR } }],
            ports: [{ protocol: 'TCP', port: 8089 }],
          },
        ],
      },
      `${overlay}: ACME renewals are allowed only from AGC to solver port 8089`,
    );
  } else {
    eq(acmePolicy, undefined, `${overlay}: core has no ACME solver network exception`);
  }
  // Contract v2: traces to the OpenTelemetry Collector of the platform layer, and nowhere else.
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.observability.svc:4318',
    `${overlay}: OTLP endpoint of the contract`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'observability' } },
            podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
          },
        ],
        ports: [{ protocol: 'TCP', port: 4318 }],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (4318) only`,
  );
  if (overlay.endsWith('-full')) meshFullChecks(overlay, { objs }, params.API_IMAGE);
}

function meshFullChecks(overlay, { objs }, approvedApiImage) {
  for (const name of ['mesh-demo', 'mesh-probe', 'mesh-intruder']) {
    eq(
      find(objs, 'ServiceAccount', name)?.automountServiceAccountToken,
      false,
      `${overlay}: ${name} does not receive a service account token`,
    );
  }
  for (const [name, variant] of [
    ['mesh-stable', 'stable'],
    ['mesh-canary', 'canary'],
  ]) {
    const workload = find(objs, 'Deployment', name);
    const spec = workload === undefined ? {} : podChecks(`${overlay}: Deployment/${name}`, workload);
    eq(spec.serviceAccountName, 'mesh-demo', `${overlay}: ${name} service account`);
    eq(spec.containers?.[0]?.image, approvedApiImage, `${overlay}: ${name} uses the approved API image`);
    eq(spec.containers?.[0]?.args, ['dist/mesh-demo.js'], `${overlay}: ${name} runs the mesh exercise server`);
    eq(
      spec.containers?.[0]?.env?.find((entry) => entry.name === 'MESH_VARIANT')?.value,
      variant,
      `${overlay}: ${name} variant`,
    );
  }
  const route = find(objs, 'HTTPRoute', 'mesh-demo')?.spec;
  eq(
    route?.parentRefs?.map((parent) => [parent.group ?? '', parent.kind, parent.name, parent.port]),
    [['', 'Service', 'mesh-demo', 3000]],
    `${overlay}: mesh route attaches to the waypoint-handled service`,
  );
  const weighted = (route?.rules ?? []).find((rule) => rule.name === 'weighted-canary');
  eq(
    weighted?.backendRefs?.map((backend) => [backend.name, backend.port, backend.weight]),
    [
      ['mesh-stable', 3000, 80],
      ['mesh-canary', 3000, 20],
    ],
    `${overlay}: canary traffic split`,
  );
  eq(
    (route?.rules ?? []).find((rule) => rule.name === 'bounded-retries')?.retry,
    { attempts: 2, codes: [500, 502, 503, 504] },
    `${overlay}: bounded retry policy`,
  );
  const outlier = find(objs, 'DestinationRule', 'mesh-canary')?.spec?.trafficPolicy?.outlierDetection;
  eq(
    [outlier?.consecutive5xxErrors, outlier?.maxEjectionPercent],
    [3, 100],
    `${overlay}: repeated canary failures eject the endpoint`,
  );
  const allowed = find(objs, 'AuthorizationPolicy', 'mesh-demo')?.spec;
  eq(allowed?.targetRefs, [{ group: '', kind: 'Service', name: 'mesh-demo' }], `${overlay}: waypoint L7 policy target`);
  check(
    allowed?.rules?.some((rule) =>
      rule.from?.[0]?.source?.principals?.includes('cluster.local/ns/dx02v2/sa/mesh-probe'),
    ),
    `${overlay}: only the mesh-probe identity may use the exercise`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'mesh-demo-require-waypoint')?.spec?.rules?.[0]?.from?.[0]?.source?.principals,
    ['cluster.local/ns/dx02v2/sa/dx02v2-waypoint'],
    `${overlay}: demo backends accept the waypoint identity only`,
  );
  const waypointSelector = { 'gateway.networking.k8s.io/gateway-name': 'dx02v2-waypoint' };
  for (const name of ['mesh-probe-egress', 'mesh-intruder-egress']) {
    eq(
      find(objs, 'NetworkPolicy', name)?.spec?.egress?.[0]?.to?.[0]?.podSelector?.matchLabels,
      waypointSelector,
      `${overlay}: ${name} cannot bypass the waypoint`,
    );
    eq(
      find(objs, 'NetworkPolicy', name)?.spec?.egress?.[0]?.ports,
      [{ protocol: 'TCP', port: 15008 }],
      `${overlay}: ${name} reaches only the waypoint over HBONE`,
    );
  }
  eq(
    find(objs, 'NetworkPolicy', 'mesh-demo-ingress')?.spec?.ingress?.[0],
    { from: [{ podSelector: { matchLabels: waypointSelector } }], ports: [{ protocol: 'TCP', port: 15008 }] },
    `${overlay}: demo backends accept HBONE from the waypoint only`,
  );
}

// Kinds the AppProject dx02v2 of the tx02v2 local lab lets Argo CD sync (local contract,
// platform/local/manifests/argocd-project-dx02v2.yaml of tx02v2).
const APPPROJECT_KINDS = new Set([
  'AuthorizationPolicy',
  'ConfigMap',
  'Deployment',
  'DestinationRule',
  'ExternalSecret',
  'Gateway',
  'HTTPRoute',
  'HorizontalPodAutoscaler',
  'NetworkPolicy',
  'PeerAuthentication',
  'PodDisruptionBudget',
  'PrometheusRule',
  'Service',
  'ServiceAccount',
  'ServiceMonitor',
]);

function localPlatformChecks({ objs }, params) {
  const overlay = 'local-platform';
  for (const o of objs) {
    check(APPPROJECT_KINDS.has(o.kind), `${overlay}: ${o.kind} is outside what the AppProject dx02v2 may sync`);
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  // One proxy hop in front of the API: the Envoy of the Istio Gateway (the load balancer emulator
  // in front of it is a TCP proxy and adds no X-Forwarded-For entry).
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/lab-ca/ca.crt', '1'],
    `${overlay}: app-config`,
  );
  const api = find(objs, 'Deployment', 'api');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'lab-ca', configMap: { name: 'lab-ca' } }], `${overlay}: lab-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'lab-ca', mountPath: '/etc/lab-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts lab-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  eq(
    find(objs, 'Deployment', 'web')?.spec?.template?.spec?.containers?.[0]?.image,
    params.WEB_IMAGE,
    `${overlay}: web image from params`,
  );

  eq(
    all(objs, 'Gateway').map((g) => g.metadata?.name),
    ['dx02v2'],
    `${overlay}: exactly one Gateway`,
  );
  const gw = find(objs, 'Gateway', 'dx02v2');
  eq(gw?.spec?.gatewayClassName, 'istio', `${overlay}: Gateway class`);
  eq(gw?.metadata?.annotations?.['cert-manager.io/cluster-issuer'], 'lab-ca', `${overlay}: Gateway issuer`);
  eq(
    (gw?.spec?.listeners ?? []).map((l) => [l.name, l.protocol, l.port, l.hostname, l.tls?.certificateRefs?.[0]?.name]),
    [
      ['http', 'HTTP', 80, 'dx02v2.tx02v2.local', undefined],
      ['https', 'HTTPS', 443, 'dx02v2.tx02v2.local', 'dx02v2-tls'],
    ],
    `${overlay}: Gateway listeners`,
  );
  const redirect = find(objs, 'HTTPRoute', 'dx02v2-redirect')?.spec;
  eq(redirect?.parentRefs?.[0]?.sectionName, 'http', `${overlay}: redirect on the http listener`);
  eq(
    redirect?.rules?.[0]?.filters?.[0]?.requestRedirect,
    { scheme: 'https', statusCode: 301 },
    `${overlay}: HTTP -> HTTPS redirect`,
  );
  const route = find(objs, 'HTTPRoute', 'dx02v2')?.spec;
  eq(route?.parentRefs?.[0]?.sectionName, 'https', `${overlay}: app routes on the https listener only`);
  eq(
    (route?.rules ?? []).map((r) => [r.matches?.[0]?.path?.value, r.backendRefs?.[0]?.name, r.backendRefs?.[0]?.port]),
    [
      ['/api', 'api', 3000],
      ['/', 'web', 8080],
    ],
    `${overlay}: HTTPRoute rules (the same as on AGC)`,
  );

  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(db?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'local-secrets' }, `${overlay}: db-credentials store`);
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
  eq(app?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'local-secrets' }, `${overlay}: app-secrets store`);
  // Key Vault holds the admin token as a plain string; the local twin keeps it under the key token.
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx02v2-lab-app-admin-token', 'token']],
    `${overlay}: app-secrets mapping`,
  );

  eq(find(objs, 'PeerAuthentication', 'default')?.spec?.mtls?.mode, 'STRICT', `${overlay}: mTLS STRICT`);
  eq(
    find(objs, 'AuthorizationPolicy', 'api-require-waypoint')?.spec?.rules?.[0]?.from?.[0]?.source?.principals,
    ['cluster.local/ns/dx02v2/sa/dx02v2-waypoint'],
    `${overlay}: API accepts the waypoint identity only`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'api-require-waypoint')?.spec?.rules?.[0]?.to?.[0]?.operation?.ports,
    ['3000', '9464'],
    `${overlay}: waypoint may reach API and metrics ports`,
  );
  eq(
    (find(objs, 'AuthorizationPolicy', 'api-require-waypoint')?.spec?.rules ?? []).slice(1),
    [
      {
        from: [{ source: { principals: ['cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus'] } }],
        to: [{ operation: { ports: ['9464'] } }],
      },
    ],
    `${overlay}: the only direct pod-IP exception authenticates Prometheus and restricts it to metrics`,
  );
  const apiPolicy = find(objs, 'AuthorizationPolicy', 'api')?.spec;
  eq(apiPolicy?.targetRefs, [{ group: '', kind: 'Service', name: 'api' }], `${overlay}: API L7 policy target`);
  eq(
    (apiPolicy?.rules ?? []).map((r) => ({
      principals: r.from?.[0]?.source?.principals,
      ports: r.to?.[0]?.operation?.ports,
      paths: r.to?.[0]?.operation?.paths ?? [],
    })),
    [
      {
        principals: ['cluster.local/ns/dx02v2/sa/web', 'cluster.local/ns/dx02v2/sa/dx02v2-istio'],
        ports: ['3000'],
        paths: [],
      },
      {
        principals: ['cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus'],
        ports: ['9464'],
        paths: [],
      },
      {
        principals: ['cluster.local/ns/monitoring/sa/opentelemetry-collector'],
        ports: ['3000'],
        paths: ['/readyz'],
      },
    ],
    `${overlay}: AuthorizationPolicy api`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'web-require-waypoint')?.spec?.rules?.[0]?.from?.[0]?.source?.principals,
    ['cluster.local/ns/dx02v2/sa/dx02v2-waypoint'],
    `${overlay}: web accepts the waypoint identity only`,
  );
  const webPolicy = find(objs, 'AuthorizationPolicy', 'web')?.spec;
  eq(webPolicy?.targetRefs, [{ group: '', kind: 'Service', name: 'web' }], `${overlay}: web L7 policy target`);
  eq(
    (webPolicy?.rules ?? []).map((r) => [r.from?.[0]?.source?.principals, r.to?.[0]?.operation?.ports]),
    [
      [['cluster.local/ns/dx02v2/sa/dx02v2-istio'], ['8080']],
      [['cluster.local/ns/monitoring/sa/opentelemetry-collector'], ['8080']],
    ],
    `${overlay}: AuthorizationPolicy web`,
  );
  eq(
    webPolicy?.rules?.[1]?.to?.[0]?.operation,
    { ports: ['8080'], methods: ['GET'], paths: ['/healthz'] },
    `${overlay}: Collector has only the synthetic web health operation`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-metrics-mesh')?.spec?.ingress,
    [
      {
        from: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'monitoring' } },
            podSelector: { matchLabels: { 'app.kubernetes.io/name': 'prometheus' } },
          },
        ],
        ports: [{ protocol: 'TCP', port: 15008 }],
      },
    ],
    `${overlay}: only Prometheus gets the direct authenticated metrics transport`,
  );

  eq(
    find(objs, 'NetworkPolicy', 'gateway-ingress-from-load-balancer')?.spec?.ingress?.[0]?.from?.[0]?.ipBlock?.cidr,
    params.NETWORK_CIDR,
    `${overlay}: Gateway ingress only from the lab network`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-db')?.spec?.egress?.[0],
    { to: [{ ipBlock: { cidr: params.DB_ENDPOINT_CIDR } }], ports: [{ protocol: 'TCP', port: 5432 }] },
    `${overlay}: api -> database only`,
  );
  // Local contract v2: the OTLP endpoint and the paths of the spans (API and Gateway, both over the mesh).
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.monitoring.svc:4318',
    `${overlay}: OTLP endpoint of the local contract`,
  );
  const collector = {
    namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'monitoring' } },
    podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
  };
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4318 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (OTLP/HTTP over HBONE) only`,
  );
  const gatewayEgress = find(objs, 'NetworkPolicy', 'gateway-egress')?.spec?.egress ?? [];
  eq(gatewayEgress.length, 3, `${overlay}: Gateway has only waypoint, xDS, and telemetry egress`);
  eq(
    gatewayEgress.find(
      (r) => r.to?.[0]?.podSelector?.matchLabels?.['gateway.networking.k8s.io/gateway-name'] === 'dx02v2-waypoint',
    ),
    {
      to: [{ podSelector: { matchLabels: { 'gateway.networking.k8s.io/gateway-name': 'dx02v2-waypoint' } } }],
      ports: [{ protocol: 'TCP', port: 15008 }],
    },
    `${overlay}: Gateway reaches the waypoint over HBONE`,
  );
  eq(
    gatewayEgress.find(
      (r) => r.to?.[0]?.namespaceSelector?.matchLabels?.['kubernetes.io/metadata.name'] === 'istio-system',
    ),
    {
      to: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'istio-system' } },
          podSelector: { matchLabels: { app: 'istiod' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 15012 }],
    },
    `${overlay}: Gateway reaches Istiod for xDS only`,
  );
  // Every Gateway egress rule that names the Collector: exactly one, OTLP/gRPC (4317) over HBONE (15008).
  eq(
    gatewayEgress.filter((r) =>
      (r.to ?? []).some((peer) => JSON.stringify(canonical(peer)) === JSON.stringify(canonical(collector))),
    ),
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4317 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: the Gateway must reach the OpenTelemetry Collector on 4317 over HBONE (its spans) and only there`,
  );
  for (const name of ['api-ingress-mesh', 'web-ingress-mesh']) {
    const rules = find(objs, 'NetworkPolicy', name)?.spec?.ingress ?? [];
    check(
      rules.some((r) => (r.ports ?? []).some((p) => p.port === 15008)),
      `${overlay}: ${name} must allow HBONE (15008)`,
    );
    check(
      rules.some((r) => r.from?.[0]?.ipBlock?.cidr === '169.254.7.127/32'),
      `${overlay}: ${name} must allow the ambient kubelet probes (169.254.7.127/32)`,
    );
  }
  eq(
    find(objs, 'ServiceMonitor', 'api')?.spec?.endpoints?.[0]?.port,
    'metrics',
    `${overlay}: ServiceMonitor scrapes the metrics port`,
  );
  eq(
    (find(objs, 'PrometheusRule', 'dx02v2')?.spec?.groups?.[0]?.rules ?? []).map((r) => r.alert),
    ['Dx02v2ApiDown', 'Dx02v2HighErrorRate', 'Dx02v2HighLatencyP95', 'Dx02v2PodRestarting', 'Dx02v2PodNotReady'],
    `${overlay}: alert rules`,
  );
  eq(
    find(objs, 'ConfigMap', 'dx02v2-dashboard')?.metadata?.labels?.grafana_dashboard,
    '1',
    `${overlay}: dashboard ConfigMap for the Grafana sidecar`,
  );
  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq([hpa?.minReplicas, hpa?.maxReplicas], [2, 4], `${overlay}: HPA`);
  meshFullChecks(overlay, { objs }, params.API_IMAGE);
}

const { params, files, localParams } = parseArgs(process.argv.slice(2));
for (const [overlay, file] of Object.entries(files)) {
  const rendered = load(file);
  commonChecks(overlay, rendered);
  if (overlay === 'local') {
    localChecks(rendered);
  } else if (['azure', 'azure-waf', 'azure-full', 'azure-waf-full'].includes(overlay)) {
    azureChecks(overlay, rendered, params, overlay.startsWith('azure-waf'));
  } else if (overlay === 'local-platform') {
    check(localParams !== undefined, 'local-platform needs --local-params');
    if (localParams !== undefined) {
      localPlatformChecks(rendered, localParams);
    }
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
