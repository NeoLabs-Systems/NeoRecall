'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/auth/api_key_service');
const { requireAuth, requireSession } = require('../middleware/auth');
const { validate } = require('../middleware/validate');

const router = express.Router();
router.use(requireAuth, requireSession);
router.get('/', (req, res) => res.json({ apiKeys: service.list(req.auth.userId) }));
router.post('/', validate(z.object({ name: z.string().min(1).max(100), scopes: z.array(z.string()).min(1), expiresAt: z.string().datetime().optional().nullable() })),
  (req, res) => res.status(201).json(service.create(req.auth.userId, req.body)));
router.delete('/:id', (req, res, next) => { try { service.revoke(req.auth.userId, req.params.id); res.status(204).end(); } catch (error) { next(error); } });
module.exports = router;
