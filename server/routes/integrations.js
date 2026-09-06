'use strict';

const express = require('express');
const { requireAuth, requireSession } = require('../middleware/auth');
const { listUserIntegrations, revokeUserClient } = require('../services/auth/oauth_service');

const router = express.Router();
router.use(requireAuth, requireSession);
router.get('/', (req, res) => res.json({ integrations: listUserIntegrations(req.auth.userId) }));
router.delete('/:clientId', (req, res) => {
  revokeUserClient(req.auth.userId, req.params.clientId);
  res.status(204).end();
});
module.exports = router;
