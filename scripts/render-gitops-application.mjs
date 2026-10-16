#!/usr/bin/env node
// Keep live Azure resource IDs in the in-cluster Argo CD Application, never in public Git.
import fs from 'node:fs';

function fail(message) {
  console.error(message);
  process.exit(2);
}

function readEnv(file) {
  const result = Object.create(null);
  for (const [index, raw] of fs.readFileSync(file, 'utf8').split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const split = line.indexOf('=');
    if (split < 1) fail(`${file}:${index + 1}: expected KEY=VALUE`);
    const key = line.slice(0, split);
    const value = line.slice(split + 1);
    if (!/^[A-Z][A-Z0-9_]*$/.test(key) || Object.hasOwn(result, key)) {
      fail(`${file}:${index + 1}: invalid or duplicate key ${key}`);
    }
    if (/[\r\n\t]/.test(value)) fail(`${file}:${index + 1}: ${key} must be a single line`);
    result[key] = value;
  }
  return result;
}

function required(params, key) {
  if (typeof params[key] !== 'string' || params[key] === '') fail(`missing ${key}`);
  return params[key];
}

function image(value, key) {
  const digestSeparator = value.lastIndexOf('@');
  if (digestSeparator > 0 && /^sha256:[0-9a-f]{64}$/.test(value.slice(digestSeparator + 1))) {
    return { name: value.slice(0, digestSeparator), reference: value };
  }
  const colon = value.lastIndexOf(':');
  if (colon <= value.lastIndexOf('/') || !/^[0-9a-f]{40}$/.test(value.slice(colon + 1))) {
    fail(`${key} must end in a full source commit SHA tag or a sha256 digest`);
  }
  return { name: value.slice(0, colon), reference: value };
}

const [cloud, overlay, actualFile, exampleFile] = process.argv.slice(2);
if (cloud !== 'azure' || !['azure', 'azure-waf'].includes(overlay) || !actualFile || !exampleFile) {
  fail('usage: render-gitops-application.mjs azure <azure|azure-waf> <actual params.env> <params.example.env>');
}

const actual = readEnv(actualFile);
const example = readEnv(exampleFile);
const api = image(required(actual, 'API_IMAGE'), 'API_IMAGE');
const web = image(required(actual, 'WEB_IMAGE'), 'WEB_IMAGE');
const apiExample = image(required(example, 'API_IMAGE'), 'example API_IMAGE');
const webExample = image(required(example, 'WEB_IMAGE'), 'example WEB_IMAGE');
if (!api.name.endsWith('/dx02v2/api') || !apiExample.name.endsWith('/dx02v2/api') ||
    !web.name.endsWith('/dx02v2/web') || !webExample.name.endsWith('/dx02v2/web')) {
  fail('runtime and example images must use the dx02v2/api and dx02v2/web repositories');
}
const patches = [];
const addPatch = (kind, name, path, value) => {
  patches.push({ target: { kind, name }, patch: JSON.stringify([{ op: 'replace', path, value }]) });
};

addPatch('Gateway', 'dx02v2', '/metadata/annotations/alb.networking.azure.io~1alb-id', required(actual, 'AGC_ID'));
addPatch('Gateway', 'dx02v2', '/spec/addresses/0/value', required(actual, 'AGC_FRONTEND'));
addPatch(
  'NetworkPolicy',
  'web-ingress-from-agc',
  '/spec/ingress/0/from/0/ipBlock/cidr',
  required(actual, 'AGC_SUBNET_CIDR'),
);
addPatch(
  'NetworkPolicy',
  'api-ingress-from-agc',
  '/spec/ingress/0/from/0/ipBlock/cidr',
  required(actual, 'AGC_SUBNET_CIDR'),
);
addPatch(
  'NetworkPolicy',
  'api-egress-to-postgres-subnet',
  '/spec/egress/0/to/0/ipBlock/cidr',
  required(actual, 'POSTGRES_SUBNET_CIDR'),
);
if (overlay === 'azure-waf') {
  addPatch(
    'WebApplicationFirewallPolicy',
    'dx02v2',
    '/spec/webApplicationFirewall/id',
    required(actual, 'WAF_POLICY_ID'),
  );
}

const document = {
  spec: {
    source: {
      path: `deploy/k8s/overlays/${overlay}`,
      kustomize: {
        images: [`${apiExample.name}=${api.reference}`, `${webExample.name}=${web.reference}`],
        patches,
      },
    },
  },
};
process.stdout.write(`${JSON.stringify(document, null, 2)}\n`);
