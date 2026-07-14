'use strict';

const express = require('express');
const service = require('../services/transcripts/transcript_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth, requireScope('recordings:read'));
router.get('/', (req, res) => res.json(service.list(req.auth.userId, req.query)));
module.exports = router;
