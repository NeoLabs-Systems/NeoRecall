'use strict';

const express = require('express');
const { z } = require('zod');
const { requireAuth, requireSession } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');
const accounts = require('../services/cloud/cloud_account_service');
const loginFlow = require('../services/cloud/nextcloud_login_flow');
const archive = require('../services/cloud/archive_service');

const router = express.Router();
router.use(requireAuth, requireSession);

function statusPayload(userId) {
  const pending = loginFlow.publicPending(userId);
  if (pending) return pending;
  return accounts.publicAccount(userId);
}

router.get('/', (req, res) => res.json({ cloud: statusPayload(req.auth.userId) }));

router.post('/nextcloud/login', validate(z.object({
  instanceUrl: z.string().min(1).max(500),
})), asyncRoute(async (req, res) => {
  const started = await loginFlow.start(req.auth.userId, req.body.instanceUrl);
  res.json({ cloud: started });
}));

router.post('/nextcloud/poll', asyncRoute(async (req, res) => {
  const result = await loginFlow.poll(req.auth.userId);
  if (!result) {
    res.json({ cloud: statusPayload(req.auth.userId) });
    return;
  }
  if (result.status === 'connected') {
    accounts.upsertConnected(req.auth.userId, {
      baseUrl: result.baseUrl,
      username: result.username,
      appPassword: result.appPassword,
    });
  }
  res.json({ cloud: statusPayload(req.auth.userId) });
}));

router.patch('/', validate(z.object({
  audioEnabled: z.boolean().optional(),
  dataBackupEnabled: z.boolean().optional(),
  folder: z.string().min(1).max(64).optional(),
})), (req, res) => {
  res.json({ cloud: accounts.update(req.auth.userId, req.body) });
});

router.post('/backup', asyncRoute(async (req, res) => {
  const account = accounts.get(req.auth.userId);
  if (!account) {
    res.status(404).json({ error: { code: 'CLOUD_NOT_CONNECTED', message: 'Connect a Nextcloud instance first.' } });
    return;
  }
  archive.enqueueDataBackup(req.auth.userId, 'manual');
  res.json({ cloud: statusPayload(req.auth.userId), queued: true });
}));

router.delete('/', (req, res) => {
  loginFlow.cancel(req.auth.userId);
  accounts.disconnect(req.auth.userId);
  res.status(204).end();
});

module.exports = router;
