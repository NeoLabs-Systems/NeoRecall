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

// `node --test` defaults to one worker per core, and each of these files stands
// up an Express app, runs every migration, and talks to it over a real socket.
// At ten workers the machine saturates and tests start failing on timing rather
// than on behaviour — observed as `socket hang up` in the ingest suite and as a
// lost race in the migration-lock suite, on roughly one run in six. Four workers
// cost about four seconds and made twelve consecutive runs clean.
//
// Raise it on a machine with headroom; a green suite is worth more than the
// seconds, because a suite that fails at random teaches people to re-run it
// instead of reading it.
const concurrency = process.env.NEORECALL_TEST_CONCURRENCY || '4';
const result = spawnSync(
  process.execPath,
  ['--test', `--test-concurrency=${concurrency}`, ...files],
  { stdio: 'inherit', env: { ...process.env, NODE_ENV: 'test' } },
);
process.exitCode = result.status ?? 1;
