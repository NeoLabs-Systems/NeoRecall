'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function collect(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const filename = path.join(directory, entry.name);
    if (entry.isDirectory()) return collect(filename);
    return entry.isFile() && entry.name.endsWith('.test.js') ? [filename] : [];
  });
}

const files = collect(path.join(__dirname, '..', 'test'));
if (!files.length) throw new Error('No backend tests were found.');
const result = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit', env: { ...process.env, NODE_ENV: 'test' } });
process.exitCode = result.status ?? 1;
