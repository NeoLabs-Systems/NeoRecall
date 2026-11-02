'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-unit-'));
const { renderSystemdUnit } = require('../../lib/manager');

test.after(() => fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }));

// systemd refuses a unit with a quoted WorkingDirectory= ("path is not
// absolute") and skips a quoted EnvironmentFile=.
test('the systemd unit only quotes the settings that unquote their values', () => {
  const lines = renderSystemdUnit().split('\n');
  const value = (key) => lines.find((line) => line.startsWith(`${key}=`)).slice(key.length + 1);
  assert.match(value('WorkingDirectory'), /^\//);
  assert.match(value('EnvironmentFile'), /^-\//);
  assert.match(value('StandardOutput'), /^append:\//);
  assert.match(value('ExecStart'), /^"\/.+" "\/.+index\.js"$/);
  assert.ok(lines.includes(`Environment="NEORECALL_HOME=${process.env.NEORECALL_HOME}"`));
});
