'use strict';

// The contract every backup destination implements.
//
// Backups start out local, but the reason this indirection exists is that they
// are not meant to stay there: a copy on the same disk as the original protects
// against corruption and mistakes, not against losing the machine. Adding S3,
// WebDAV or a mounted remote should mean writing one file next to
// `local_destination.js` and registering it — no change to the service, the
// scheduler, the admin surface, or the restore path.
//
// Artifacts arrive already encrypted with the installation key, so a
// destination never sees plaintext and never needs credentials for anything
// beyond its own transport. Keys are opaque strings the destination itself
// chooses and is later handed back verbatim.
//
// @typedef {Object} BackupDestination
// @property {string} name             Registry name, as configured.
// @property {() => Promise<string>} describe
//           One human-readable line naming where artifacts land. Shown in the
//           admin dashboard so an operator can confirm the target without
//           reading configuration.
// @property {(source: string, key: string) => Promise<{key: string, bytes: number}>} store
//           Uploads/copies the encrypted artifact at local path `source`.
// @property {() => Promise<Array<{key: string, bytes: number, createdAt: string}>>} list
//           Newest first. Drives retention and the admin history view.
// @property {(key: string) => Promise<void>} remove
// @property {(key: string, destination: string) => Promise<void>} fetch
//           Retrieves an artifact to a local path so it can be decrypted and
//           restored. Required — a destination that cannot be read back is not
//           a backup.

// Names an artifact: sortable by name, and safe on every filesystem and object
// store — no colons, no timezone offsets, no spaces.
//
// The random suffix is not decoration. Timestamps alone collide at one-second
// resolution, and a collision here is silent data loss: the second run
// overwrites the first, and retention then counts one artifact where the
// operator believes there are two.
function artifactKey(now, suffix = require('node:crypto').randomBytes(3).toString('hex')) {
  const stamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  return `neorecall-${stamp}-${suffix}.nrbak`;
}

module.exports = { artifactKey };
