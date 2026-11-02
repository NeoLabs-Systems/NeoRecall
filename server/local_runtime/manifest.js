'use strict';

const crypto = require('node:crypto');
const path = require('node:path');

const MANIFEST_PATH = path.join(__dirname, '..', '..', 'models', 'local_runtimes.json');
const SHA256 = /^[0-9a-f]{64}$/;
const ARTIFACT_TYPES = Object.freeze(['file', 'tar-archive', 'zip-member']);

// What this process runs on, in the vocabulary of the manifest. Absent from the
// manifest means no runtime is published for it — the caller reports that rather
// than trying.
function platformKey(platform = process.platform, arch = process.arch) {
  return `${platform}-${arch}`;
}

function assertPinned(value, label) {
  if (!SHA256.test(value.sha256 || '')) throw new Error(`${label} needs a SHA-256.`);
  if (!Number.isInteger(value.size) || value.size <= 0) throw new Error(`${label} needs a byte size.`);
  if (typeof value.url !== 'string' || !value.url.startsWith('https://')) throw new Error(`${label} needs an https URL.`);
}

function validateArtifact(artifact, label) {
  if (!ARTIFACT_TYPES.includes(artifact.type)) throw new Error(`${label} has an unknown type: ${artifact.type}.`);
  assertPinned(artifact, label);
  if (artifact.type === 'file' && !artifact.path) throw new Error(`${label} needs a path.`);
  if (artifact.type === 'tar-archive' && !(artifact.filename && artifact.extractTo && artifact.check)) throw new Error(`${label} is incomplete.`);
  if (artifact.type === 'zip-member') {
    if (!(artifact.filename && artifact.member && artifact.path)) throw new Error(`${label} is incomplete.`);
    if (!SHA256.test(artifact.fileSha256 || '') || !Number.isInteger(artifact.fileSize)) throw new Error(`${label} needs the extracted file's size and SHA-256.`);
  }
}

function validate(manifest) {
  if (manifest?.schemaVersion !== 2 || !Array.isArray(manifest.components)) throw new Error('local_runtimes.json has an unsupported shape.');
  const ids = new Set();
  for (const component of manifest.components) {
    if (!component.id || !component.license || !component.kind) throw new Error('A local component needs an id, a kind and a license.');
    if (ids.has(component.id)) throw new Error(`Duplicate local component: ${component.id}.`);
    ids.add(component.id);
    for (const artifact of component.files || []) validateArtifact(artifact, `${component.id}/${artifact.id}`);
    for (const [key, platform] of Object.entries(component.platforms || {})) {
      for (const artifact of platform.artifacts || []) validateArtifact(artifact, `${component.id}/${key}/${artifact.id}`);
    }
  }
  return manifest;
}

function load(manifest = require(MANIFEST_PATH)) {
  return validate(manifest);
}

function component(manifest, id) {
  const found = manifest.components.find((entry) => entry.id === id);
  if (!found) throw new Error(`Unknown local component: ${id}`);
  return found;
}

// Everything to install for a component on a platform: what only this platform
// needs, then what every platform shares.
function artifactsFor(entry, platform) {
  return [...(platform?.artifacts || []), ...(entry.files || [])];
}

// Identifies exactly which bytes a complete installation consists of. An install
// is only considered current when the fingerprint it was verified under equals
// this one, so moving a pin in the manifest makes every existing install
// re-verify and fetch what changed instead of silently running the old build.
function fingerprint(entry, platform) {
  const parts = artifactsFor(entry, platform).map((artifact) => `${artifact.sha256}${artifact.fileSha256 || ''}`);
  return crypto.createHash('sha256').update(parts.join('\n')).digest('hex');
}

// Bytes a first installation downloads, for telling the operator what they are
// agreeing to.
function downloadBytes(entry, platform) {
  return artifactsFor(entry, platform).reduce((sum, artifact) => sum + artifact.size, 0);
}

module.exports = { load, component, platformKey, artifactsFor, fingerprint, downloadBytes, MANIFEST_PATH };
