'use strict';

const express = require('express');
const { z } = require('zod');
const service = require('../services/memories/memory_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('memories:read'), (req, res) => res.json(service.listMini(req.auth.userId, req.query)));
router.patch('/:id', requireScope('memories:write'), validate(z.object({ status: z.enum(['open', 'completed', 'cancelled']).optional(), importanceOverride: z.number().min(1).max(10).nullable().optional() })),
  (req, res, next) => { try { res.json(service.updateMini(req.auth.userId, req.params.id, req.body)); } catch (error) { next(error); } });
router.delete('/:id', requireScope('memories:write'), (req, res, next) => { try { service.removeMini(req.auth.userId, req.params.id); res.status(204).end(); } catch (error) { next(error); } });
module.exports = router;
