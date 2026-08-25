'use strict';

const express = require('express');
const { z } = require('zod');
const sources = require('../services/sources');
const { requireAuth } = require('../middleware/auth');
const { validate } = require('../middleware/validate');

const router = express.Router();

const pairingService = require('../services/sources/pairing_service');

const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);

// Public endpoint for the Discord JS snippet
router.post('/discord/pair', express.json(), (req, res, next) => {
  try {
    const { pairingToken, discordToken } = req.body;
    if (!pairingToken || !discordToken) {
      return res.status(400).json({ error: 'Missing tokens' });
    }
    pairingService.consumePairing(pairingToken, discordToken);
    res.json({ success: true });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

router.use(requireAuth);

router.post('/discord/pairing', (req, res) => {
  try {
    const token = pairingService.createPairing(req.auth.userId, req.body);
    res.json({ pairingToken: token });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

router.get('/discord/pairing/:token/status', (req, res) => {
  res.json(pairingService.getPairingStatus(req.params.token));
});

// Which source types this build can run, so the client offers only real ones.
router.get('/types', (req, res) => res.json({ types: sources.availableTypes() }));

const verifySchema = z.object({
  type: z.string().min(1),
  config: z.record(z.unknown()),
});

// Checks credentials before a source is stored, so a bad token surfaces in the
// setup dialog instead of as a silent background failure later. Types that need
// no verification simply report ok.
router.post('/verify', validate(verifySchema), async (req, res) => {
  try {
    const result = await sources.verifyConfig(req.body.type, req.body.config);
    res.json({ ok: true, ...result });
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message });
  }
});

const createSchema = z.object({
  type: z.string().min(1),
  name: z.string().min(1).max(100),
  config: z.record(z.unknown()).optional(),
  enabled: z.boolean().optional(),
});

const updateSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  config: z.record(z.unknown()).optional(),
  enabled: z.boolean().optional(),
});

router.get('/', (req, res) => res.json({ sources: sources.list(req.auth.userId) }));

router.post('/', validate(createSchema), asyncRoute(async (req, res) => {
  res.status(201).json(sources.create(req.auth.userId, req.body));
}));

router.get('/:id', (req, res, next) => {
  try {
    res.json(sources.getPublic(req.auth.userId, req.params.id));
  } catch (error) {
    next(error);
  }
});

router.patch('/:id', validate(updateSchema), (req, res, next) => {
  try {
    res.json(sources.update(req.auth.userId, req.params.id, req.body));
  } catch (error) {
    next(error);
  }
});

router.delete('/:id', (req, res, next) => {
  try {
    sources.delete(req.auth.userId, req.params.id);
    res.status(204).end();
  } catch (error) {
    next(error);
  }
});

router.post('/:id/sync', asyncRoute(async (req, res) => {
  res.json(await sources.syncNow(req.auth.userId, req.params.id));
}));

module.exports = router;
