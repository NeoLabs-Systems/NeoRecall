'use strict';

const express = require('express');
const { z } = require('zod');
const auth = require('../services/auth/admin_auth_service');
const admin = require('../services/admin/admin_service');
const adminTwoFactor = require('../services/auth/admin_two_factor_service');
const audit = require('../services/audit/audit_service');
const processingSettings = require('../services/settings/processing_settings_service');
const providerSettings = require('../services/settings/provider_settings_service');
const backups = require('../services/backup/backup_service');
const { requireAdmin } = require('../middleware/admin_auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');
const { slidingWindow } = require('../middleware/rate_limit');

const router = express.Router();
router.post('/login', slidingWindow({ windowMs: 60_000, limit: 10 }), validate(z.object({ username: z.string().min(1), password: z.string().min(1) })),
  asyncRoute(async (req, res) => res.json(await auth.login(req.body.username, req.body.password, { ipAddress: req.ip, userAgent: req.get('User-Agent') }))));
router.post('/2fa/verify', slidingWindow({ windowMs: 60_000, limit: 10 }), validate(z.object({ username: z.string().min(1), password: z.string().min(1), code: z.string().min(1) })),
  asyncRoute(async (req, res) => res.json(await auth.verifyTwoFactorLogin(req.body.username, req.body.password, req.body.code, { ipAddress: req.ip, userAgent: req.get('User-Agent') }))));
router.post('/login/2fa/setup/enable', slidingWindow({ windowMs: 60_000, limit: 10 }), validate(z.object({ username: z.string().min(1), password: z.string().min(1), code: z.string().min(1) })),
  asyncRoute(async (req, res) => res.json(await auth.setupTwoFactorLogin(req.body.username, req.body.password, req.body.code, { ipAddress: req.ip, userAgent: req.get('User-Agent') }))));
router.use(requireAdmin);
router.post('/logout', (req, res) => { if (req.adminAuth.adminSessionId) auth.logout(req.adminAuth.adminSessionId); res.status(204).end(); });
router.get('/stats', (req, res) => res.json(admin.stats()));
router.get('/users', (req, res) => res.json({ users: admin.users(req.query.limit) }));
router.patch('/users/:id', validate(z.object({ disabled: z.boolean() })), (req, res) => {
  admin.setUserDisabled(req.params.id, req.body.disabled); audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, affectedUserId: req.params.id, action: req.body.disabled ? 'user_disabled' : 'user_enabled', ipAddress: req.ip }); res.status(204).end();
});
router.get('/jobs', (req, res) => res.json({ jobs: admin.listJobs(req.query) }));
router.post('/jobs/:id/retry', (req, res) => { admin.retryJob(req.params.id); res.status(204).end(); });
router.post('/jobs/:id/cancel', (req, res) => { admin.cancelJob(req.params.id); res.status(204).end(); });
router.get('/ai-requests', (req, res) => res.json({ requests: admin.aiRequests(req.query.limit) }));
router.get('/audit', (req, res) => res.json({ entries: admin.audit(req.query.limit) }));
router.get('/backups', asyncRoute(async (req, res) => res.json({ status: await backups.status(), history: backups.history(req.query.limit) })));
router.post('/backups/run', asyncRoute(async (req, res) => {
  const result = await backups.run({ triggerKind: 'manual' });
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'backup_run', resourceType: 'backup', resourceId: result.key || null, ipAddress: req.ip });
  res.json(result);
}));
router.get('/processing-settings', (req, res) => res.json({ settings: processingSettings.get() }));
router.put('/processing-settings', (req, res) => {
  const settings = processingSettings.update(req.body);
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'processing_settings_updated', ipAddress: req.ip, metadata: req.body });
  res.json({ settings });
});
router.get('/provider-settings', (req, res) => res.json({ settings: providerSettings.getAdmin() }));
router.post('/provider-settings/models', asyncRoute(async (req, res) => res.json(await providerSettings.discoverModels(req.body))));
// Deliberately exercises the configured services for real, so it is an explicit
// button rather than something the dashboard does on load.
router.post('/provider-settings/test', asyncRoute(async (req, res) => {
  const result = await providerSettings.testProviders();
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'provider.test',
    metadata: { transcription: result.transcription.ok, llm: result.llm.ok } });
  res.json(result);
}));
router.put('/provider-settings', (req, res) => {
  const settings = providerSettings.update(req.body);
  const metadata = Object.fromEntries(Object.entries(req.body).map(([workload, value]) => [workload, {
    provider: value.provider,
    model: value.model || null,
    baseUrl: value.baseUrl || null,
    language: value.language || null,
    responseFormat: value.responseFormat || null,
    apiKeyChanged: Boolean(value.apiKey || value.clearApiKey),
  }]));
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'provider_settings_updated', ipAddress: req.ip, metadata });
  res.json({ settings });
});
router.delete('/provider-settings', (req, res) => {
  const settings = providerSettings.clearOverrides();
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'provider_settings_reset', ipAddress: req.ip });
  res.json({ settings });
});

router.get('/settings/2fa', (req, res) => res.json(adminTwoFactor.getStatus(req.adminAuth.adminId)));
router.post('/settings/2fa/setup', (req, res) => res.json(adminTwoFactor.beginSetup(req.adminAuth.adminId, req.adminAuth.username)));
router.post('/settings/2fa/enable', validate(z.object({ code: z.string().min(1) })), (req, res) => res.json({ ok: true, recoveryCodes: adminTwoFactor.activateTwoFactor(req.adminAuth.adminId, req.body.code) }));
router.delete('/settings/2fa', validate(z.object({ code: z.string().min(1) })), (req, res) => { adminTwoFactor.disableTwoFactor(req.adminAuth.adminId, req.body.code); res.json({ ok: true }); });
router.post('/settings/2fa/recovery-codes', validate(z.object({ code: z.string().min(1) })), (req, res) => res.json({ ok: true, recoveryCodes: adminTwoFactor.regenerateRecoveryCodes(req.adminAuth.adminId, req.body.code) }));

module.exports = router;
