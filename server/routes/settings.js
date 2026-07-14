'use strict';

const express = require('express');
const service = require('../services/settings/settings_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('settings:read'), (req, res) => res.json({ settings: service.get(req.auth.userId) }));
router.put('/', requireScope('settings:write'), (req, res, next) => { try { res.json({ settings: service.update(req.auth.userId, req.body) }); } catch (error) { next(error); } });
module.exports = router;
