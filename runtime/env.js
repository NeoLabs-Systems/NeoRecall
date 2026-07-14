'use strict';

const fs = require('node:fs');
const dotenv = require('dotenv');
const { paths } = require('./paths');

function loadEnvironment() {
  const envFile = paths().envFile;
  if (fs.existsSync(envFile)) dotenv.config({ path: envFile, override: false });
  dotenv.config({ override: false, quiet: true });
}

module.exports = { loadEnvironment };
