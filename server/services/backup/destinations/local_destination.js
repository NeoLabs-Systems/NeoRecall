'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { ensureRuntimeDirs, ensurePrivateDirectory } = require('../../../../runtime/paths');

// Writes artifacts to `NEORECALL_HOME/backups`.
//
// The default, and the only one that needs no configuration. It protects
// against database corruption, a bad migration, and accidental deletion — not
// against losing the host, which is what a remote destination is for.
function createLocalDestination() {
  const directory = () => {
    const { backups } = ensureRuntimeDirs();
    ensurePrivateDirectory(backups);
    return backups;
  };
  // Anything not matching this was not written by us; retention must never
  // delete a file an operator parked in the directory by hand.
  const OURS = /^neorecall-\d{8}T\d{6}Z-[0-9a-f]{6}\.nrbak$/;
  const resolve = (key) => {
    if (!OURS.test(key)) throw new Error(`Refusing to act on an unrecognized backup key: ${key}`);
    return path.join(directory(), key);
  };

  return {
    name: 'local',
    async describe() { return directory(); },
    async store(source, key) {
      const target = resolve(key);
      await fs.promises.copyFile(source, target);
      await fs.promises.chmod(target, 0o600);
      return { key, bytes: (await fs.promises.stat(target)).size };
    },
    async list() {
      const root = directory();
      const names = (await fs.promises.readdir(root)).filter((name) => OURS.test(name));
      const entries = await Promise.all(names.map(async (name) => {
        const stats = await fs.promises.stat(path.join(root, name));
        return { key: name, bytes: stats.size, createdAt: stats.mtime.toISOString() };
      }));
      return entries.sort((left, right) => right.key.localeCompare(left.key));
    },
    async remove(key) { await fs.promises.rm(resolve(key), { force: true }); },
    async fetch(key, destination) { await fs.promises.copyFile(resolve(key), destination); },
  };
}

module.exports = { createLocalDestination };
