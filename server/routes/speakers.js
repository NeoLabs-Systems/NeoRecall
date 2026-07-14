'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/speakers/speaker_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('speakers:read'), (req, res) => res.json({ speakers: service.list(req.auth.userId) }));
router.patch('/:id', requireScope('speakers:write'), validate(z.object({ displayName: z.string().min(1).max(120).nullable().optional(), matchingEnabled: z.boolean().optional() })),
  (req, res, next) => { try { res.json(service.update(req.auth.userId, req.params.id, req.body)); } catch (error) { next(error); } });
router.post('/:id/merge', requireScope('speakers:write'), validate(z.object({ sourceId: z.string().uuid() })),
  (req, res, next) => { try { res.json(service.merge(req.auth.userId, req.params.id, req.body.sourceId)); } catch (error) { next(error); } });
router.post('/:id/assignments', requireScope('speakers:write'), validate(z.object({ turnIds: z.array(z.string().uuid()).min(1).max(1000) })),
  (req, res, next) => { try { res.json(service.assign(req.auth.userId, req.params.id, req.body.turnIds)); } catch (error) { next(error); } });
module.exports = router;
