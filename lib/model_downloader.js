'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { ensureRuntimeDirs } = require('../runtime/paths');

const manifest = require('../models/manifest.json');

async function fileSha256(filename) {
  const hash = crypto.createHash('sha256');
  await pipeline(fs.createReadStream(filename), async function* (source) { for await (const chunk of source) { hash.update(chunk); yield chunk; } }, new (require('node:stream').Writable)({ write(_chunk, _encoding, callback) { callback(); } }));
  return hash.digest('hex');
}

async function downloadFile(file, onProgress = () => {}) {
  const destination = path.join(ensureRuntimeDirs().models, file.path);
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  if (fs.existsSync(destination) && fs.statSync(destination).size === file.size && await fileSha256(destination) === file.sha256) return { path: destination, cached: true };
  const partial = `${destination}.partial`;
  let offset = fs.existsSync(partial) ? fs.statSync(partial).size : 0;
  if (offset > file.size) { fs.unlinkSync(partial); offset = 0; }
  const response = await fetch(file.url, { headers: offset ? { Range: `bytes=${offset}-` } : {} });
  if (!response.ok || (offset && response.status !== 206)) {
    if (offset) { fs.unlinkSync(partial); return downloadFile(file, onProgress); }
    throw new Error(`Model download failed with HTTP ${response.status}: ${file.url}`);
  }
  let received = offset;
  const progress = new (require('node:stream').Transform)({ transform(chunk, _encoding, callback) { received += chunk.length; onProgress({ file: file.path, received, total: file.size }); callback(null, chunk); } });
  await pipeline(Readable.fromWeb(response.body), progress, fs.createWriteStream(partial, { flags: offset ? 'a' : 'w', mode: 0o600 }));
  if (fs.statSync(partial).size !== file.size) throw new Error(`Downloaded size for ${file.path} is incorrect.`);
  const digest = await fileSha256(partial);
  if (digest !== file.sha256) { fs.unlinkSync(partial); throw new Error(`SHA-256 verification failed for ${file.path}.`); }
  fs.renameSync(partial, destination);
  return { path: destination, cached: false };
}

async function validFile(filename, file) {
  return fs.existsSync(filename)
    && fs.statSync(filename).size === file.size
    && await fileSha256(filename) === file.sha256;
}

async function installArchive(model, onProgress) {
  const runtime = ensureRuntimeDirs();
  const ready = [];
  for (const file of model.files) {
    if (await validFile(path.join(runtime.models, file.path), file)) ready.push(file.path);
  }
  if (ready.length === model.files.length) {
    return model.files.map((file) => ({ path: path.join(runtime.models, file.path), cached: true }));
  }

  const archiveFile = {
    ...model.archive,
    path: path.join('.downloads', model.archive.filename),
  };
  const downloaded = await downloadFile(archiveFile, onProgress);
  const extractionRoot = path.join(runtime.models, `.extract-${model.id}-${process.pid}`);
  fs.rmSync(extractionRoot, { recursive: true, force: true });
  fs.mkdirSync(extractionRoot, { recursive: true, mode: 0o700 });

  try {
    const args = ['-xjf', downloaded.path, '-C', extractionRoot];
    if (model.archive.stripComponents) args.push(`--strip-components=${model.archive.stripComponents}`);
    const extracted = spawnSync('tar', args, { encoding: 'utf8' });
    if (extracted.status !== 0) {
      throw new Error(`Unable to extract ${model.archive.filename}: ${extracted.stderr || extracted.stdout || 'tar failed'}`);
    }

    for (const file of model.files) {
      const source = path.join(extractionRoot, file.archivePath || path.basename(file.path));
      if (!(await validFile(source, file))) {
        throw new Error(`Extracted model file failed verification: ${file.archivePath || file.path}`);
      }
    }

    for (const file of model.files) {
      const source = path.join(extractionRoot, file.archivePath || path.basename(file.path));
      const destination = path.join(runtime.models, file.path);
      const installing = `${destination}.installing`;
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.rmSync(installing, { force: true });
      fs.copyFileSync(source, installing);
      fs.chmodSync(installing, 0o600);
      fs.rmSync(destination, { force: true });
      fs.renameSync(installing, destination);
    }
    fs.rmSync(downloaded.path, { force: true });
    return model.files.map((file) => ({ path: path.join(runtime.models, file.path), cached: false }));
  } finally {
    fs.rmSync(extractionRoot, { recursive: true, force: true });
  }
}

async function installHubModel(model, onProgress) {
  const runtime = ensureRuntimeDirs();
  const cacheDir = path.join(runtime.models, '.hub-cache');
  const { downloadFileToCacheDir } = await import('@huggingface/hub');
  const output = [];

  try {
    for (const file of model.files) {
      const destination = path.join(runtime.models, file.path);
      if (await validFile(destination, file)) {
        output.push({ path: destination, cached: true });
        continue;
      }

      const cached = await downloadFileToCacheDir({
        repo: model.huggingFace.repo,
        revision: model.revision,
        path: file.hubPath,
        cacheDir,
      });
      if (!(await validFile(cached, file))) {
        throw new Error(`Hugging Face model file failed verification: ${file.hubPath}`);
      }

      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      const installing = `${destination}.installing`;
      fs.rmSync(installing, { force: true });
      try {
        fs.linkSync(fs.realpathSync(cached), installing);
      } catch {
        fs.copyFileSync(cached, installing);
      }
      fs.chmodSync(installing, 0o600);
      fs.rmSync(destination, { force: true });
      fs.renameSync(installing, destination);
      onProgress({ file: file.path, received: file.size, total: file.size });
      output.push({ path: destination, cached: false });
    }
    fs.rmSync(cacheDir, { recursive: true, force: true });
    return output;
  } catch (error) {
    throw new Error(`Unable to install ${model.id} through the Hugging Face Hub: ${error.message}`);
  }
}

async function downloadAll(onProgress) {
  const output = [];
  for (const model of manifest.models) {
    if (model.huggingFace) output.push(...await installHubModel(model, onProgress));
    else if (model.archive) output.push(...await installArchive(model, onProgress));
    else for (const file of model.files) output.push(await downloadFile(file, onProgress));
  }
  return output;
}

/// Weights an earlier manifest installed that are no longer part of the set.
/// Without this a model swap leaves its predecessor on disk forever — several
/// gigabytes that nothing loads. Only paths the manifest itself retires are
/// touched, never an arbitrary file found in the directory, and a model the
/// operator deliberately pinned through LLM_MODEL_FILE is left alone.
function pruneRetired() {
  const runtime = ensureRuntimeDirs();
  const pinned = String(process.env.LLM_MODEL_FILE || '').trim();
  const removed = [];
  for (const relative of manifest.retired || []) {
    if (relative === pinned) continue;
    let bytes = 0;
    for (const candidate of [relative, `${relative}.partial`]) {
      const filename = path.resolve(runtime.models, candidate);
      if (path.relative(runtime.models, filename).startsWith('..')) continue;
      if (!fs.existsSync(filename)) continue;
      bytes += fs.statSync(filename).size;
      fs.rmSync(filename, { force: true });
    }
    if (bytes) removed.push({ path: relative, bytes });
  }
  return removed;
}

async function verifyAll() {
  const failures = [];
  for (const model of manifest.models) for (const file of model.files) {
    const filename = path.join(ensureRuntimeDirs().models, file.path);
    if (!fs.existsSync(filename)) failures.push({ path: file.path, reason: 'missing' });
    else if (fs.statSync(filename).size !== file.size) failures.push({ path: file.path, reason: 'size' });
    else if (await fileSha256(filename) !== file.sha256) failures.push({ path: file.path, reason: 'sha256' });
  }
  return failures;
}

module.exports = { manifest, downloadFile, downloadAll, pruneRetired, verifyAll, fileSha256 };
