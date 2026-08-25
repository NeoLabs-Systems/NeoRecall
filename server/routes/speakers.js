'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/speakers/speaker_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { HttpError } = require('../middleware/error_handler');
const previews = require('../services/speakers/speaker_preview_service');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('speakers:read'), (req, res) => res.json({ speakers: service.list(req.auth.userId) }));
router.get('/:id/preview', requireScope('speakers:read'), (req, res, next) => {
  try {
    const preview = previews.get(req.auth.userId, req.params.id);
    if (!preview) throw new HttpError(404, 'NOT_FOUND', 'Speaker preview not found.');
    res.set({
      'Content-Type': preview.content_type,
      'Content-Length': preview.audio.length,
      'Cache-Control': 'private, no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    res.send(preview.audio);
  } catch (error) {
    next(error);
  }
});
router.patch('/:id', requireScope('speakers:write'), validate(z.object({ displayName: z.string().min(1).max(120).nullable().optional(), matchingEnabled: z.boolean().optional() })),
  (req, res, next) => { try { res.json(service.update(req.auth.userId, req.params.id, req.body)); } catch (error) { next(error); } });
router.post('/:id/merge', requireScope('speakers:write'), validate(z.object({ sourceId: z.string().uuid() })),
  (req, res, next) => { try { res.json(service.merge(req.auth.userId, req.params.id, req.body.sourceId)); } catch (error) { next(error); } });
router.post('/merge', requireScope('speakers:write'), validate(z.object({
  targetId: z.string().uuid(),
  sourceIds: z.array(z.string().uuid()).min(1).max(20),
})), (req, res, next) => {
  try { res.json(service.mergeMany(req.auth.userId, req.body.targetId, req.body.sourceIds)); } catch (error) { next(error); }
});
router.post('/bulk', requireScope('speakers:write'), validate(z.object({
  ids: z.array(z.string().uuid()).min(1).max(100),
  action: z.enum(['delete']),
})), (req, res, next) => {
  try { res.json(service.bulkRemove(req.auth.userId, req.body.ids)); } catch (error) { next(error); }
});
router.post('/:id/assignments', requireScope('speakers:write'), validate(z.object({ turnIds: z.array(z.string().uuid()).min(1).max(1000) })),
  (req, res, next) => { try { res.json(service.assign(req.auth.userId, req.params.id, req.body.turnIds)); } catch (error) { next(error); } });
router.delete('/:id', requireScope('speakers:write'),
  (req, res, next) => { try { res.json(service.remove(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
module.exports = router;
