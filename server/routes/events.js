'use strict';

const express = require('express');
const { requireAuth, requireScope } = require('../middleware/auth');
const { getConfig } = require('../config');
const events = require('../services/events/event_outbox_service');

const router = express.Router();
router.use(requireAuth, requireScope('recordings:read'));
router.get('/', (req, res) => {
  res.status(200);
  res.set({ 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
  res.flushHeaders();
  let lastId = Number(req.get('Last-Event-ID') || req.query.after || 0);
  if (!Number.isSafeInteger(lastId) || lastId < 0) lastId = 0;
  const poll = () => {
    const rows = events.pollAfter(req.auth.userId, lastId);
    for (const row of rows) {
      res.write(`id: ${row.id}\nevent: ${row.event_type}\ndata: ${row.payload_json}\n\n`);
      lastId = row.id;
    }
  };
  poll();
  const timer = setInterval(() => { res.write(': keepalive\n\n'); poll(); }, getConfig().eventOutboxKeepaliveMs);
  req.on('close', () => clearInterval(timer));
});
module.exports = router;
