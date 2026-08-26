'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/memories/memory_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');

const router = express.Router();
router.use(requireAuth);

router.get('/', requireScope('memories:read'), (req, res) => res.json(service.listMini(req.auth.userId, req.query)));
router.get('/:id', requireScope('memories:read'), (req, res) => {
  res.json(service.miniDetail(req.auth.userId, req.params.id));
});
router.patch('/:id', requireScope('memories:write'), validate(z.object({
  status: z.enum(['open', 'completed', 'cancelled']).optional(),
  importanceOverride: z.number().min(1).max(10).nullable().optional(),
})), (req, res) => {
  res.json(service.updateMini(req.auth.userId, req.params.id, req.body));
});
router.delete('/:id', requireScope('memories:write'), (req, res) => {
  service.removeMini(req.auth.userId, req.params.id); res.status(204).end();
});

module.exports = router;
