// Boots a real NeoRecall backend on an ephemeral port for the appliance's
// integration test.
//
// The appliance's whole claim is that it needs no server feature of its own — it
// speaks the same ingest protocol as every other client. That claim is only
// worth anything if it is checked against the real thing: a stub server would
// happily accept headers the real one rejects, which is exactly the class of
// mistake that costs a bring-up evening rather than a test run.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-desk-it-'));

const { createApp } = require('../../../../server/app');

const app = createApp();
const server = app.listen(0, '127.0.0.1', () => {
  // The test reads this line to learn where to connect.
  process.stdout.write(`LISTENING ${server.address().port}\n`);
});

function shutdown() {
  server.close(() => {
    try {
      const { closeDatabase } = require('../../../../server/db/database');
      closeDatabase();
    } catch {
      // Already closed; nothing to do.
    }
    fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
    process.exit(0);
  });
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
