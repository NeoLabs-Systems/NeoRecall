#!/usr/bin/env node
'use strict';

// Drive the in-app Memoket Gem hardware probe over ADB and wait for its report.
//
// The Gem must be powered on, in range, and preferably already bonded to the
// phone. Scan-only discovery usually fails: a Gem that is (or just was) an LE
// client does not advertise. The in-app probe reconnects by deviceKey.
// Force-stop the official Memoket app so it cannot hold the GATT link.
// Default live soak is 120 seconds.

const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PACKAGE = 'systems.neolabs.neorecall';
const ACTIVITY = `${PACKAGE}/.MainActivity`;
const ACTION = 'systems.neolabs.neorecall.MEMOKET_E2E';
const DEVICE_DIR = `/sdcard/Android/data/${PACKAGE}/files`;
const STATUS_REMOTE = `${DEVICE_DIR}/memoket_e2e_status.json`;
const REPORT_REMOTE = `${DEVICE_DIR}/memoket_e2e_report.json`;
const liveMs = Number(process.env.NEORECALL_MEMOKET_E2E_LIVE_MS || 120000);
const extraMs = 8 * 60_000;
const timeoutMs = Number(process.env.NEORECALL_MEMOKET_E2E_TIMEOUT_MS || liveMs * 2 + extraMs);

function adb(args, opts = {}) {
  return execFileSync('adb', args, { encoding: 'utf8', ...opts });
}

function pullJson(remote) {
  try {
    const text = adb(['shell', 'cat', remote], { stdio: ['ignore', 'pipe', 'pipe'] });
    if (!text || text.includes('No such file')) return null;
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function main() {
  const devices = adb(['devices', '-l']).trim().split('\n').slice(1).filter(Boolean);
  if (devices.length === 0) {
    throw new Error('No Android device is connected over ADB.');
  }
  console.log(`[memoket-e2e] device ${devices[0]}`);

  for (const perm of [
    'android.permission.BLUETOOTH_CONNECT',
    'android.permission.BLUETOOTH_SCAN',
    'android.permission.RECORD_AUDIO',
    'android.permission.POST_NOTIFICATIONS',
  ]) {
    try {
      adb(['shell', 'pm', 'grant', PACKAGE, perm]);
    } catch {
      // Older images reject grants they do not declare.
    }
  }

  try {
    adb(['shell', 'am', 'force-stop', 'com.ssheng.memoket']);
  } catch {
    // Official app may not be installed.
  }
  adb(['shell', 'svc', 'power', 'stayon', 'usb']);
  adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);

  try {
    adb(['shell', 'rm', '-f', STATUS_REMOTE, REPORT_REMOTE]);
  } catch {
    // First run has no previous report.
  }

  adb(['shell', 'am', 'force-stop', PACKAGE]);
  const startArgs = [
    'shell', 'am', 'start',
    '-n', ACTIVITY,
    '-a', ACTION,
    '--ei', 'systems.neolabs.neorecall.E2E_LIVE_MS', String(liveMs),
  ];
  console.log(`[memoket-e2e] ${startArgs.join(' ')}`);
  console.log(adb(startArgs));

  const logcat = spawn('adb', ['logcat', '-s', 'NeoRecallMemoketE2E:I', 'flutter:I'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  logcat.stdout.on('data', (chunk) => process.stdout.write(chunk));
  logcat.stderr.on('data', (chunk) => process.stderr.write(chunk));

  const started = Date.now();
  let lastStep = '';
  while (Date.now() - started < timeoutMs) {
    const status = pullJson(STATUS_REMOTE) || pullJson(REPORT_REMOTE);
    if (status) {
      const steps = Array.isArray(status.steps) ? status.steps : [];
      const latest = steps.length ? steps[steps.length - 1].name : 'starting';
      if (latest !== lastStep) {
        lastStep = latest;
        console.log(`[memoket-e2e] ${status.running ? 'running' : 'done'} step=${latest} passed=${status.passed}`);
      }
      if (status.running === false && status.finishedAt) {
        logcat.kill();
        const outDir = path.resolve(process.env.NEORECALL_MEMOKET_E2E_OUT || path.join(process.cwd(), 'tmp'));
        fs.mkdirSync(outDir, { recursive: true });
        const outFile = path.join(outDir, 'memoket_e2e_report.json');
        fs.writeFileSync(outFile, `${JSON.stringify(status, null, 2)}\n`);
        console.log(`[memoket-e2e] report ${outFile}`);
        if (!status.passed) {
          console.error('[memoket-e2e] FAILED');
          process.exit(1);
        }
        console.log('[memoket-e2e] PASSED');
        return;
      }
    }
    execFileSync('sleep', ['3']);
  }
  logcat.kill();
  throw new Error(`Timed out after ${timeoutMs}ms waiting for the Memoket E2E report.`);
}

main();
