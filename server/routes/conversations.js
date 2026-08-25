'use strict';

const express = require('express');
const service = require('../services/conversations/conversation_service');
const timeline = require('../services/conversations/timeline_service');
const reprocess = require('../services/conversations/conversation_reprocess_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('recordings:read'), (req, res) => res.json(service.list(req.auth.userId, req.query)));
// The timeline reads as moments: one conversation with everything said in it.
router.get('/timeline', requireScope('recordings:read'), (req, res) => res.json(timeline.list(req.auth.userId, req.query)));
// Everything said in one moment, fetched when a reader opens it rather than
// carried in every timeline refresh.
router.get('/:id/segments', requireScope('recordings:read'), (req, res, next) => {
  try { res.json(timeline.segments(req.auth.userId, req.params.id)); } catch (error) { next(error); }
});
router.post('/:id/reprocess', requireScope('memories:write'), (req, res, next) => {
  try { res.status(202).json(reprocess.reprocess(req.auth.userId, req.params.id)); } catch (error) { next(error); }
});
router.get('/:id', requireScope('recordings:read'), (req, res, next) => { try { res.json(service.get(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
module.exports = router;
