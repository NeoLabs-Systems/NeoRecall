'use strict';

const express = require('express');
const service = require('../services/recordings/recording_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('recordings:read'), (req, res) => res.json(service.list(req.auth.userId, req.query)));
router.get('/:id/transcript', requireScope('recordings:read'), (req, res) => { res.json(service.transcript(req.auth.userId, req.params.id, req.query)); });
router.get('/:id', requireScope('recordings:read'), (req, res) => { res.json(service.get(req.auth.userId, req.params.id)); });
router.delete('/:id', requireScope('recordings:write'), (req, res) => { service.remove(req.auth.userId, req.params.id); res.status(204).end(); });
module.exports = router;
