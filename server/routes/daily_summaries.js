'use strict';

const express = require('express');
const service = require('../services/memories/memory_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth, requireScope('memories:read'));
router.get('/', (req, res) => res.json(service.dailySummaries(req.auth.userId, req.query)));
module.exports = router;
