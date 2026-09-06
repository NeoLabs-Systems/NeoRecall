'use strict';
// Starts a real NeoRecall server on an ephemeral port and provisions an account
// with an ingest API key, then writes one line of JSON describing how to reach
// it to the file given as the second argument.
//
// A file rather than stdout: the server logs its migrations there, and a
// handshake that has to be fished out of a log is a handshake that breaks the
// first time somebody adds a log line.
//
// This exists so the appliance's upload pump can be exercised against the actual
// server rather than a hand-written stand-in. A fake agrees with whatever the
// client does; the real routes do not, and the appliance's whole reason to exist
// is that it speaks this protocol correctly.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-desk-it-'));

const { createApp } = require(path.join(process.argv[2], 'server', 'app'));
const app = createApp();

const server = app.listen(0, '127.0.0.1', async () => {
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const username = `desk-${crypto.randomBytes(4).toString('hex')}`;
  const password = 'a long and unique password';

  const post = async (route, body, token) => {
    const response = await fetch(base + route, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      throw new Error(`${route} -> ${response.status} ${await response.text()}`);
    }
    return response.json();
  };

  try {
    const account = await post('/api/v1/auth/register', { username, password });
    const key = await post(
      '/api/v1/api-keys',
      { name: 'NeoRecall Desk', scopes: ['ingest:write', 'devices:read', 'devices:write'] },
      account.session.token,
    );
    fs.writeFileSync(
      process.argv[3],
      JSON.stringify({ baseUrl: base, apiKey: key.token, home: process.env.NEORECALL_HOME }),
    );
  } catch (error) {
    process.stderr.write(String(error && error.stack ? error.stack : error) + '\n');
    process.exit(1);
  }
});

const shutdown = () => {
  server.close(() => {
    fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
    process.exit(0);
  });
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
