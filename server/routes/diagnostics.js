'use strict';

const express = require('express');
const { requireAuth, requireSession } = require('../middleware/auth');
const diagnostics = require('../services/diagnostics/diagnostic_service');

const router = express.Router();
router.use(requireAuth, requireSession);
router.get('/export', (req, res) => res.json(diagnostics.exportForUser(req.auth.userId)));

module.exports = router;
