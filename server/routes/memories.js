'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/memories/memory_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');

const router = express.Router();
router.use(requireAuth);

router.get('/', requireScope('memories:read'), (req, res) => res.json(service.list(req.auth.userId, req.query)));
router.get('/daily-summaries', requireScope('memories:read'), (req, res) => res.json(service.dailySummaries(req.auth.userId, req.query)));
router.get('/mini', requireScope('memories:read'), (req, res) => res.json(service.listMini(req.auth.userId, req.query)));

router.post('/bulk', requireScope('memories:write'), validate(z.object({
  ids: z.array(z.string().min(1)).min(1).max(100),
  action: z.enum(['delete', 'pin', 'unpin', 'archive', 'unarchive']),
})), (req, res) => {
  res.json(service.bulk(req.auth.userId, req.body));
});

router.post('/merge', requireScope('memories:write'), validate(z.object({
  // Count validation belongs to the service so callers receive its actionable
  // limit message instead of the validation middleware's generic response.
  ids: z.array(z.string().min(1)),
})), asyncRoute(async (req, res) => {
  res.json(await service.merge(req.auth.userId, req.body));
}));

router.patch('/mini/:id', requireScope('memories:write'), validate(z.object({
  status: z.enum(['open', 'completed', 'cancelled']).optional(),
  importanceOverride: z.number().min(1).max(10).nullable().optional(),
})), (req, res) => {
  res.json(service.updateMini(req.auth.userId, req.params.id, req.body));
});
router.delete('/mini/:id', requireScope('memories:write'), (req, res) => {
  service.removeMini(req.auth.userId, req.params.id); res.status(204).end();
});

router.get('/:id', requireScope('memories:read'), (req, res) => {
  res.json(service.memoryDetail(req.auth.userId, req.params.id));
});
router.patch('/:id', requireScope('memories:write'), validate(z.object({
  type: z.string().optional(),
  titleEn: z.string().min(1).max(160).optional(),
  emoji: z.string().min(1).max(16).optional(),
  importanceOverride: z.number().min(1).max(10).nullable().optional(),
  pinned: z.boolean().optional(),
  archived: z.boolean().optional(),
})), (req, res) => {
  res.json(service.update(req.auth.userId, req.params.id, req.body));
});
router.delete('/:id', requireScope('memories:write'), (req, res) => {
  service.remove(req.auth.userId, req.params.id); res.status(204).end();
});

module.exports = router;
