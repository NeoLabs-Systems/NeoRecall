#!/usr/bin/env node

const { runCLI } = require('../lib/manager');
const { printError } = require('../lib/cli/errors');

runCLI(process.argv.slice(2)).catch((err) => {
  printError(err, { details: process.argv.includes('--details') });
  process.exit(1);
});
