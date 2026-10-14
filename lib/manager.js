'use strict';

const fs = require('node:fs');
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
  parseReleaseChannel,
  readConfiguredReleaseChannel,
  writeReleaseChannelToEnvFile,
} = require('../runtime/release_channel');
const { createGitHelpers } = require('../runtime/git_helpers');
const {
  defaultSourceInstallDirectory,
  prepareSourceInstallation,
} = require('./source_install');
const ui = require('./cli/ui');
const prompt = require('./cli/prompt');
const { closeStepList, createStepList, formatDuration, noteActiveStep } = require('./cli/steps');
const { printHelp } = require('./cli/help');
const {
  needsAttention,
  printChecks,
  printStatus,
  statusChecks,
} = require('./cli/status');
const { printHomeHeader, printInstallFinished } = require('./cli/screens');
const { createUpdateGit } = require('./cli/updates');

const APP_NAME = 'NeoRecall';
const DEFAULT_PORT = 4500;
// spawnSync's 1 MB default is too small for npm and Flutter build output.
const QUIET_OUTPUT_BUFFER = 64 * 1024 * 1024;
const LOG_TAIL_LINES = 200;

loadEnvironment();

function runQuiet(cmd, args, options = {}) {
  return spawnSync(cmd, args, {
    encoding: 'utf8',
    cwd: options.cwd || APP_DIR,
    env: options.env || process.env,
    stdio: options.stdio || ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout,
    maxBuffer: QUIET_OUTPUT_BUFFER,
  });
}

// The last lines a failed quiet command printed, for its error message.
function outputTail(result, lines = 12) {
  const text = String(result.stderr || result.stdout || result.error?.message || '').trim();
  return text.split('\n').slice(-lines).join('\n');
}

// Runs a command without echoing its output; a failure carries its last lines.
function runOrThrow(cmd, args, options = {}, failureMessage = `${cmd} ${args.join(' ')} failed`) {
  const result = runQuiet(cmd, args, options);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const tail = outputTail(result);
    throw new Error(tail ? `${failureMessage}\n${tail}` : failureMessage);
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

// While a step list is on screen, progress messages become the current step's
// detail line instead of scrolling past it. Warnings always print.
function logInfo(msg) {
  if (!noteActiveStep(msg)) ui.item('info', msg);
}

function logOk(msg) {
  if (!noteActiveStep(msg)) ui.item('ok', msg);
}

function logWarn(msg) {
  ui.item('warn', msg);
}

// Things worth telling the person once a long command has finished.
const followUps = [];

function rememberFollowUp(message) {
  if (!followUps.includes(message)) followUps.push(message);
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

function appUrl(port = loadEnvPort()) {
  return `http://localhost:${port}/app/`;
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
    return JSON.parse(fs.readFileSync(path.join(APP_DIR, 'package.json'), 'utf8')).version || '0.0.0';
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
  logInfo(`Switched to the ${targetBranch} branch`);
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
  return target;
}

function dependenciesReady() {
  try {
    require.resolve('express', { paths: [APP_DIR] });
    require.resolve('better-sqlite3-multiple-ciphers', { paths: [APP_DIR] });
    return true;
  } catch {
    return false;
  }
}

function installDependencies() {
  runOrThrow(
    'npm',
    ['install', '--omit=dev', '--no-audit', '--no-fund'],
    { env: withInstallEnv() },
    "Installing NeoRecall's dependencies failed.",
  );
}

function assertSupportedNodeRuntime() {
  const major = Number(String(process.versions.node || '').split('.')[0]);
  if (!Number.isInteger(major) || major < 20) {
    throw new Error(`NeoRecall requires Node.js 20 or newer. Current runtime is ${process.versions.node || 'unknown'}.`);
  }
}

function buildBundledWebClientIfPossible({ required = false } = {}) {
  // Build tools print a lot; only a failure's last lines are worth showing.
  let failedOutput = '';
  return sharedBuildWebClient({
    flutterAppDir: FLUTTER_APP_DIR,
    webClientDir: WEB_CLIENT_DIR,
    runCommand: (command, args, options = {}) => {
      const result = runQuiet(command, args, options);
      if (result.status !== 0) failedOutput = outputTail(result);
      return result;
    },
    commandExistsFn: commandExists,
    onMissingSources: () => logInfo('Using the app that came with NeoRecall'),
    onUsingBundledClient: () => logInfo('Using the app that came with NeoRecall'),
    onMissingFlutter: () => logInfo('Using the app that came with NeoRecall'),
    onBuildStart: () => logInfo('Building the app — this can take a few minutes'),
    onBuildSuccess: () => logOk('App rebuilt'),
    onBuildFailed: () => logWarn('The app could not be rebuilt; keeping the one already installed'),
    fail: (message) => { throw new Error(failedOutput ? `${message}\n${failedOutput}` : message); },
    required,
  });
}

function ensureWebClient() {
  if (!hasBundledWebClient(WEB_CLIENT_DIR)) buildBundledWebClientIfPossible({ required: true });
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
        logInfo(`Already running (process ${existingPid})`);
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
  rememberFollowUp("NeoRecall can't start by itself on this computer. After a restart, run `neorecall start`.");
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
}

function installLinuxService() {
  ensureRuntimeDirs();
  fs.mkdirSync(path.dirname(SYSTEMD_UNIT), { recursive: true });
  fs.writeFileSync(SYSTEMD_UNIT, renderSystemdUnit(), { mode: 0o600 });
  runOrThrow('systemctl', ['--user', 'daemon-reload']);
  runOrThrow('systemctl', ['--user', 'enable', 'neorecall.service']);
  runOrThrow('systemctl', ['--user', 'start', 'neorecall.service']);
  runOrThrow('systemctl', ['--user', 'is-active', '--quiet', 'neorecall.service']);
}

function installService() {
  const platform = detectPlatform();
  if (platform === 'macos' && commandExists('launchctl')) {
    installMacService();
    return;
  }
  if (platform === 'linux' && commandExists('systemctl')) {
    try {
      installLinuxService();
      return;
    } catch (error) {
      logWarn(`The background service could not be set up (${error.message}); starting NeoRecall directly instead.`);
    }
  }
  startFallback();
}

function serviceInstalled() {
  const platform = detectPlatform();
  return (platform === 'macos' && fs.existsSync(PLIST_DST))
    || (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT));
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

// The server's own report; /ready answers 503 with the same body while not ready.
async function fetchServerJson(port, route) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}${route}`, { signal: AbortSignal.timeout(1500) });
    return await response.json();
  } catch {
    return null;
  }
}

async function waitForServerReady(port, timeoutMs = 30000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if ((await fetchServerJson(port, '/health'))?.status === 'ok') return true;
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
  const error = new Error(`NeoRecall did not answer on port ${port}. Its log usually says why.`);
  error.code = 'SERVER_NOT_READY';
  throw error;
}

// A server that cannot bind its port exits at startup, so another program on
// it is reported before starting rather than as a timeout afterwards.
async function ensurePortFree(port) {
  if (!(await isPortOpen(port))) return;
  if ((await fetchServerJson(port, '/health'))?.status === 'ok') return;
  const error = new Error(
    `Another app on this computer is already using port ${port}, the address NeoRecall wants. `
    + 'Close that app, or give NeoRecall another port with `neorecall env set NEORECALL_PORT <number>`.',
  );
  error.code = 'PORT_IN_USE';
  throw error;
}

async function waitForPortClosed(port, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (await isPortOpen(port)) {
    if (Date.now() > deadline) throw new Error('NeoRecall did not stop in time. Try again, or restart this computer.');
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
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

function modelsPresent() {
  const { installedMatchesManifest, manifest } = require('./model_downloader');
  const modelsDir = ensureRuntimeDirs().models;
  return manifest.models.every((model) => model.files
    .every((file) => installedMatchesManifest(file.path, path.join(modelsDir, file.path))));
}

async function ensureModelsReady() {
  const models = require('./model_downloader');
  // Progress arrives per network chunk; the line changes once per percent.
  let shown = '';
  await models.downloadAll(({ file, received, total }) => {
    if (!total) return;
    const line = `${path.basename(file)} ${Math.floor((received / total) * 100)}%`;
    if (line !== shown) logInfo(line);
    shown = line;
  });
  logInfo('Checking the downloads');
  const failures = await models.verifyAll();
  if (failures.length) throw new Error(`Model verification failed: ${JSON.stringify(failures)}`);
  for (const { path: retired, bytes } of models.pruneRetired()) {
    logInfo(`Removed the old ${path.basename(retired)} (${(bytes / 1e9).toFixed(1)} GB freed)`);
  }
  const runtime = ensureRuntimeDirs();
  process.env.NEORECALL_TRANSFORMERS_LOCAL_PATH = runtime.models;
  const embedding = await require('../server/embeddings/embedding_service').embed('NeoRecall model verification', 'passage');
  if (embedding.length !== 384) throw new Error('Embedding model probe did not return 384 dimensions.');
  require('../server/db/database').probeVectorExtension();
  // Optional: no build for every platform, so this reports rather than throws.
  if (!require('../server/transcription/local_analysis').available()) {
    rememberFollowUp('Speaker identity is unavailable on this computer, so transcripts carry no speaker names.');
  }
}

// One step list for a fixed sequence of [label, task] pairs. Returns each
// task's result in order.
async function runSteps(steps, options) {
  const list = createStepList(steps.map(([label]) => label), options);
  const results = [];
  try {
    for (const [index, [, task]] of steps.entries()) {
      results.push(await list.run(index, task));
    }
  } finally {
    closeStepList(list);
  }
  return results;
}

function printRunning(headline) {
  ui.blank();
  ui.item('ok', ui.paint.bold(headline));
  ui.print(`    ${ui.paint.accent(appUrl())}`);
  ui.blank();
}

function printFollowUps() {
  for (const text of followUps) ui.item('info', text.replace(/`([^`]+)`/g, (_, command) => ui.paint.command(command)));
  if (followUps.length > 0) ui.blank();
}

function openInBrowser(url) {
  const opener = { darwin: 'open', win32: 'explorer' }[process.platform] || 'xdg-open';
  spawnSync(opener, [url], { stdio: 'ignore' });
}

function migrateDatabase() {
  require('../server/db/migrate').migrate();
}

async function cmdInstall(args = []) {
  const skipModels = args.includes('--skip-models');
  ui.title(`Installing ${APP_NAME}`, skipModels ? '' : 'The first time, this downloads a few GB of speech and search models.');
  ui.blank();
  const port = loadEnvPort();
  const steps = [
    [["Preparing NeoRecall's files", "Prepared NeoRecall's files"], () => {
      ensureDefaultEnvFile();
      assertSupportedNodeRuntime();
      if (!dependenciesReady()) installDependencies();
    }],
    [['Preparing the app', 'Prepared the app'], ensureWebClient],
    [['Preparing the database', 'Prepared the database'], migrateDatabase],
  ];
  if (skipModels) {
    rememberFollowUp('The models were skipped. Run `neorecall setup` before recording.');
  } else {
    steps.push([['Downloading the speech and search models', 'Downloaded the speech and search models'], ensureModelsReady]);
  }
  steps.push([['Starting NeoRecall', 'Started NeoRecall'], async () => {
    await ensurePortFree(port);
    installService();
  }]);
  steps.push([["Checking it's answering", "It's answering"], () => waitForServerReady(port)]);
  await runSteps(steps, { bar: true });

  printInstallFinished({
    url: appUrl(port),
    startsItself: serviceInstalled(),
    notes: followUps.map((text) => text.replace(/`([^`]+)`/g, (_, command) => ui.paint.command(command))),
  });
  if (!ui.isInteractive()) return;
  ui.keys([['enter', 'open it'], ['q', 'done']]);
  if (await prompt.waitForKey(['return', 'q', 'escape']) === 'return') openInBrowser(appUrl(port));
}

function readChannelArgument(args) {
  return args.find((arg) => arg === 'stable' || arg === 'beta')
    || (args.includes('--channel') ? args[args.indexOf('--channel') + 1] : null)
    || args.find((arg) => arg.startsWith('--channel='))?.split('=')[1];
}

async function cmdSetup(args = []) {
  const channelArg = readChannelArgument(args);
  if (channelArg) {
    const channel = parseReleaseChannel(channelArg);
    if (!channel) throw new Error('Usage: neorecall setup [--channel stable|beta]');
    ensureDefaultEnvFile();
    writeReleaseChannelToEnvFile(channel, ENV_FILE);
    process.env.NEORECALL_RELEASE_CHANNEL = channel;
  }
  const skipModels = args.includes('--skip-models');
  ui.title(`Setting up ${APP_NAME}`, `Updates come from the ${releaseChannelSummary(currentReleaseChannel())} channel.`);
  ui.blank();
  const steps = [
    [['Preparing the database', 'Prepared the database'], () => {
      ensureDefaultEnvFile();
      assertSupportedNodeRuntime();
      migrateDatabase();
    }],
  ];
  if (!skipModels) {
    steps.push([['Downloading the speech and search models', 'Downloaded the speech and search models'], ensureModelsReady]);
  }
  steps.push([['Preparing the app', 'Prepared the app'], ensureWebClient]);
  await runSteps(steps, { bar: true });
  ui.blank();
  ui.item('ok', ui.paint.bold(`${APP_NAME} is set up`), RUNTIME_HOME);
  ui.blank();
  printFollowUps();
  if (await isPortOpen(loadEnvPort())) {
    ui.note(`NeoRecall is running; it uses new models after ${ui.paint.command('neorecall restart')}.`);
    ui.blank();
  }
}

// Starts whichever service manager this installation uses.
function launchService() {
  ensureDefaultEnvFile();
  ensureWebClient();
  const platform = detectPlatform();
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    installMacService();
  } else if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    runOrThrow('systemctl', ['--user', 'start', 'neorecall.service']);
    runOrThrow('systemctl', ['--user', 'is-active', '--quiet', 'neorecall.service']);
  } else {
    startFallback();
  }
}

async function cmdStart() {
  const port = loadEnvPort();
  await runSteps([
    [['Starting NeoRecall', 'Started NeoRecall'], async () => {
      await ensurePortFree(port);
      launchService();
    }],
    [["Checking it's answering", "It's answering"], () => waitForServerReady(port)],
  ]);
  printRunning(`${APP_NAME} is running.`);
}

// Asks the service manager (or the fallback process) to stop NeoRecall.
function stopService() {
  const platform = detectPlatform();
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    const domain = launchctlDomain();
    if (domain) {
      runQuiet('launchctl', ['bootout', domain, PLIST_DST]);
      runQuiet('launchctl', ['bootout', launchctlServiceTarget()]);
    }
    runQuiet('launchctl', ['unload', PLIST_DST]);
  } else if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    runQuiet('systemctl', ['--user', 'stop', 'neorecall.service']);
  } else if (fs.existsSync(PID_FILE)) {
    const pid = Number(fs.readFileSync(PID_FILE, 'utf8').trim());
    if (Number.isFinite(pid) && pid > 0) {
      try {
        process.kill(pid, 'SIGTERM');
      } catch {
        // A stale PID file; the process is already gone.
      }
    }
    fs.rmSync(PID_FILE, { force: true });
  }
}

async function stopAndWait() {
  stopService();
  await waitForPortClosed(loadEnvPort());
}

async function cmdStop() {
  await runSteps([[['Stopping NeoRecall', 'Stopped NeoRecall'], stopAndWait]]);
  ui.blank();
  ui.item('ok', ui.paint.bold(`${APP_NAME} stopped`));
  ui.blank();
}

async function cmdRestart() {
  const startedAt = Date.now();
  const port = loadEnvPort();
  await runSteps([
    [['Getting the app ready', 'Got the app ready'], () => buildBundledWebClientIfPossible()],
    [['Stopping NeoRecall', 'Stopped NeoRecall'], stopAndWait],
    [['Starting it again', 'Started it again'], async () => {
      await ensurePortFree(port);
      launchService();
    }],
    [["Checking it's answering", "It's answering"], () => waitForServerReady(port)],
  ]);
  printRunning(`Back online in ${formatDuration(Date.now() - startedAt)}.`);
}

async function cmdRebuildWeb() {
  await runSteps([[['Rebuilding the app', 'Rebuilt the app'], () => buildBundledWebClientIfPossible({ required: true })]]);
  ui.blank();
  ui.item('ok', ui.paint.bold('App rebuilt'));
  ui.blank();
}

function isGitCheckout() {
  return fs.existsSync(path.join(APP_DIR, '.git')) && commandExists('git');
}

function findPendingUpdate(channel) {
  if (!isGitCheckout()) return { checked: false, update: null };
  const updateGit = createUpdateGit(runQuiet);
  if (!updateGit.fetchRemote()) return { checked: false, update: null };
  return { checked: true, update: updateGit.pendingUpdate(resolvePreferredGitBranch(channel)) };
}

// Reading admins opens the database, so only once one exists, and only reads:
// status migrates nothing, and a database it cannot open is reported rather
// than ending the whole report.
function readAdmins() {
  if (!fs.existsSync(paths().database)) return null;
  try {
    const access = adminAccess({ migrate: false });
    return { names: access.listAdmins().map((admin) => admin.username), missing: access.needsAdminGrant() };
  } catch (error) {
    return { error: error.message };
  }
}

// What `neorecall status` and the home screen know about this installation.
async function collectStatusFacts({ checkForUpdate = false } = {}) {
  const port = loadEnvPort();
  const health = await fetchServerJson(port, '/health');
  const running = health?.status === 'ok';
  const platform = detectPlatform();
  let serviceActive = false;
  if (platform === 'macos' && fs.existsSync(PLIST_DST)) {
    const result = runQuiet('launchctl', ['list', SERVICE_LABEL]);
    serviceActive = result.status === 0 && Boolean(result.stdout.trim());
  } else if (platform === 'linux' && fs.existsSync(SYSTEMD_UNIT)) {
    const result = runQuiet('systemctl', ['--user', 'is-active', 'neorecall.service']);
    serviceActive = result.status === 0 && result.stdout.trim() === 'active';
  }
  const channel = currentReleaseChannel();
  const updateCheck = checkForUpdate ? findPendingUpdate(channel) : { checked: false, update: null };
  return {
    appDir: APP_DIR,
    runtimeHome: RUNTIME_HOME,
    envFile: ENV_FILE,
    port,
    url: appUrl(port),
    running,
    ready: running ? await fetchServerJson(port, '/ready') : null,
    version: readInstalledPackageVersion(),
    versionLabel: currentInstalledVersionLabel(),
    runningVersion: health?.version || null,
    channelSummary: releaseChannelSummary(channel),
    serviceActive,
    configPresent: fs.existsSync(ENV_FILE),
    webClientPresent: hasBundledWebClient(WEB_CLIENT_DIR),
    modelsPresent: running || modelsPresent(),
    admins: readAdmins(),
    update: updateCheck.update,
    updateChecked: updateCheck.checked,
  };
}

function isInstalled() {
  return serviceInstalled() || fs.existsSync(PID_FILE) || fs.existsSync(paths().database);
}

function homeActions(facts) {
  return [
    facts.running
      ? { label: 'Open NeoRecall in my browser', value: async () => openInBrowser(facts.url) }
      : { label: 'Start NeoRecall', value: cmdStart },
    facts.update && {
      label: 'Get the latest version',
      hint: `${facts.update.version || 'A new version'} is ready`,
      value: () => cmdUpdate(),
    },
    { label: 'Check that everything works', value: () => cmdStatus() },
    facts.running && { label: 'Restart NeoRecall', value: cmdRestart },
    { label: 'Back up my memories now', hint: 'encrypted', value: () => require('./backup_cli').cmdBackup() },
    { label: "Something's wrong — help me fix it", value: cmdDoctor },
    { label: 'More…', hint: 'every command', value: async () => printHelp() },
  ].filter(Boolean);
}

async function cmdHome() {
  if (!isInstalled()) {
    if (!ui.isInteractive()) {
      printHelp();
      return;
    }
    ui.blank();
    ui.print(`  ${ui.paint.command('NeoRecall')}  ${ui.paint.faint('your day, remembered privately')}`);
    ui.blank();
    if (await prompt.confirm("NeoRecall isn't set up on this computer yet. Set it up now?")) await cmdInstall();
    return;
  }
  const facts = await collectStatusFacts({ checkForUpdate: ui.isInteractive() });
  // Running state and updates are in the header and the menu already.
  printHomeHeader(facts, statusChecks(facts)
    .filter((check) => check.id !== 'server' && check.id !== 'version' && needsAttention(check)));
  ui.blank();
  if (!ui.isInteractive()) {
    ui.print(`  ${ui.paint.faint('Every command:')} ${ui.paint.command('neorecall help')}`);
    ui.blank();
    return;
  }
  const action = await prompt.select('What would you like to do?', homeActions(facts), { cancelValue: null });
  if (action) await action();
}

async function cmdStatus(args = []) {
  const facts = await collectStatusFacts({ checkForUpdate: ui.isInteractive() });
  printStatus(facts, { details: args.includes('--details') });
}

async function cmdDoctor() {
  const port = loadEnvPort();
  let runtimeWritable = true;
  try { fs.accessSync(RUNTIME_HOME, fs.constants.R_OK | fs.constants.W_OK); } catch { runtimeWritable = false; }
  const serverReachable = (await fetchServerJson(port, '/health'))?.status === 'ok';
  const check = (label, ok, messages, fix) => ({
    tone: ok ? 'ok' : 'error',
    label,
    detail: messages[ok ? 0 : 1],
    fix: ok ? null : fix,
  });
  const checks = [
    check("NeoRecall's data folder", runtimeWritable,
      ['Can be read and changed', `NeoRecall can't write to ${RUNTIME_HOME} — check your user owns it`], null),
    check('Settings', fs.existsSync(ENV_FILE), ['Saved', 'Not set up yet'], 'neorecall setup'),
    check("NeoRecall's files", dependenciesReady(), ['All there', 'Some are missing'], 'neorecall repair'),
    check('App in your browser', hasBundledWebClient(WEB_CLIENT_DIR), ['Installed', 'Missing'], 'neorecall rebuild-web'),
    check('Speech and search models', modelsPresent(), ['Downloaded', 'Not downloaded yet'], 'neorecall setup'),
    check('NeoRecall', serverReachable, [`Running on port ${port}`, `Not running on port ${port}`], 'neorecall start'),
  ];

  ui.title(`Checking ${APP_NAME}`, 'Nothing is changed while this runs.');
  printChecks(checks);
  ui.blank();
  if (checks.every((entry) => entry.tone === 'ok')) {
    ui.item('ok', ui.paint.bold('No problems found'));
    ui.blank();
  } else if (ui.isInteractive() && await prompt.confirm('Fix these for you now?')) {
    await cmdFix();
  } else {
    ui.note(`Most problems are fixed by ${ui.paint.command('neorecall repair')}.`);
    ui.blank();
  }
}

function cmdLogs() {
  ensureRuntimeDirs();
  const log = path.join(LOG_DIR, 'neorecall.log');
  if (!fs.existsSync(log)) {
    ui.blank();
    ui.item('info', 'NeoRecall has not written a log yet.');
    ui.blank();
    return;
  }
  const lines = fs.readFileSync(log, 'utf8').trimEnd().split('\n');
  ui.title('What NeoRecall has been doing', `The last ${Math.min(lines.length, LOG_TAIL_LINES)} lines of ${log}`);
  ui.blank();
  process.stdout.write(`${lines.slice(-LOG_TAIL_LINES).join('\n')}\n`);
}

function cmdChannel(args = []) {
  ensureDefaultEnvFile();
  if (!args[0]) {
    ui.blank();
    ui.item('info', `Updates come from the ${releaseChannelSummary(currentReleaseChannel())} channel.`);
    ui.note(`Switch with ${ui.paint.command('neorecall channel stable')} or ${ui.paint.command('neorecall channel beta')}.`);
    ui.blank();
    return currentReleaseChannel();
  }
  const nextChannel = parseReleaseChannel(args[0]);
  if (!nextChannel) throw new Error('Usage: neorecall channel [stable|beta]');
  writeReleaseChannelToEnvFile(nextChannel, ENV_FILE);
  process.env.NEORECALL_RELEASE_CHANNEL = nextChannel;
  logOk(`Updates now come from the ${releaseChannelSummary(nextChannel)} channel`);
  ui.note(`Get it with ${ui.paint.command('neorecall update')}.`);
  return nextChannel;
}

async function migrateLegacyPackageInstallation(releaseChannel, versionBefore) {
  ui.title(`Moving ${APP_NAME} to a Git installation`, 'Updates will come straight from the release channel afterwards.');
  for (const command of ['git', 'npm']) {
    if (!commandExists(command)) {
      throw new Error(
        `${command} is required to migrate this legacy installation. `
        + 'Install Git and Node.js with npm, then rerun `neorecall update`.',
      );
    }
  }

  const sourceDirectory = defaultSourceInstallDirectory();
  const prepared = prepareSourceInstallation({
    run: (command, args, options = {}) => runQuiet(command, args, options),
    releaseChannel,
    sourceDirectory,
    onInfo: (message) => logInfo(message),
  });
  logOk(`Source checkout prepared on ${prepared.targetBranch}`);

  const targetCli = path.join(sourceDirectory, 'bin', 'neorecall.js');
  const adoption = spawnSync(process.execPath, [targetCli, 'install'], {
    cwd: sourceDirectory,
    env: { ...process.env, NEORECALL_HOME: RUNTIME_HOME },
    stdio: 'inherit',
  });
  if (adoption.error || adoption.status !== 0) {
    throw new Error(
      `The Git checkout was prepared at ${sourceDirectory}, but the existing `
      + 'service could not be switched to it. No runtime data was removed; '
      + `rerun: ${process.execPath} ${targetCli} install`,
    );
  }
  logOk(`Moved ${versionBefore} → ${prepared.version}; future updates use ${sourceDirectory}`);
}

function printChanges(changes) {
  if (changes.length === 0) return;
  ui.section("What's new");
  for (const change of changes) ui.item('info', change);
}

// Puts the code from before the update back and starts it again.
async function rollBackUpdate(updateGit, before) {
  if (!updateGit.restore(before)) throw new Error('The previous version could not be restored.');
  installDependencies();
  stopService();
  await waitForPortClosed(loadEnvPort());
  launchService();
  await waitForServerReady(loadEnvPort());
}

async function cmdUpdate(args = []) {
  ensureDefaultEnvFile();
  const notesOnly = args.includes('--notes');
  const channelArg = args.find((arg) => !arg.startsWith('--'));
  const requestedChannel = channelArg ? parseReleaseChannel(channelArg) : null;
  if (channelArg && !requestedChannel) throw new Error('Usage: neorecall update [stable|beta] [--notes]');
  const releaseChannel = requestedChannel || currentReleaseChannel();
  if (requestedChannel && !notesOnly) {
    writeReleaseChannelToEnvFile(releaseChannel, ENV_FILE);
    process.env.NEORECALL_RELEASE_CHANNEL = releaseChannel;
  }
  const versionBefore = readInstalledPackageVersion();

  // Package installations predate the Git installer. Convert them into a
  // source checkout instead of pulling another tarball, so every later update
  // is a plain `git pull` against the release channel branch.
  if (!isGitCheckout()) {
    if (notesOnly) throw new Error('Release notes need a Git installation of NeoRecall.');
    await migrateLegacyPackageInstallation(releaseChannel, versionBefore);
    return;
  }

  const updateGit = createUpdateGit(runQuiet);
  if (!updateGit.fetchRemote()) {
    throw new Error("NeoRecall couldn't reach GitHub to look for updates. Check the internet connection and try again.");
  }
  const targetBranch = resolvePreferredGitBranch(releaseChannel);
  const pending = updateGit.pendingUpdate(targetBranch, { allowOlder: Boolean(requestedChannel) });
  const before = updateGit.head();
  if (!pending) {
    ui.blank();
    logOk(`You have the latest version (${versionBefore})`);
    ui.blank();
    return;
  }
  const versionAfter = pending.version || 'the latest version';
  if (notesOnly) {
    ui.blank();
    ui.item('warn', ui.paint.bold(`${versionAfter} is ready`), `you have ${versionBefore}`);
    printChanges(updateGit.changesBetween(before.sha, pending.remoteRef));
    ui.blank();
    ui.note(`Get it with ${ui.paint.command('neorecall update')}.`);
    ui.blank();
    return;
  }

  ui.title(`Updating ${APP_NAME}`, `${versionBefore} → ${versionAfter} · ${releaseChannel}`);
  ui.blank();
  const list = createStepList([
    ['Saving a backup of your memories and settings', 'Saved a backup of your memories and settings'],
    ['Downloading the new version', 'Downloaded the new version'],
    ['Installing it', 'Installed it'],
    ['Restarting NeoRecall', 'Restarted NeoRecall'],
    ['Making sure it all works', 'Made sure it all works'],
  ], { bar: true });
  let codeChanged = false;
  try {
    await list.run(0, () => backupRuntimeData());
    await list.run(1, () => {
      codeChanged = true;
      if (gitWorkingTreeDirty()) {
        logInfo('Discarding local changes');
        runQuiet('git', ['reset', '--hard', 'HEAD']);
        runQuiet('git', ['clean', '-fd']);
      }
      ensureGitBranchForReleaseChannel(targetBranch);
      runOrThrow('git', ['pull', '--rebase', 'origin', targetBranch]);
    });
    await list.run(2, async () => {
      installDependencies();
      // The checkout ships the web client built from this same commit, so a
      // local rebuild would only dirty the working tree the next update resets.
      ensureWebClient();
      // A release can change the pinned speech or language model without
      // changing any JavaScript dependency. Prepare and verify those assets
      // before the new worker starts; otherwise it can repeatedly fail queued
      // recordings using weights left behind by the previous release.
      await ensureModelsReady();
    });
    await list.run(3, async () => {
      await stopAndWait();
      launchService();
    });
    await list.run(4, async () => {
      const port = loadEnvPort();
      await waitForServerReady(port);
      const serving = (await fetchServerJson(port, '/health'))?.version;
      if (serving && serving !== readInstalledPackageVersion()) {
        throw new Error(`NeoRecall restarted but is still running ${serving}.`);
      }
    });
  } catch (error) {
    if (!codeChanged) {
      closeStepList(list);
      throw error;
    }
    const rollback = list.add([`Going back to ${versionBefore}`, `Went back to ${versionBefore}`]);
    let rollbackError = null;
    try {
      await list.run(rollback, () => rollBackUpdate(updateGit, before));
    } catch (restoreError) {
      rollbackError = restoreError;
    }
    closeStepList(list);
    const failure = new Error(rollbackError
      ? `${error.message}\nGoing back to ${versionBefore} also failed: ${rollbackError.message}`
      : `${error.message}\nNeoRecall is running ${versionBefore} again; nothing was lost.`);
    failure.code = rollbackError ? 'UPDATE_ROLLBACK_FAILED' : 'UPDATE_ROLLED_BACK';
    throw failure;
  }
  closeStepList(list);

  ui.blank();
  ui.item('ok', ui.paint.bold(`${APP_NAME} ${readInstalledPackageVersion()} is ready`), appUrl());
  printChanges(updateGit.changesBetween(before.sha, 'HEAD'));
  ui.blank();
  printFollowUps();
}

async function cmdEnv(args = []) {
  ensureDefaultEnvFile();
  const action = (args[0] || '').trim().toLowerCase();
  if (!action) {
    ui.title('Settings', ENV_FILE);
    ui.blank();
    for (const [command, description] of [
      ['neorecall env list', 'List every setting (secrets masked)'],
      ['neorecall env get KEY', 'Print one setting'],
      ['neorecall env set KEY VALUE', 'Change a setting'],
      ['neorecall env unset KEY', 'Remove a setting'],
    ]) {
      ui.print(`  ${ui.padEnd(ui.paint.bold(command), 32)}${ui.paint.muted(description)}`);
    }
    ui.blank();
    return;
  }
  if (action === 'list') {
    const env = parseEnv(readEnvFileRaw(ENV_FILE));
    if (env.size === 0) {
      logWarn(`No settings in ${ENV_FILE} yet`);
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
    logOk(`Saved ${key}`);
    ui.note(`NeoRecall reads it after ${ui.paint.command('neorecall restart')}.`);
    return;
  }
  if (action === 'unset') {
    const key = args[1];
    if (!key) throw new Error('Usage: neorecall env unset <KEY>');
    removeEnvValue(ENV_FILE, key);
    logOk(`Removed ${key}`);
    return;
  }
  throw new Error('Usage: neorecall env [list|get|set|unset] ...');
}

// Admin is the role on a user account, read by the server on every request, so
// a change here applies to a running server immediately. The first account
// created on an install is the admin; this is how the operator adds or removes
// more, or restores one after the last admin was revoked.
function adminAccess({ migrate = true } = {}) {
  const db = require('../server/db/database').getDatabase();
  if (migrate) require('../server/db/migrate').migrate(db);
  return require('../server/services/auth/admin_access_service');
}

function cmdAdmin(args = []) {
  const json = args.includes('--json');
  const [sub = 'list', username] = args.filter((arg) => arg !== '--json');
  if (sub !== 'list' && sub !== 'grant' && sub !== 'revoke') {
    throw new Error('Usage: neorecall admin [list | grant <username> | revoke <username>] [--json]');
  }
  if (sub !== 'list' && !username) throw new Error(`Usage: neorecall admin ${sub} <username>`);
  const access = adminAccess();
  if (sub === 'list') {
    const admins = access.listAdmins().map((admin) => admin.username);
    if (json) console.log(JSON.stringify({ admins }));
    else if (admins.length) admins.forEach((name) => logOk(name));
    else if (access.needsAdminGrant()) logWarn('No account is an admin yet. Run `neorecall admin grant <username>`.');
    else logInfo('No accounts yet. The first account you create becomes the admin.');
    return;
  }
  const result = sub === 'grant'
    ? access.grantAdmin(username, { source: 'cli' })
    : access.revokeAdmin(username, { source: 'cli' });
  if (json) console.log(JSON.stringify(result));
  else if (!result.changed) logInfo(`${result.username} ${sub === 'grant' ? 'is already' : 'is not'} an admin.`);
  else logOk(`${result.username} ${sub === 'grant' ? 'is now an admin' : 'is no longer an admin'}.`);
}

function cmdVersion() {
  console.log(currentInstalledVersionLabel());
}

async function cmdFix() {
  ui.title(`Repairing ${APP_NAME}`, 'This can take a few minutes.');
  ui.blank();
  const port = loadEnvPort();
  await runSteps([
    [['Reinstalling what it needs', 'Reinstalled what it needs'], () => {
      ensureDefaultEnvFile();
      assertSupportedNodeRuntime();
      if (!dependenciesReady()) installDependencies();
    }],
    [['Preparing the app', 'Prepared the app'], () => buildBundledWebClientIfPossible({ required: true })],
    [['Preparing the database', 'Prepared the database'], migrateDatabase],
    [['Checking the speech and search models', 'Checked the speech and search models'], ensureModelsReady],
    [['Starting NeoRecall', 'Started NeoRecall'], installService],
    [["Checking it's answering", "It's answering"], () => waitForServerReady(port)],
  ], { bar: true });
  printRunning('Repair complete.');
  printFollowUps();
}

async function cmdUninstall() {
  if (ui.isInteractive() && !(await prompt.confirm(
    'Stop NeoRecall and stop it starting with your computer? Your memories stay.',
    { initial: false },
  ))) {
    return;
  }
  await stopAndWait();
  if (fs.existsSync(PLIST_DST)) fs.rmSync(PLIST_DST, { force: true });
  if (fs.existsSync(SYSTEMD_UNIT)) {
    runQuiet('systemctl', ['--user', 'disable', 'neorecall.service']);
    fs.rmSync(SYSTEMD_UNIT, { force: true });
    runQuiet('systemctl', ['--user', 'daemon-reload']);
  }
  logOk('NeoRecall no longer starts with your computer');
  ui.note(`Your memories and settings are still in ${RUNTIME_HOME}. Turn it back on with ${ui.paint.command('neorecall install')}.`);
}

async function promptPassword() {
  if (!ui.isInteractive()) {
    throw new Error('Enter a password on a TTY, or pass --password-file PATH.');
  }
  return (await prompt.askSecret('New password (at least 12 characters)')).trim();
}

async function resetPassword(account, password) {
  if (!account) {
    throw new Error('Usage: neorecall reset-password <username-or-email> [--password-file PATH]');
  }
  if (!password || password.length < 12) {
    throw new Error('Password must be at least 12 characters.');
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
  logOk(`New password set for ${user.username}; they are signed out everywhere.`);
}

async function runCLI(argv) {
  const [command = '', ...args] = argv;
  switch (command) {
    case '':
      return cmdHome();
    case 'help':
    case '--help':
    case '-h':
      printHelp({ all: args.includes('--all') });
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
      return cmdStatus(args);
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
    case 'admin':
      return cmdAdmin(args);
    case 'backup':
      return args[0] === 'list'
        ? require('./backup_cli').cmdBackupList()
        : require('./backup_cli').cmdBackup();
    case 'restore':
      return require('./backup_cli').cmdRestore(args);
    case 'reset-password': {
      const fileIdx = args.indexOf('--password-file');
      let password;
      const positional = args.filter((arg, index) => arg !== '--password-file' && index !== fileIdx + 1);
      const account = positional[0];
      if (fileIdx >= 0) {
        const file = args[fileIdx + 1];
        if (!file) throw new Error('Usage: neorecall reset-password <user> --password-file PATH');
        password = fs.readFileSync(file, 'utf8').replace(/\r?\n$/, '');
      } else if (positional[1]) {
        password = positional[1];
      } else {
        password = await promptPassword();
      }
      return resetPassword(account, password);
    }
    case 'version':
    case '--version':
    case '-V':
    case '-v':
      return cmdVersion();
    default:
      throw new Error(`"${command}" isn't a neorecall command. Run \`neorecall help\` to see what you can do.`);
  }
}

module.exports = {
  runCLI,
  cmdAdmin,
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
