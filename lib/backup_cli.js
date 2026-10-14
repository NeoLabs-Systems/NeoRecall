'use strict';

const fs = require('node:fs');
const path = require('node:path');
const ui = require('./cli/ui');
const { closeStepList, createStepList } = require('./cli/steps');

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

async function runStep(label, task) {
  const list = createStepList([label]);
  try {
    return await list.run(0, task);
  } finally {
    closeStepList(list);
  }
}

async function cmdBackup() {
  const { backups } = service();
  ui.blank();
  const result = await runStep(
    ['Saving an encrypted copy of your memories', 'Saved an encrypted copy'],
    () => backups.run({ triggerKind: 'manual' }),
  );
  if (result.skipped) {
    ui.item('info', 'A backup is already running; nothing to do.');
    ui.blank();
    return;
  }
  ui.item('ok', ui.paint.bold('Backup saved'), `${result.key} · ${megabytes(result.bytes)}`);
  if (result.pruned) ui.note(`Removed ${result.pruned} older ${result.pruned === 1 ? 'copy' : 'copies'} beyond the number you keep.`);
  ui.blank();
}

async function cmdBackupList() {
  const { backups } = service();
  const status = await backups.status();
  if (status.unreachable) throw new Error(`Destination "${status.destination}" is unreachable: ${status.unreachable}`);
  ui.title('Backups', `${status.destination} · ${status.location}`);
  ui.blank();
  ui.item(status.enabled ? 'ok' : 'pending', 'Schedule', status.enabled
    ? `Every ${status.intervalHours}h, keeping ${status.retain}`
    : `Off, keeping ${status.retain}`, 18);
  ui.item(status.lastSuccessAt ? 'ok' : 'warn', 'Last backup', status.lastSuccessAt || 'Never', 18);
  ui.blank();
  if (!status.artifacts.length) {
    ui.note(`No copies yet. Make one with ${ui.paint.command('neorecall backup')}.`);
    ui.blank();
    return;
  }
  for (const artifact of status.artifacts) {
    ui.print(`  ${artifact.key}  ${ui.paint.muted(`${megabytes(artifact.bytes).padStart(10)}  ${artifact.createdAt}`)}`);
  }
  ui.blank();
  ui.note(`Bring one back with ${ui.paint.command('neorecall restore <key>')}.`);
  ui.blank();
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

  ui.blank();
  const { result, users } = await runStep([`Decrypting ${key}`, `Decrypted ${key}`], async () => {
    const restored = await backups.restore(key, output);
    // A restore that produces an unopenable file is worse than no restore,
    // because it is discovered later. Verify before reporting success.
    const database = require('better-sqlite3-multiple-ciphers')(restored.path, { readonly: true });
    try {
      const integrity = database.pragma('integrity_check', { simple: true });
      if (integrity !== 'ok') throw new Error(`Restored database failed its integrity check: ${integrity}`);
      return { result: restored, users: database.prepare('SELECT COUNT(*) AS count FROM users').get().count };
    } finally { database.close(); }
  });

  ui.item('ok', ui.paint.bold('Restored and checked'), result.path);
  ui.note(`Integrity ok · ${users} ${users === 1 ? 'account' : 'accounts'} · sha256 ${result.checksum.slice(0, 16)}…`);
  ui.section('To put it into service, with NeoRecall stopped:');
  ui.print(`  mv ${paths.database} ${paths.database}.superseded`);
  ui.print(`  mv ${result.path} ${paths.database}`);
  ui.print('  neorecall start');
  ui.blank();
}

module.exports = { cmdBackup, cmdBackupList, cmdRestore };
