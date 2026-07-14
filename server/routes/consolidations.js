'use strict';

const express = require('express');
const service = require('../services/memories/consolidation_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth, requireScope('memories:write'));
router.post('/', (req, res, next) => { try { res.status(202).json(service.request(req.auth.userId, { manual: true })); } catch (error) { next(error); } });
router.get('/latest', (req, res) => res.json(service.latest(req.auth.userId)));
module.exports = router;
