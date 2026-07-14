#!/usr/bin/env node
'use strict';

require('../runtime/env').loadEnvironment();
const manager = require('../lib/manager');
const pkg = require('../package.json');

async function main() {
  const [command = 'help', ...args] = process.argv.slice(2);
  if (command === 'install') return manager.install();
  if (command === 'setup') return manager.setup({ skipModels: args.includes('--skip-models') });
  if (command === 'start') return manager.start();
  if (command === 'stop') return manager.stop();
  if (command === 'status') return manager.status();
  if (command === 'logs') return manager.logs();
  if (command === 'update') return manager.update(args[0]);
  if (command === 'channel') return manager.update(args[0] || 'stable');
  if (command === 'env') return process.stdout.write(`${require('../runtime/paths').ensureRuntimeDirs().envFile}\n`);
  if (command === 'version' || command === '--version' || command === '-v') return process.stdout.write(`${pkg.version}\n`);
  if (command === 'reset-password') return manager.resetPassword(args[0], args[1]);
  process.stdout.write(`NeoRecall ${pkg.version}\n\nCommands:\n  install\n  setup [--skip-models]\n  start\n  stop\n  status\n  logs\n  channel <stable|beta>\n  update [stable|beta]\n  env\n  reset-password <account> <new-password>\n  version\n`);
}

main().catch((error) => { process.stderr.write(`NeoRecall: ${error.message}\n`); process.exitCode = 1; });
