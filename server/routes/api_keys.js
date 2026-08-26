'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/auth/api_key_service');
const { requireAuth, requireSession } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { HttpError } = require('../middleware/error_handler');

const router = express.Router();
router.use(requireAuth);
router.get('/', requireSession, (req, res) => res.json({ apiKeys: service.list(req.auth.userId) }));
router.post('/', requireSession, validate(z.object({ name: z.string().min(1).max(100), scopes: z.array(z.string()).min(1), expiresAt: z.string().datetime().optional().nullable() })),
  (req, res) => res.status(201).json(service.create(req.auth.userId, req.body)));

// Registered before '/:id' so an API key can revoke itself (e.g. during on-device
// sign-out) without an interactive session, which '/:id' requires.
router.delete('/self', (req, res, next) => {
  try {
    if (req.auth.type !== 'api_key') throw new HttpError(400, 'NOT_AN_API_KEY', 'This operation requires an API key, not a session.');
    service.revoke(req.auth.userId, req.auth.apiKeyId);
    res.status(204).end();
  } catch (error) { next(error); }
});

router.delete('/:id', requireSession, (req, res, next) => { try { service.revoke(req.auth.userId, req.params.id); res.status(204).end(); } catch (error) { next(error); } });
module.exports = router;
