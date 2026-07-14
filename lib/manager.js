'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { ensureRuntimeDirs } = require('../runtime/paths');
const models = require('./model_downloader');
const service = require('./service_manager');

async function setup({ skipModels = false } = {}) {
  const runtime = ensureRuntimeDirs();
  require('../server/db/migrate').migrate();
  if (!skipModels) {
    let lastLine = '';
    await models.downloadAll(({ file, received, total }) => {
      const line = `${file}: ${(received / total * 100).toFixed(1)}%`;
      if (line !== lastLine) { process.stdout.write(`\r${line.padEnd(80)}`); lastLine = line; }
    });
    process.stdout.write('\n');
    const failures = await models.verifyAll();
    if (failures.length) throw new Error(`Model verification failed: ${JSON.stringify(failures)}`);
    process.env.NEORECALL_TRANSFORMERS_LOCAL_PATH = runtime.models;
    const embedding = await require('../server/embeddings/embedding_service').embed('NeoRecall model verification', 'passage');
    if (embedding.length !== 384) throw new Error('Embedding model probe did not return 384 dimensions.');
    const provider = require('../server/transcription/provider_registry').getProvider();
    if (!(await provider.ready())) throw new Error('Transcription provider is not ready after model setup.');
    if (provider.getRecognizer) {
      provider.getRecognizer();
      const fixture = path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav');
      if (!fs.existsSync(fixture)) throw new Error('The packaged local inference fixture is missing.');
      const components = require('../server/transcription/audio_decode').decodeAudio(fixture, 'mono');
      const started = Date.now();
      const segments = await provider.transcribe({ filename: fixture, components, channelLayout: 'mono' });
      if (!segments.length) throw new Error('The local speech inference smoke test produced no transcript.');
      const audioSeconds = Math.max(...components.map((component) => component.samples.length / component.sampleRate));
      const realtimeFactor = (Date.now() - started) / 1000 / audioSeconds;
      const stages = require('../server/config').getConfig().diarizationEnabled ? 'ASR, VAD, and diarization' : 'ASR and VAD';
      process.stdout.write(`Local ${stages} smoke test passed at ${realtimeFactor.toFixed(3)} RTF.\n`);
    }
  }
  require('../server/db/database').getDatabase().prepare('SELECT vec_version()').get();
  process.stdout.write(`NeoRecall setup completed in ${runtime.home}.\n`);
}

function install() {
  const runtime = ensureRuntimeDirs();
  if (!fs.existsSync(runtime.envFile)) fs.writeFileSync(runtime.envFile, '# NeoRecall local configuration\n', { mode: 0o600 });
  const installed = service.install();
  process.stdout.write(installed.manager ? `Installed ${installed.manager} user service at ${installed.path}.\n` : 'Service installation is not supported on this platform; use `neorecall start`.\n');
}

function start() {
  const manager = service.start();
  if (manager) { process.stdout.write(`NeoRecall started with ${manager}.\n`); return; }
  const runtime = ensureRuntimeDirs();
  const pidFile = path.join(runtime.data, 'neorecall.pid');
  if (fs.existsSync(pidFile)) {
    const existingPid = Number(fs.readFileSync(pidFile, 'utf8'));
    try { process.kill(existingPid, 0); process.stdout.write(`NeoRecall is already running with process ${existingPid}.\n`); return; } catch (_) { fs.unlinkSync(pidFile); }
  }
  const output = fs.openSync(path.join(runtime.logs, 'neorecall.log'), 'a');
  const error = fs.openSync(path.join(runtime.logs, 'neorecall-error.log'), 'a');
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'index.js')], { detached: true, stdio: ['ignore', output, error], env: { ...process.env, NEORECALL_HOME: runtime.home } });
  child.unref(); fs.writeFileSync(pidFile, String(child.pid), { mode: 0o600 });
  process.stdout.write(`NeoRecall started with process ${child.pid}.\n`);
}

function stop() {
  const manager = service.stop();
  if (manager) { process.stdout.write(`NeoRecall stopped with ${manager}.\n`); return; }
  const pidFile = path.join(ensureRuntimeDirs().data, 'neorecall.pid');
  if (!fs.existsSync(pidFile)) throw new Error('NeoRecall is not running.');
  process.kill(Number(fs.readFileSync(pidFile, 'utf8')), 'SIGTERM'); fs.unlinkSync(pidFile);
}

function status() {
  const result = service.status();
  if (result.status === 0) { process.stdout.write(result.stdout || result.stderr || 'NeoRecall service is running.\n'); return; }
  const pidFile = path.join(ensureRuntimeDirs().data, 'neorecall.pid');
  if (fs.existsSync(pidFile)) {
    const pid = Number(fs.readFileSync(pidFile, 'utf8'));
    try { process.kill(pid, 0); process.stdout.write(`NeoRecall is running with process ${pid}.\n`); return; } catch (_) { fs.unlinkSync(pidFile); }
  }
  process.stdout.write(result.stdout || result.stderr || 'NeoRecall is not running.\n');
  process.exitCode = 1;
}
function logs() { const file = path.join(ensureRuntimeDirs().logs, 'neorecall.log'); process.stdout.write(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : 'No logs yet.\n'); }
function update(channel = 'stable') { const tag = channel === 'beta' ? 'beta' : 'latest'; const result = spawnSync('npm', ['install', '-g', `neorecall@${tag}`], { stdio: 'inherit' }); if (result.status) process.exitCode = result.status; }

async function resetPassword(account, password) {
  if (!account || !password || password.length < 12) throw new Error('Usage: neorecall reset-password <username-or-email> <new-password-of-at-least-12-characters>');
  const db = require('../server/db/database').getDatabase(); require('../server/db/migrate').migrate(db);
  const user = db.prepare('SELECT * FROM users WHERE username=? COLLATE NOCASE OR email=? COLLATE NOCASE').get(account, account);
  if (!user) throw new Error('User not found.');
  const passwordHash = await require('../server/utils/crypto').hashPassword(password);
  db.transaction(() => {
    db.prepare('UPDATE users SET password_hash=? WHERE id=?').run(passwordHash, user.id);
    db.prepare("UPDATE user_sessions SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND revoked_at IS NULL").run(user.id);
  })();
  process.stdout.write(`Password reset and sessions revoked for ${user.username}.\n`);
}

module.exports = { setup, install, start, stop, status, logs, update, resetPassword };
