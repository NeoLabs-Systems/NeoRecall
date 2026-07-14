'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { ensureRuntimeDirs } = require('../runtime/paths');

function xml(value) { return String(value).replace(/[<>&"']/g, (character) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[character])); }
function executable() { return process.execPath; }
function entrypoint() { return path.join(__dirname, '..', 'server', 'index.js'); }

function launchdPath() { return path.join(os.homedir(), 'Library', 'LaunchAgents', 'systems.neolabs.neorecall.plist'); }
function systemdPath() { return path.join(os.homedir(), '.config', 'systemd', 'user', 'neorecall.service'); }

function install() {
  const runtime = ensureRuntimeDirs();
  if (process.platform === 'darwin') {
    fs.mkdirSync(path.dirname(launchdPath()), { recursive: true });
    fs.writeFileSync(launchdPath(), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>Label</key><string>systems.neolabs.neorecall</string><key>ProgramArguments</key><array><string>${xml(executable())}</string><string>${xml(entrypoint())}</string></array>
<key>EnvironmentVariables</key><dict><key>NEORECALL_HOME</key><string>${xml(runtime.home)}</string></dict><key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${xml(path.join(runtime.logs, 'neorecall.log'))}</string><key>StandardErrorPath</key><string>${xml(path.join(runtime.logs, 'neorecall-error.log'))}</string>
</dict></plist>`, { mode: 0o600 });
    return { manager: 'launchd', path: launchdPath() };
  }
  if (process.platform === 'linux') {
    fs.mkdirSync(path.dirname(systemdPath()), { recursive: true });
    fs.writeFileSync(systemdPath(), `[Unit]\nDescription=NeoRecall audio memory service\nAfter=network-online.target\n\n[Service]\nExecStart=${executable()} ${entrypoint()}\nEnvironment=NEORECALL_HOME=${runtime.home}\nRestart=always\nRestartSec=2\nStandardOutput=append:${path.join(runtime.logs, 'neorecall.log')}\nStandardError=append:${path.join(runtime.logs, 'neorecall-error.log')}\n\n[Install]\nWantedBy=default.target\n`, { mode: 0o600 });
    spawnSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'inherit' });
    spawnSync('systemctl', ['--user', 'enable', 'neorecall.service'], { stdio: 'inherit' });
    return { manager: 'systemd', path: systemdPath() };
  }
  return { manager: null, path: null };
}

function installedManager() {
  if (process.platform === 'darwin' && fs.existsSync(launchdPath())) return 'launchd';
  if (process.platform === 'linux' && fs.existsSync(systemdPath())) return 'systemd';
  return null;
}

function start() {
  const manager = installedManager();
  if (manager === 'launchd') {
    spawnSync('launchctl', ['bootout', `gui/${process.getuid()}`, launchdPath()], { stdio: 'ignore' });
    const result = spawnSync('launchctl', ['bootstrap', `gui/${process.getuid()}`, launchdPath()], { stdio: 'inherit' });
    if (result.status) throw new Error('launchctl could not start NeoRecall.');
  } else if (manager === 'systemd') {
    const result = spawnSync('systemctl', ['--user', 'start', 'neorecall.service'], { stdio: 'inherit' });
    if (result.status) throw new Error('systemd could not start NeoRecall.');
  }
  return manager;
}

function stop() {
  const manager = installedManager();
  if (manager === 'launchd') spawnSync('launchctl', ['bootout', `gui/${process.getuid()}`, launchdPath()], { stdio: 'inherit' });
  else if (manager === 'systemd') spawnSync('systemctl', ['--user', 'stop', 'neorecall.service'], { stdio: 'inherit' });
  return manager;
}

function status() {
  const manager = installedManager();
  if (manager === 'launchd') return spawnSync('launchctl', ['print', `gui/${process.getuid()}/systems.neolabs.neorecall`], { encoding: 'utf8' });
  if (manager === 'systemd') return spawnSync('systemctl', ['--user', 'status', 'neorecall.service', '--no-pager'], { encoding: 'utf8' });
  return { status: 1, stdout: 'NeoRecall service is not installed.\n', stderr: '' };
}

module.exports = { install, start, stop, status, installedManager, launchdPath, systemdPath };
