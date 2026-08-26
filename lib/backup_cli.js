'use strict';

const fs = require('node:fs');
const path = require('node:path');

/// CLI face of the backup service.
///
/// Restore is deliberately a command rather than a dashboard button. Replacing
/// the database means replacing a file the server holds open; doing that under a
/// running process is how a recoverable situation becomes an unrecoverable one.
/// So the command refuses to touch a live installation, writes the restored copy
/// beside the original, and leaves the final swap to a human who can see both.
function service() {
  require('../runtime/env').loadEnvironment();
  return {
    backups: require('../server/services/backup/backup_service'),
    paths: require('../runtime/paths').paths(),
  };
}

const megabytes = (bytes) => `${(Number(bytes || 0) / 1048576).toFixed(1)} MB`;

async function cmdBackup() {
  const { backups } = service();
  process.stdout.write('Creating an encrypted snapshot…\n');
  const result = await backups.run({ triggerKind: 'manual' });
  if (result.skipped) {
    process.stdout.write('A backup is already running; nothing to do.\n');
    return;
  }
  process.stdout.write(`Wrote ${result.key} (${megabytes(result.bytes)}).\n`);
  if (result.pruned) process.stdout.write(`Pruned ${result.pruned} artifact(s) beyond the retention limit.\n`);
}

async function cmdBackupList() {
  const { backups } = service();
  const status = await backups.status();
  if (status.unreachable) throw new Error(`Destination "${status.destination}" is unreachable: ${status.unreachable}`);
  process.stdout.write(`Destination: ${status.destination} · ${status.location}\n`);
  process.stdout.write(`Schedule: ${status.enabled ? `every ${status.intervalHours}h` : 'disabled'} · keeping ${status.retain}\n`);
  process.stdout.write(`Last successful backup: ${status.lastSuccessAt || 'never'}\n\n`);
  if (!status.artifacts.length) {
    process.stdout.write('No artifacts stored yet. Run "neorecall backup" to create one.\n');
    return;
  }
  for (const artifact of status.artifacts) {
    process.stdout.write(`  ${artifact.key}  ${megabytes(artifact.bytes).padStart(10)}  ${artifact.createdAt}\n`);
  }
}

async function cmdRestore(args) {
  const [key, ...rest] = args;
  if (!key) throw new Error('Usage: neorecall restore <artifact-key> [--output <path>]\nRun "neorecall backup list" to see available artifacts.');
  const { backups, paths } = service();

  if (fs.existsSync(paths.pidFile)) {
    const pid = Number(fs.readFileSync(paths.pidFile, 'utf8').trim());
    let live = false;
    try { process.kill(pid, 0); live = true; } catch (_) { live = false; }
    if (live) throw new Error('NeoRecall is running. Stop it first with "neorecall stop", then restore.');
  }

  const flag = rest.indexOf('--output');
  const output = flag >= 0 && rest[flag + 1]
    ? path.resolve(rest[flag + 1])
    : path.join(path.dirname(paths.database), `restored-${key.replace(/\.nrbak$/, '')}.sqlite3`);
  if (path.resolve(output) === path.resolve(paths.database)) {
    throw new Error('Refusing to write directly over the live database. Restore beside it, verify, then swap the files yourself.');
  }
  if (fs.existsSync(output)) throw new Error(`${output} already exists. Move it aside or pass a different --output.`);

  process.stdout.write(`Decrypting ${key}…\n`);
  const result = await backups.restore(key, output);

  // A restore that produces an unopenable file is worse than no restore, because
  // it is discovered later. Verify before reporting success.
  const database = require('better-sqlite3')(result.path, { readonly: true });
  try {
    const integrity = database.pragma('integrity_check', { simple: true });
    if (integrity !== 'ok') throw new Error(`Restored database failed its integrity check: ${integrity}`);
    const users = database.prepare('SELECT COUNT(*) AS count FROM users').get().count;
    process.stdout.write(`Restored to ${result.path}\n`);
    process.stdout.write(`  integrity: ok · accounts: ${users} · sha256: ${result.checksum.slice(0, 16)}…\n\n`);
  } finally { database.close(); }

  process.stdout.write('To put it into service, with NeoRecall stopped:\n');
  process.stdout.write(`  mv ${paths.database} ${paths.database}.superseded\n`);
  process.stdout.write(`  mv ${result.path} ${paths.database}\n`);
  process.stdout.write('  neorecall start\n');
}

module.exports = { cmdBackup, cmdBackupList, cmdRestore };
