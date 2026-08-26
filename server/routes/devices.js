'use strict';

const express = require('express');
const { z } = require('zod');
const devices = require('../services/devices/device_service');
const { requireAuth, requireScope, requireAnyScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');

const router = express.Router();
router.use(requireAuth);
const deviceSchema = z.object({
  id: z.string().uuid().optional(), clientUuid: z.string().min(8).max(128), name: z.string().min(1).max(100), platform: z.string().min(1).max(40),
  kind: z.enum(['browser', 'desktop', 'mobile', 'import', 'wearable', 'appliance']), capabilities: z.record(z.unknown()).optional(),
});
router.get('/', requireScope('devices:read'), (req, res) => res.json({ devices: devices.list(req.auth.userId) }));
router.post('/', requireAnyScope('devices:write', 'ingest:write'), validate(deviceSchema), (req, res) => res.status(201).json(devices.register(req.auth.userId, req.body)));
router.get('/:id', requireScope('devices:read'), (req, res) => { res.json(devices.get(req.auth.userId, req.params.id)); });
router.patch('/:id', requireScope('devices:write'), validate(z.object({ name: z.string().min(1).max(100) })), (req, res) => { res.json(devices.rename(req.auth.userId, req.params.id, req.body.name)); });
router.delete('/:id', requireScope('devices:write'), (req, res) => { devices.revoke(req.auth.userId, req.params.id); res.status(204).end(); });
router.post('/:id/heartbeat', requireAnyScope('devices:write', 'ingest:write'), validate(z.object({ clientSentAt: z.string().datetime(), clockOffsetMs: z.number().optional(), clockRttMs: z.number().nonnegative().optional() })),
  (req, res) => { res.json(devices.heartbeat(req.auth.userId, req.params.id, req.body)); });
module.exports = router;
