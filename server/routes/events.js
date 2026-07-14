'use strict';

const express = require('express');
const { requireAuth, requireScope } = require('../middleware/auth');
const { getDatabase } = require('../db/database');

const router = express.Router();
router.use(requireAuth, requireScope('recordings:read'));
router.get('/', (req, res) => {
  res.status(200);
  res.set({ 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
  res.flushHeaders();
  let lastId = Number(req.get('Last-Event-ID') || req.query.after || 0);
  if (!Number.isSafeInteger(lastId) || lastId < 0) lastId = 0;
  const poll = () => {
    const rows = getDatabase().prepare(`SELECT * FROM event_outbox WHERE user_id=? AND id>? AND expires_at>?
      ORDER BY id LIMIT 100`).all(req.auth.userId, lastId, new Date().toISOString());
    for (const row of rows) {
      res.write(`id: ${row.id}\nevent: ${row.event_type}\ndata: ${row.payload_json}\n\n`);
      lastId = row.id;
    }
  };
  poll();
  const timer = setInterval(() => { res.write(': keepalive\n\n'); poll(); }, 15_000);
  req.on('close', () => clearInterval(timer));
});
module.exports = router;
