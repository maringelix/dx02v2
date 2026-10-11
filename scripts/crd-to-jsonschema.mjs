// Converts CustomResourceDefinitions into the JSON schemas kubeconform reads
// (<out>/<group>/<kind>_<version>.json) with the transformation of the openapi2jsonschema script of
// the datreeio CRDs catalog: every nested object that lists properties rejects unknown fields (what
// makes `kubeconform -strict` strict for custom resources; like that script, lists are not
// descended) and the legacy `format: int-or-string` becomes a oneOf. One difference: objects
// marked x-kubernetes-preserve-unknown-fields keep accepting unknown fields. Output: 2-space JSON
// with non-ASCII escaped, like Python's json.dumps. Used by scripts/update-crd-schemas.sh:
//   node scripts/crd-to-jsonschema.mjs <out-dir> <crd.yaml>...
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseAllDocuments } from 'yaml';

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

function rejectUnknownFields(node, isRoot) {
  if (!isObject(node)) {
    return node;
  }
  const out = {};
  for (const [key, value] of Object.entries(node)) {
    out[key] = rejectUnknownFields(value, false);
  }
  if (
    !isRoot &&
    out.properties !== undefined &&
    out.additionalProperties === undefined &&
    out['x-kubernetes-preserve-unknown-fields'] !== true
  ) {
    out.additionalProperties = false;
  }
  return out;
}

function intOrString(node) {
  if (Array.isArray(node)) {
    return node.map(intOrString);
  }
  if (!isObject(node)) {
    return node;
  }
  const out = {};
  for (const [key, value] of Object.entries(node)) {
    out[key] =
      isObject(value) && value.format === 'int-or-string'
        ? { oneOf: [{ type: 'string' }, { type: 'integer' }] }
        : intOrString(value);
  }
  return out;
}

const asciiJson = (value) =>
  JSON.stringify(value, null, 2).replace(
    /[\u0080-\uffff]/g,
    (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`,
  );

function convert(file, outDir) {
  const written = [];
  for (const doc of parseAllDocuments(readFileSync(file, 'utf8'))) {
    if (doc.errors.length > 0) {
      throw new Error(`${file}: ${doc.errors[0].message}`);
    }
    const crd = doc.toJS();
    if (crd?.kind !== 'CustomResourceDefinition') {
      continue;
    }
    const { group, names, versions } = crd.spec;
    for (const version of versions ?? []) {
      const schema = version.schema?.openAPIV3Schema;
      if (schema === undefined) {
        continue;
      }
      const name = `${group}/${names.kind.toLowerCase()}_${version.name}.json`;
      mkdirSync(join(outDir, group), { recursive: true });
      writeFileSync(join(outDir, name), `${asciiJson(intOrString(rejectUnknownFields(schema, true)))}\n`);
      written.push(name);
    }
  }
  if (written.length === 0) {
    throw new Error(`${file}: no CustomResourceDefinition with an openAPIV3Schema`);
  }
  return written;
}

const [outDir, ...files] = process.argv.slice(2);
if (outDir === undefined || files.length === 0) {
  console.error('usage: node scripts/crd-to-jsonschema.mjs <out-dir> <crd.yaml>...');
  process.exit(2);
}
for (const file of files) {
  for (const name of convert(file, outDir)) {
    console.log(name);
  }
}
