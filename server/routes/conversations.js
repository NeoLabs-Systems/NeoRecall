'use strict';

const express = require('express');
const service = require('../services/conversations/conversation_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth, requireScope('recordings:read'));
router.get('/', (req, res) => res.json(service.list(req.auth.userId, req.query)));
router.get('/:id', (req, res, next) => { try { res.json(service.get(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
module.exports = router;
