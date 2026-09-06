'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const Database = require('better-sqlite3');

const repoRoot = path.join(__dirname, '..', '..');

function migrateProcess(home) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', `
      process.env.NEORECALL_HOME = ${JSON.stringify(home)};
      process.env.NODE_ENV = 'test';
      process.env.NEORECALL_REQUIRE_VECTOR = 'false';
      require(${JSON.stringify(path.join(repoRoot, 'server/db/migrate'))}).migrate();
    `], { cwd: repoRoot, stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('exit', (code) => {
      if (code === 0) resolve();
      else reject(new Error(stderr || `migrate exited ${code}`));
    });
  });
}

test('two processes can migrate a fresh database without colliding', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-migrate-lock-'));
  require('../../runtime/paths').ensureRuntimeDirs({ NEORECALL_HOME: home });
  try {
    await Promise.all([migrateProcess(home), migrateProcess(home)]);
    const db = new Database(path.join(home, 'data', 'neorecall.sqlite3'));
    const versions = db.prepare('SELECT version FROM schema_migrations ORDER BY version').all().map((row) => row.version);
    const unique = new Set(versions);
    assert.equal(unique.size, versions.length, 'each migration version is recorded once');
    assert.ok(versions.length > 0);
    db.close();
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
