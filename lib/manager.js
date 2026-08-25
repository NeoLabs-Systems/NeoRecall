'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const {
  commandExists: sharedCommandExists,
  withInstallEnv,
  hasBundledWebClient,
  buildBundledWebClientIfPossible: sharedBuildWebClient,
} = require('./install_helpers');
const {
  APP_DIR,
  ENV_FILE,
  FLUTTER_APP_DIR,
  HOME_DIR,
  LOG_DIR,
  PID_FILE,
  PLIST_DST,
  RUNTIME_HOME,
  SERVICE_LABEL,
  SYSTEMD_UNIT,
  WEB_CLIENT_DIR,
  ensureRuntimeDirs,
  paths,
} = require('../runtime/paths');
const {
  loadEnvironment,
  parseEnv,
  readEnvFileRaw,
  removeEnvValue,
  upsertEnvValue,
} = require('../runtime/env');
const {
  choosePreferredBranchForChannel,
  describeReleaseChannelPolicy,
  getReleaseChannelBranch,
  parseReleaseChannel,
  readConfiguredReleaseChannel,
  writeReleaseChannelToEnvFile,
} = require('../runtime/release_channel');
const { createGitHelpers } = require('../runtime/git_helpers');

const APP_NAME = 'NeoRecall';
const GITHUB_REPO = 'NeoLabs-Systems/NeoRecall';
const DEFAULT_PORT = 4500;

loadEnvironment();

function runQuiet(cmd, args, options = {}) {
  return spawnSync(cmd, args, {
    encoding: 'utf8',
    cwd: options.cwd || APP_DIR,
    env: options.env || process.env,
    stdio: options.stdio || ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout,
  });
}

function runOrThrow(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    encoding: 'utf8',
    cwd: options.cwd || APP_DIR,
    env: options.env || process.env,
    stdio: options.stdio || 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} failed with exit code ${result.status}`);
  }
  return result;
}

const {
  latestStableGitTagVersion,
  latestBetaGitTagVersion,
  gitWorkingTreeDirty,
  gitLocalBranchExists,
  gitRemoteBranchExists,
} = createGitHelpers((cmd, args) => runQuiet(cmd, args));

function logInfo(msg) { console.log(`[neorecall] ${msg}`); }
function logOk(msg) { console.log(`[neorecall] ✓ ${msg}`); }
function logWarn(msg) { console.warn(`[neorecall] ! ${msg}`); }
function logErr(msg) { console.error(`[neorecall] ✗ ${msg}`); }
function heading(text) {
  console.log('');
  console.log(`== ${text} ==`);
}
function cliBanner(title = APP_NAME, subtitle = 'private audio memory') {
  console.log('');
  console.log(`${title}`);
  console.log(subtitle);
  console.log('');
}
function cliSection(text) {
  console.log('');
  console.log(`-- ${text}`);
}
function statusLine(ok, label, value, hint = '') {
  const mark = ok ? '✓' : '✗';
  const suffix = hint ? ` (${hint})` : '';
  console.log(`  ${mark} ${label.padEnd(10)} ${value}${suffix}`);
}

function detectPlatform() {
  if (process.platform === 'darwin') return 'macos';
  if (process.platform === 'linux') return 'linux';
  if (process.platform === 'win32') return 'windows';
  return 'other';
}

function commandExists(cmd) {
  return sharedCommandExists((command, args) => runQuiet(command, args), cmd);
}

function launchctlDomain() {
  try { return `gui/${process.getuid()}`; } catch { return null; }
}

function launchctlServiceTarget() {
  const domain = launchctlDomain();
  return domain ? `${domain}/${SERVICE_LABEL}` : SERVICE_LABEL;
}

function loadEnvPort() {
  const env = parseEnv(readEnvFileRaw(ENV_FILE));
  const raw = process.env.NEORECALL_PORT || env.get('NEORECALL_PORT') || String(DEFAULT_PORT);
  const port = Number(raw);
  return Number.isInteger(port) && port > 0 && port <= 65535 ? port : DEFAULT_PORT;
}

function validateEnvKey(key) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(String(key || ''))) {
    throw new Error(`Invalid environment variable name: ${key || '(empty)'}`);
  }
}

function maskEnvValue(key, value) {
  const upper = String(key || '').toUpperCase();
  if (/(PASSWORD|SECRET|TOKEN|KEY|API)/.test(upper) && value) {
    if (String(value).length <= 8) return '********';
    return `${String(value).slice(0, 2)}********${String(value).slice(-2)}`;
  }
  return value;
}

function readInstalledPackageVersion() {
  try {
    return require(path.join(APP_DIR, 'package.json')).version || '0.0.0';
  } catch {
    return '0.0.0';
  }
}

function readGitVersionLabel() {
  const gitVersion = runQuiet('git', ['describe', '--tags', '--always', '--dirty']);
  if (gitVersion.status !== 0) return null;
  return gitVersion.stdout.trim().replace(/^v/, '') || null;
}

function currentInstalledVersionLabel() {
  const pkg = readInstalledPackageVersion();
  const git = readGitVersionLabel();
  if (git && git !== pkg) return `${pkg} (${git})`;
  return pkg;
}

function currentReleaseChannel() {
  return readConfiguredReleaseChannel({ envFile: ENV_FILE });
}

function releaseChannelSummary(channel) {
  return describeReleaseChannelPolicy(parseReleaseChannel(channel) || currentReleaseChannel());
}

function resolvePreferredGitBranch(channel) {
  const normalized = parseReleaseChannel(channel) || currentReleaseChannel();
  const hasMain = gitRemoteBranchExists('main');
  const hasBeta = gitRemoteBranchExists('beta');

  if (normalized === 'stable') {
    if (hasMain) return 'main';
    if (hasBeta) {
      logWarn('Stable channel selected, but origin/main is missing; using origin/beta until a stable branch exists.');
      return 'beta';
    }
    throw new Error('No origin/main or origin/beta branch was found for updates.');
  }

  const preferred = choosePreferredBranchForChannel(normalized, {
    stable: latestStableGitTagVersion(),
    beta: latestBetaGitTagVersion(),
  });

  if (preferred === 'beta') {
    if (hasBeta) return 'beta';
    if (hasMain) return 'main';
  } else {
    if (hasMain) return 'main';
    if (hasBeta) return 'beta';
  }

  throw new Error(`Release channel branch "${preferred}" was not found on origin.`);
}

function ensureGitBranchForReleaseChannel(targetBranch) {
  const branchRes = runQuiet('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
  const currentBranch = branchRes.status === 0 ? branchRes.stdout.trim() : '';
  if (currentBranch === targetBranch) return currentBranch;
  if (!gitRemoteBranchExists(targetBranch)) {
    throw new Error(`Release channel branch "${targetBranch}" was not found on origin.`);
  }
  if (gitWorkingTreeDirty()) {
    throw new Error(`Cannot switch to ${targetBranch} while the git worktree has local changes. Commit or stash them first, then rerun the update.`);
  }
  if (gitLocalBranchExists(targetBranch)) runOrThrow('git', ['checkout', targetBranch]);
  else runOrThrow('git', ['checkout', '-b', targetBranch, '--track', `origin/${targetBranch}`]);
  if (currentBranch) logOk(`Switched git branch ${currentBranch} -> ${targetBranch}`);
  else logOk(`Checked out git branch ${targetBranch}`);
  return targetBranch;
}

function pruneOldRuntimeBackups(backupsDir, keepLatest = 3) {
  if (!fs.existsSync(backupsDir) || keepLatest < 0) return;
  const backupDirs = fs.readdirSync(backupsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith('pre-update-'))
    .map((entry) => {
      const fullPath = path.join(backupsDir, entry.name);
      try {
        return { name: entry.name, fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs };
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .sort((a, b) => (b.mtimeMs - a.mtimeMs) || b.name.localeCompare(a.name));
  for (const backup of backupDirs.slice(keepLatest)) {
    try { fs.rmSync(backup.fullPath, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

function backupRuntimeData() {
  const runtime = ensureRuntimeDirs();
  const backupsDir = runtime.backups;
  const stamp = new Date().toISOString().replace(/:/g, '-').replace(/\.\d{3}Z$/, 'Z');
  const target = path.join(backupsDir, `pre-update-${stamp}`);
  fs.mkdirSync(target, { recursive: true });
  if (fs.existsSync(ENV_FILE)) fs.copyFileSync(ENV_FILE, path.join(target, '.env'));
  if (fs.existsSync(runtime.data)) {
    fs.cpSync(runtime.data, path.join(target, 'data'), { recursive: true, force: false, errorOnExist: false });
  }
  pruneOldRuntimeBackups(backupsDir, 3);
  logOk(`Runtime backup saved at ${target}`);
}

function dependenciesReady() {
  try {
    require.resolve('express', { paths: [APP_DIR] });
    require.resolve('better-sqlite3', { paths: [APP_DIR] });
    return true;
  } catch {
    return false;
  }
}

function installDependencies() {
  heading('Dependencies');
  runOrThrow('npm', ['install', '--omit=dev', '--no-audit', '--no-fund'], {
    env: withInstallEnv(),
  });
  logOk('Dependencies installed');
}

function assertSupportedNodeRuntime() {
  const major = Number(String(process.versions.node || '').split('.')[0]);
  if (!Number.isInteger(major) || major < 20) {
    throw new Error(`NeoRecall requires Node.js 20 or newer. Current runtime is ${process.versions.node || 'unknown'}.`);
  }
  logOk(`Node.js ${process.versions.node}`);
}

function buildBundledWebClientIfPossible({ required = false } = {}) {
  heading('Web Client');
  return sharedBuildWebClient({
    flutterAppDir: FLUTTER_APP_DIR,
    webClientDir: WEB_CLIENT_DIR,
    runCommand: (command, args, options = {}) =>
      runQuiet(command, args, options.stdio ? options : { ...options, stdio: 'inherit' }),
    commandExistsFn: commandExists,
    onMissingSources: () => logWarn('Flutter app sources not found; keeping existing bundled web client'),
    onUsingBundledClient: () => logOk('Using bundled Flutter web client'),
    onMissingFlutter: () => logWarn('Flutter SDK not found; using bundled web client'),
    onBuildSuccess: () => logOk('Bundled Flutter web client updated'),
    onBuildFailed: () => logWarn('Flutter web build failed; keeping existing bundled web client'),
    fail: (message) => { throw new Error(message); },
    required,
  });
}

function xml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function quoteSystemdValue(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function renderLaunchAgent() {
  const runtime = ensureRuntimeDirs();
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xml(process.execPath)}</string>
    <string>${xml(path.join(APP_DIR, 'server', 'index.js'))}</string>
  </array>
  <key>WorkingDirectory</key><string>${xml(APP_DIR)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NEORECALL_HOME</key><string>${xml(runtime.home)}</string>
    <key>NODE_ENV</key><string>production</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${xml(path.join(runtime.logs, 'neorecall.log'))}</string>
  <key>StandardErrorPath</key><string>${xml(path.join(runtime.logs, 'neorecall-error.log'))}</string>
</dict></plist>
`;
}

function renderSystemdUnit() {
  const runtime = ensureRuntimeDirs();
  const serverEntry = path.join(APP_DIR, 'server', 'index.js');
  return `[Unit]
Description=NeoRecall private audio memory
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${quoteSystemdValue(APP_DIR)}
ExecStart=${quoteSystemdValue(process.execPath)} ${quoteSystemdValue(serverEntry)}
Restart=always
RestartSec=2
Environment=NEORECALL_HOME=${runtime.home}
Environment=NODE_ENV=production
EnvironmentFile=-${quoteSystemdValue(ENV_FILE)}
StandardOutput=append:${path.join(runtime.logs, 'neorecall.log')}
StandardError=append:${path.join(runtime.logs, 'neorecall-error.log')}

[Install]
WantedBy=default.target
`;
}

function startFallback() {
  const runtime = ensureRuntimeDirs();
  if (fs.existsSync(PID_FILE)) {
    const existingPid = Number(fs.readFileSync(PID_FILE, 'utf8'));
    if (Number.isFinite(existingPid) && existingPid > 0) {
      try {
        process.kill(existingPid, 0);
        logOk(`NeoRecall is already running with process ${existingPid}`);
        return;
      } catch {
        fs.rmSync(PID_FILE, { force: true });
      }
    }
  }
  const out = fs.openSync(path.join(runtime.logs, 'neorecall.log'), 'a');
  const err = fs.openSync(path.join(runtime.logs, 'neorecall-error.log'), 'a');
  const child = spawn(process.execPath, [path.join(APP_DIR, 'server', 'index.js')], {
    cwd: APP_DIR,
    detached: true,
    stdio: ['ignore', out, err],
    env: { ...process.env, NEORECALL_HOME: runtime.home },
  });
  child.unref();
  fs.writeFileSync(PID_FILE, String(child.pid), { mode: 0o600 });
  logOk(`Started detached process (pid ${child.pid})`);
}

function installMacService() {
  ensureRuntimeDirs();
  fs.mkdirSync(path.dirname(PLIST_DST), { recursive: true });
  fs.writeFileSync(PLIST_DST, renderLaunchAgent(), { mode: 0o600 });
  const domain = launchctlDomain();
  if (domain) {
    runQuiet('launchctl', ['bootout', domain, PLIST_DST]);
    const bootstrap = runQuiet('launchctl', ['bootstrap', domain, PLIST_DST]);
    if (bootstrap.status !== 0) {
      runQuiet('launchctl', ['unload', PLIST_DST]);
      runOrThrow('launchctl', ['load', PLIST_DST]);
    } else {
      runQuiet('launchctl', ['enable', launchctlServiceTarget()]);
      runQuiet('launchctl', ['kickstart', '-k', launchctlServiceTarget()]);
    }
  } else {
    runQuiet('launchctl', ['unload', PLIST_DST]);
    runOrThrow('launchctl', ['load', PLIST_DST]);
  }
  logOk(`launchd service loaded (${SERVICE_LABEL})`);
}

function installLinuxService() {
  ensureRuntimeDirs();
  fs.mkdirSync(path.dirname(SYSTEMD_UNIT), { recursive: true });
  fs.writeFileSync(SYSTEMD_UNIT, renderSystemdUnit(), { mode: 0o600 });
  runOrThrow('systemctl', ['--user', 'daemon-reload']);
  runOrThrow('systemctl', ['--user', 'enable', 'neorecall.service']);
  runOrThrow('systemctl', ['--user', 'start', 'neorecall.service']);
  runOrThrow('systemctl', ['--user', 'is-active', '--quiet', 'neorecall.service']);
  logOk('systemd user service installed and started');
}

function installService() {
  const platform = detectPlatform();
  if (platform === 'macos' && commandExists('launchctl')) {
    installMacService();
    return 'launchd';
  }
  if (platform === 'linux' && commandExists('systemctl')) {
    try {
      installLinuxService();
      return 'systemd';
    } catch (error) {
      logWarn(`systemd setup failed (${error.message}); falling back to detached process`);
    }
  }
  startFallback();
  return 'detached';
}

function isPortOpen(port) {
  return new Promise((resolve) => {
    const net = require('node:net');
    const socket = net.connect({ host: '127.0.0.1', port }, () => {
      socket.end();
      resolve(true);
    });
    socket.on('error', () => resolve(false));
    socket.setTimeout(1000, () => {
      socket.destroy();
      resolve(false);
    });
  });
}

async function waitForServerReady(port, timeoutMs = 30000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (await isPortOpen(port)) {
      try {
        const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(1500) });
        if (response.ok) return true;
      } catch {
        // still booting
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
  throw new Error(`NeoRecall did not become reachable on port ${port}.`);
}

function ensureDefaultEnvFile() {
  ensureRuntimeDirs();
  if (!fs.existsSync(ENV_FILE)) {
    fs.writeFileSync(ENV_FILE, '# NeoRecall local configuration\n', { mode: 0o600 });
  }
  if (!parseEnv(readEnvFileRaw(ENV_FILE)).has('NEORECALL_RELEASE_CHANNEL') && !process.env.NEORECALL_RELEASE_CHANNEL) {
    writeReleaseChannelToEnvFile(currentReleaseChannel(), ENV_FILE);
  }
}

function ensureModelsReady({ skipModels = false } = {}) {
  if (skipModels) {
    logWarn('Skipping model download/verification');
    return;
  }
  heading('Models');
  const models = require('./model_downloader');
  return models.downloadAll(({ file, received, total }) => {
    if (!total) return;
    process.stdout.write(`\r[neorecall] ${file}: ${((received / total) * 100).toFixed(1)}%`.padEnd(80));
  }).then(async () => {
    process.stdout.write('\n');
    const failures = await models.verifyAll();
    if (failures.length) throw new Error(`Model verification failed: ${JSON.stringify(failures)}`);
    for (const { path: retired, bytes } of models.pruneRetired()) {
      logOk(`Removed superseded ${retired} (${(bytes / 1e9).toFixed(1)} GB reclaimed)`);
    }
    const runtime = ensureRuntimeDirs();
    process.env.NEORECALL_TRANSFORMERS_LOCAL_PATH = runtime.models;
    const embedding = await require('../server/embeddings/embedding_service').embed('NeoRecall model verification', 'passage');
    if (embedding.length !== 384) throw new Error('Embedding model probe did not return 384 dimensions.');
    require('../server/db/database').getDatabase().prepare('SELECT vec_version()').get();
    logOk('Search model verified');
  });
}

async function cmdInstall(args = []) {
  cliBanner(`Install ${APP_NAME}`, 'guided bootstrap');
  heading(`Install ${APP_NAME}`);
  ensureDefaultEnvFile();
  assertSupportedNodeRuntime();
  if (!dependenciesReady()) {
    installDependencies();
  }
  else logOk('Runtime dependencies are ready');
  if (!hasBundledWebClient(WEB_CLIENT_DIR)) buildBundledWebClientIfPossible({ required: true });
  else logOk('Bundled web client is ready');
  require('../server/db/migrate').migrate();
  await ensureModelsReady({ skipModels: args.includes('--skip-models') });
  const manager = installService();
  const port = loadEnvPort();
  await waitForServerReady(port);
  logOk(`Running with ${manager} on http://localhost:${port}`);
  logInfo(`Open http://localhost:${port}/app/ for the web client`);
}

async function cmdSetup(args = []) {
  cliBanner(`Setup ${APP_NAME}`, 'runtime preparation');
  heading(`Setup ${APP_NAME}`);
  ensureDefaultEnvFile();
  assertSupportedNodeRuntime();
  const channelArg = args.find((arg) => arg === 'stable' || arg === 'beta')
    || (args.includes('--channel') ? args[args.indexOf('--channel') + 1] : null)
    || args.find((arg) => arg.startsWith('--channel='))?.split('=')[1];
  if (channelArg) {
    const channel = parseReleaseChannel(channelArg);
    if (!channel) throw new Error('Usage: neorecall setup [--channel stable|beta]');
    writeReleaseChannelToEnvFile(channel, ENV_FILE);
    process.env.NEORECALL_RELEASE_CHANNEL = channel;
    logOk(`Release channel set to ${releaseChannelSummary(channel)}`);
  } else {
    logInfo(`Using release channel ${releaseChannelSummary(currentReleaseChannel())}`);
  }
  require('../server/db/migrate').migrate();
  await ensureModelsReady({ skipModels: args.includes('--skip-models') });
  if (!hasBundledWebClient(WEB_CLIENT_DIR)) buildBundledWebClientIfPossible({ required: true });
  else logOk('Bundled web client is ready');
  logOk(`Setup completed in ${RUNTIME_HOME}`);
}

function cmdStart() {
  cliBanner(`Start ${APP_NAME}`, 'boot sequence');
  heading(`Start ${APP_NAME}`);
  ensureDefaultEnvFile();
  if (!hasBundledWebClient(WEB_CLIENT_DIR)) buildBundledWebClientIfPossible({ required: true });
  const platform = detectPlatform();
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    installMacService();
    return;
  }
  if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    runOrThrow('systemctl', ['--user', 'start', 'neorecall.service']);
    runOrThrow('systemctl', ['--user', 'is-active', '--quiet', 'neorecall.service']);
    logOk('systemd start requested');
    return;
  }
  startFallback();
}

function cmdStop() {
  heading(`Stop ${APP_NAME}`);
  const platform = detectPlatform();
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    const domain = launchctlDomain();
    if (domain) {
      runQuiet('launchctl', ['bootout', domain, PLIST_DST]);
      runQuiet('launchctl', ['bootout', launchctlServiceTarget()]);
    }
    runQuiet('launchctl', ['unload', PLIST_DST]);
    logOk('launchd stop requested');
  } else if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    runQuiet('systemctl', ['--user', 'stop', 'neorecall.service']);
    logOk('systemd stop requested');
  } else if (fs.existsSync(PID_FILE)) {
    const pid = Number(fs.readFileSync(PID_FILE, 'utf8').trim());
    if (Number.isFinite(pid) && pid > 0) {
      try {
        process.kill(pid, 'SIGTERM');
        logOk(`Stopped pid ${pid}`);
      } catch {
        logWarn(`pid ${pid} was not running (stale PID file)`);
      }
    }
    fs.rmSync(PID_FILE, { force: true });
  } else {
    logWarn('No running process found');
  }
}

function cmdRestart() {
  heading(`Restart ${APP_NAME}`);
  buildBundledWebClientIfPossible();
  cmdStop();
  cmdStart();
}

async function cmdRebuildWeb() {
  heading('Rebuild Flutter Web Client');
  buildBundledWebClientIfPossible({ required: true });
}

async function cmdStatus({ showBanner = true } = {}) {
  if (showBanner) cliBanner(`${APP_NAME} Status`, 'systems sweep');
  heading(`${APP_NAME} Status`);
  const port = loadEnvPort();
  const running = await isPortOpen(port);
  const releaseChannel = currentReleaseChannel();
  const platform = detectPlatform();
  cliSection('Runtime');
  statusLine(running, 'server', running ? `http://localhost:${port}` : `not reachable on port ${port}`);
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    const svcRes = runQuiet('launchctl', ['list', SERVICE_LABEL]);
    statusLine(svcRes.status === 0 && Boolean(svcRes.stdout.trim()), 'service', svcRes.status === 0 && svcRes.stdout.trim() ? `launchd (${SERVICE_LABEL})` : 'launchd unit not loaded', svcRes.status === 0 ? '' : 'run: neorecall install');
  } else if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    const svcRes = runQuiet('systemctl', ['--user', 'is-active', 'neorecall.service']);
    statusLine(svcRes.status === 0 && svcRes.stdout.trim() === 'active', 'service', svcRes.status === 0 && svcRes.stdout.trim() === 'active' ? 'systemd (neorecall)' : 'systemd unit not active', svcRes.status === 0 ? '' : 'run: neorecall install');
  }
  cliSection('Assets');
  statusLine(fs.existsSync(ENV_FILE), 'config', fs.existsSync(ENV_FILE) ? ENV_FILE : '.env not found', fs.existsSync(ENV_FILE) ? '' : 'run: neorecall setup');
  statusLine(hasBundledWebClient(WEB_CLIENT_DIR), 'web', hasBundledWebClient(WEB_CLIENT_DIR) ? 'bundled Flutter client present' : 'no bundled client', hasBundledWebClient(WEB_CLIENT_DIR) ? '' : 'run: neorecall rebuild-web');
  cliSection('Build');
  console.log(`  install   ${APP_DIR}`);
  console.log(`  version   ${currentInstalledVersionLabel()}`);
  console.log(`  channel   ${releaseChannelSummary(releaseChannel)}`);
}

async function cmdDoctor() {
  cliBanner(`${APP_NAME} Doctor`, 'read-only diagnostics');
  heading(`${APP_NAME} Doctor`);
  const port = loadEnvPort();
  let runtimeWritable = true;
  try { fs.accessSync(RUNTIME_HOME, fs.constants.R_OK | fs.constants.W_OK); } catch { runtimeWritable = false; }
  const checks = [
    { id: 'runtime', ok: runtimeWritable, message: runtimeWritable ? 'Runtime data directory is accessible' : 'Runtime data directory is not writable', action: 'Check permissions for ~/.neorecall' },
    { id: 'config', ok: fs.existsSync(ENV_FILE), message: fs.existsSync(ENV_FILE) ? 'Configuration is present' : 'Configuration is missing', action: 'Run `neorecall setup`' },
    { id: 'deps', ok: dependenciesReady(), message: dependenciesReady() ? 'Runtime dependencies are present' : 'Runtime dependencies are incomplete', action: 'Run `neorecall repair`' },
    { id: 'web', ok: hasBundledWebClient(WEB_CLIENT_DIR), message: hasBundledWebClient(WEB_CLIENT_DIR) ? 'Bundled client is present' : 'Bundled client is missing', action: 'Run `neorecall rebuild-web`' },
    { id: 'server', ok: await isPortOpen(port), message: '', action: 'Run `neorecall start` or `neorecall repair`' },
  ];
  checks.find((check) => check.id === 'server').message = checks.find((check) => check.id === 'server').ok
    ? `NeoRecall is reachable on port ${port}`
    : `NeoRecall is not reachable on port ${port}`;
  for (const check of checks) statusLine(check.ok, check.id, check.message, check.ok ? '' : check.action);
}

function cmdLogs() {
  heading('Logs');
  ensureRuntimeDirs();
  const log = path.join(LOG_DIR, 'neorecall.log');
  if (!fs.existsSync(log)) {
    console.log('No logs yet.');
    return;
  }
  process.stdout.write(fs.readFileSync(log, 'utf8'));
}

function cmdChannel(args = []) {
  heading('Release Channel');
  ensureDefaultEnvFile();
  if (!args[0]) {
    console.log(`  configured ${releaseChannelSummary(currentReleaseChannel())}`);
    return currentReleaseChannel();
  }
  const nextChannel = parseReleaseChannel(args[0]);
  if (!nextChannel) throw new Error('Usage: neorecall channel [stable|beta]');
  writeReleaseChannelToEnvFile(nextChannel, ENV_FILE);
  process.env.NEORECALL_RELEASE_CHANNEL = nextChannel;
  logOk(`Release channel set to ${releaseChannelSummary(nextChannel)}`);
  return nextChannel;
}

async function cmdUpdate(args = []) {
  heading(`Update ${APP_NAME}`);
  ensureDefaultEnvFile();
  ensureRuntimeDirs();
  const requestedChannel = args[0] ? parseReleaseChannel(args[0]) : null;
  if (args[0] && !requestedChannel) throw new Error('Usage: neorecall update [stable|beta]');
  const releaseChannel = requestedChannel || currentReleaseChannel();
  if (requestedChannel) {
    writeReleaseChannelToEnvFile(releaseChannel, ENV_FILE);
    process.env.NEORECALL_RELEASE_CHANNEL = releaseChannel;
    logOk(`Release channel set to ${releaseChannelSummary(releaseChannel)}`);
  }
  const versionBefore = currentInstalledVersionLabel();
  const githubInstallRef = releaseChannel === 'beta' ? '#beta' : '';
  const githubInstallSpec = `git+https://github.com/${GITHUB_REPO}.git${githubInstallRef}`;

  if (fs.existsSync(path.join(APP_DIR, '.git')) && commandExists('git')) {
    const current = runQuiet('git', ['rev-parse', '--short', 'HEAD']);
    // Rolling tags such as firmware-latest are force-moved on origin. Without
    // --force, fetch refuses to update the local tag and aborts the whole update.
    runOrThrow('git', ['fetch', 'origin', '--tags', '--force']);
    const targetBranch = resolvePreferredGitBranch(releaseChannel);
    logInfo(`Using git branch ${targetBranch} for the ${releaseChannel} channel.`);
    if (gitWorkingTreeDirty()) {
      logWarn('Discarding local changes...');
      runQuiet('git', ['reset', '--hard', 'HEAD']);
      runQuiet('git', ['clean', '-fd']);
    }
    ensureGitBranchForReleaseChannel(targetBranch);
    backupRuntimeData();
    runOrThrow('git', ['pull', '--rebase', 'origin', targetBranch]);
    const next = runQuiet('git', ['rev-parse', '--short', 'HEAD']);
    if (current.status === 0 && next.status === 0 && current.stdout.trim() !== next.stdout.trim()) {
      logOk(`Updated ${current.stdout.trim()} -> ${next.stdout.trim()}`);
      installDependencies();
      buildBundledWebClientIfPossible();
    } else {
      logOk('Already up to date');
      buildBundledWebClientIfPossible();
    }
  } else {
    logWarn(`No git repo detected; installing from ${githubInstallSpec}.`);
    if (!commandExists('npm')) throw new Error('npm is required for global NeoRecall updates.');
    backupRuntimeData();
    runOrThrow('npm', ['install', '-g', githubInstallSpec, '--force'], { env: withInstallEnv() });
    logOk('npm global update completed from GitHub');
  }

  if (!hasBundledWebClient(WEB_CLIENT_DIR)) {
    throw new Error('No bundled Flutter web client found after update.');
  }
  // A release can change the pinned speech or language model without changing
  // any JavaScript dependency. Prepare and verify those assets before the new
  // worker starts; otherwise it can repeatedly fail queued recordings using
  // weights left behind by the previous release.
  await ensureModelsReady();
  cmdRestart();
  logOk(`Installed version ${versionBefore} -> ${currentInstalledVersionLabel()}`);
}

async function cmdEnv(args = []) {
  heading('Environment Variables');
  ensureDefaultEnvFile();
  const action = (args[0] || '').trim().toLowerCase();
  if (!action) {
    console.log('Usage: neorecall env <subcommand>');
    console.log('');
    console.log('  neorecall env list            List all variables (secrets masked)');
    console.log('  neorecall env get KEY         Print a single variable');
    console.log('  neorecall env set KEY VALUE   Set a variable');
    console.log('  neorecall env unset KEY       Remove a variable');
    return;
  }
  if (action === 'list') {
    const env = parseEnv(readEnvFileRaw(ENV_FILE));
    if (env.size === 0) {
      logWarn(`No .env found at ${ENV_FILE}`);
      return;
    }
    for (const [k, v] of [...env.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      console.log(`${k}=${maskEnvValue(k, v)}`);
    }
    return;
  }
  if (action === 'get') {
    const key = args[1];
    if (!key) throw new Error('Usage: neorecall env get <KEY>');
    const env = parseEnv(readEnvFileRaw(ENV_FILE));
    if (!env.has(key)) throw new Error(`Key not found: ${key}`);
    console.log(env.get(key));
    return;
  }
  if (action === 'set') {
    const key = args[1];
    const value = args.slice(2).join(' ');
    if (!key || !value) throw new Error('Usage: neorecall env set <KEY> <VALUE>');
    validateEnvKey(key);
    upsertEnvValue(ENV_FILE, key, value);
    logOk(`Set ${key} in ${ENV_FILE}`);
    return;
  }
  if (action === 'unset') {
    const key = args[1];
    if (!key) throw new Error('Usage: neorecall env unset <KEY>');
    removeEnvValue(ENV_FILE, key);
    logOk(`Removed ${key} from ${ENV_FILE}`);
    return;
  }
  throw new Error('Usage: neorecall env [list|get|set|unset] ...');
}

function cmdVersion() {
  console.log(currentInstalledVersionLabel());
}

async function cmdFix() {
  cliBanner(`Fix ${APP_NAME}`, 'reset and recover');
  heading(`Repair ${APP_NAME}`);
  ensureDefaultEnvFile();
  assertSupportedNodeRuntime();
  if (!dependenciesReady()) {
    installDependencies();
  } else {
    logOk('Runtime dependencies are ready');
  }
  buildBundledWebClientIfPossible({ required: true });
  require('../server/db/migrate').migrate();
  await ensureModelsReady();
  installService();
  await waitForServerReady(loadEnvPort());
  logOk('Repair complete');
}

function cmdUninstall() {
  heading(`Uninstall service for ${APP_NAME}`);
  cmdStop();
  if (fs.existsSync(PLIST_DST)) {
    fs.rmSync(PLIST_DST, { force: true });
    logOk(`Removed ${PLIST_DST}`);
  }
  if (fs.existsSync(SYSTEMD_UNIT)) {
    runQuiet('systemctl', ['--user', 'disable', 'neorecall.service']);
    fs.rmSync(SYSTEMD_UNIT, { force: true });
    runQuiet('systemctl', ['--user', 'daemon-reload']);
    logOk(`Removed ${SYSTEMD_UNIT}`);
  }
  logInfo(`Runtime data at ${RUNTIME_HOME} was preserved.`);
}

async function resetPassword(account, password) {
  if (!account || !password || password.length < 12) {
    throw new Error('Usage: neorecall reset-password <username-or-email> <new-password-of-at-least-12-characters>');
  }
  const db = require('../server/db/database').getDatabase();
  require('../server/db/migrate').migrate(db);
  const user = db.prepare('SELECT * FROM users WHERE username=? COLLATE NOCASE OR email=? COLLATE NOCASE').get(account, account);
  if (!user) throw new Error('User not found.');
  const passwordHash = await require('../server/utils/crypto').hashPassword(password);
  db.transaction(() => {
    db.prepare('UPDATE users SET password_hash=? WHERE id=?').run(passwordHash, user.id);
    db.prepare("UPDATE user_sessions SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND revoked_at IS NULL").run(user.id);
  })();
  logOk(`Password reset and sessions revoked for ${user.username}.`);
}

function printHelp() {
  console.log(`NeoRecall ${currentInstalledVersionLabel()}`);
  console.log('');
  console.log('Commands:');
  const row = (cmd, desc) => console.log(`  ${cmd.padEnd(28)} ${desc}`);
  row('install', 'Install service, bootstrap runtime, and prepare local semantic search');
  row('setup [--skip-models]', 'Prepare semantic search, database, and web client');
  row('setup --channel beta|stable', 'Setup and set release channel');
  row('start', 'Start NeoRecall');
  row('stop', 'Stop NeoRecall');
  row('restart', 'Restart NeoRecall');
  row('status', 'Show runtime status');
  row('doctor', 'Read-only diagnostics');
  row('logs', 'Print service logs');
  row('rebuild-web', 'Rebuild the Flutter web client');
  row('repair|fix', 'Repair dependencies, web client, and service');
  row('uninstall', 'Remove the user service (keeps data)');
  row('channel', 'Show current release channel');
  row('channel stable|beta', 'Switch release channel');
  row('update', 'Update to latest on current channel');
  row('update stable|beta', 'Update and switch channel');
  row('env list|get|set|unset', 'Manage ~/.neorecall/.env');
  row('reset-password <user> <pw>', 'Reset a local account password');
  row('version', 'Print installed version');
  row('help', 'Show this help');
}

async function runCLI(argv) {
  const [command = '', ...args] = argv;
  switch (command) {
    case '':
    case 'help':
    case '--help':
    case '-h':
      printHelp();
      return;
    case 'install':
      return cmdInstall(args);
    case 'setup':
      return cmdSetup(args);
    case 'start':
      return cmdStart();
    case 'stop':
      return cmdStop();
    case 'restart':
      return cmdRestart();
    case 'status':
      return cmdStatus();
    case 'doctor':
      return cmdDoctor();
    case 'logs':
      return cmdLogs();
    case 'rebuild-web':
      return cmdRebuildWeb();
    case 'repair':
    case 'fix':
      return cmdFix(args);
    case 'uninstall':
      return cmdUninstall();
    case 'channel':
      return cmdChannel(args);
    case 'update':
      return cmdUpdate(args);
    case 'env':
      return cmdEnv(args);
    case 'reset-password':
      return resetPassword(args[0], args[1]);
    case 'version':
    case '--version':
    case '-V':
    case '-v':
      return cmdVersion();
    default:
      throw new Error(`Unknown command: ${command}. Run "neorecall --help" for usage.`);
  }
}

module.exports = {
  runCLI,
  cmdInstall,
  cmdSetup,
  cmdStart,
  cmdStop,
  cmdRestart,
  cmdStatus,
  cmdDoctor,
  cmdLogs,
  cmdChannel,
  cmdUpdate,
  cmdEnv,
  cmdVersion,
  resetPassword,
};
