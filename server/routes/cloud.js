'use strict';

const express = require('express');
const { z } = require('zod');
const { requireAuth, requireSession } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');
const accounts = require('../services/cloud/cloud_account_service');
const loginFlow = require('../services/cloud/nextcloud_login_flow');
const neocloudLogin = require('../services/cloud/neocloud_device_login');
const archive = require('../services/cloud/archive_service');

const router = express.Router();
router.use(requireAuth, requireSession);

function statusPayload(userId) {
  const pending = loginFlow.publicPending(userId) || neocloudLogin.publicPending(userId);
  if (pending) return pending;
  return accounts.publicAccount(userId);
}

// Only one sign-in can be open per user: starting one closes the other.
function cancelLogins(userId) {
  loginFlow.cancel(userId);
  neocloudLogin.cancel(userId);
}

const instanceBody = z.object({ instanceUrl: z.string().min(1).max(500) });

router.get('/', (req, res) => res.json({ cloud: statusPayload(req.auth.userId) }));

router.post('/nextcloud/login', validate(instanceBody), asyncRoute(async (req, res) => {
  cancelLogins(req.auth.userId);
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
      type: 'nextcloud',
      baseUrl: result.baseUrl,
      username: result.username,
      appPassword: result.appPassword,
    });
  }
  res.json({ cloud: statusPayload(req.auth.userId) });
}));

router.post('/neocloud/login', validate(instanceBody), asyncRoute(async (req, res) => {
  cancelLogins(req.auth.userId);
  const started = await neocloudLogin.start(req.auth.userId, req.body.instanceUrl);
  res.json({ cloud: started });
}));

router.post('/neocloud/poll', asyncRoute(async (req, res) => {
  const result = await neocloudLogin.poll(req.auth.userId);
  if (!result) {
    res.json({ cloud: statusPayload(req.auth.userId) });
    return;
  }
  if (result.status === 'connected') await accounts.connectNeoCloud(req.auth.userId, result);
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
    res.status(404).json({ error: { code: 'CLOUD_NOT_CONNECTED', message: 'Connect a cloud backup first.' } });
    return;
  }
  archive.enqueueDataBackup(req.auth.userId, 'manual');
  res.json({ cloud: statusPayload(req.auth.userId), queued: true });
}));

router.delete('/', (req, res) => {
  cancelLogins(req.auth.userId);
  accounts.disconnect(req.auth.userId);
  res.status(204).end();
});

module.exports = router;
