'use strict';

// Admin API, under /api/v1/admin. Every route needs an interactive session for
// an account whose role is admin; the role is re-read on each request, so
// revoking it applies at once. Admin itself is granted and revoked by the
// operator (`neorecall admin`), never through this API.

const express = require('express');
const { z } = require('zod');
const admin = require('../services/admin/admin_service');
const audit = require('../services/audit/audit_service');
const processingSettings = require('../services/settings/processing_settings_service');
const providerSettings = require('../services/settings/provider_settings_service');
const backups = require('../services/backup/backup_service');
const usageLimits = require('../services/usage/usage_limit_service');
const { requireAuth, requireAdmin } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');

const router = express.Router();
router.use(requireAuth, requireAdmin);
router.get('/stats', (req, res) => res.json(admin.stats()));
router.get('/users', (req, res) => res.json({ users: admin.users(req.query.limit) }));
router.patch('/users/:id', validate(z.object({ disabled: z.boolean() })), (req, res) => {
  admin.setUserDisabled(req.params.id, req.body.disabled); audit.record({ actorType: 'admin', actorId: req.auth.userId, affectedUserId: req.params.id, action: req.body.disabled ? 'user_disabled' : 'user_enabled', ipAddress: req.ip }); res.status(204).end();
});
const usageOverride = z.number().int().min(0).nullable();
router.get('/users/:id/usage-limits', (req, res) => res.json(usageLimits.getUserLimits(req.params.id)));
router.put('/users/:id/usage-limits', validate(z.object({
  aiLimit4h: usageOverride.optional(),
  aiLimitWeekly: usageOverride.optional(),
  transcriptionLimit4h: usageOverride.optional(),
  transcriptionLimitWeekly: usageOverride.optional(),
})), (req, res) => {
  const limits = usageLimits.setUserLimits(req.params.id, req.body);
  audit.record({ actorType: 'admin', actorId: req.auth.userId, affectedUserId: req.params.id, action: 'user_usage_limits_updated', ipAddress: req.ip, metadata: req.body });
  res.json(limits);
});
router.get('/config/usage-limits', (req, res) => res.json({ limits: usageLimits.getInstallDefaults() }));
router.put('/config/usage-limits', validate(z.object({
  aiTokens4h: z.number().int().min(0).optional(),
  aiTokensWeekly: z.number().int().min(0).optional(),
  transcriptionSeconds4h: z.number().int().min(0).optional(),
  transcriptionSecondsWeekly: z.number().int().min(0).optional(),
})), (req, res) => {
  const limits = usageLimits.setInstallDefaults(req.body);
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'usage_limits_updated', ipAddress: req.ip, metadata: req.body });
  res.json({ limits });
});
router.get('/jobs', (req, res) => res.json({ jobs: admin.listJobs(req.query) }));
router.post('/jobs/:id/retry', (req, res) => { admin.retryJob(req.params.id); res.status(204).end(); });
router.post('/jobs/:id/cancel', (req, res) => { admin.cancelJob(req.params.id); res.status(204).end(); });
router.get('/ai-requests', (req, res) => res.json({ requests: admin.aiRequests(req.query.limit) }));
router.get('/audit', (req, res) => res.json({ entries: admin.audit(req.query.limit) }));
router.get('/backups', asyncRoute(async (req, res) => res.json({ status: await backups.status(), history: backups.history(req.query.limit) })));
router.post('/backups/run', asyncRoute(async (req, res) => {
  const result = await backups.run({ triggerKind: 'manual' });
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'backup_run', resourceType: 'backup', resourceId: result.key || null, ipAddress: req.ip });
  res.json(result);
}));
router.get('/processing-settings', (req, res) => res.json({ settings: processingSettings.get() }));
router.put('/processing-settings', (req, res) => {
  const settings = processingSettings.update(req.body);
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'processing_settings_updated', ipAddress: req.ip, metadata: req.body });
  res.json({ settings });
});
router.get('/provider-settings', (req, res) => res.json({ settings: providerSettings.getAdmin() }));
router.post('/provider-settings/models', asyncRoute(async (req, res) => res.json(await providerSettings.discoverModels(req.body))));
// Deliberately exercises the configured services for real, so it is an explicit
// button rather than something the dashboard does on load.
router.post('/provider-settings/test', asyncRoute(async (req, res) => {
  const result = await providerSettings.testProviders();
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'provider.test',
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
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'provider_settings_updated', ipAddress: req.ip, metadata });
  res.json({ settings });
});
router.delete('/provider-settings', (req, res) => {
  const settings = providerSettings.clearOverrides();
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'provider_settings_reset', ipAddress: req.ip });
  res.json({ settings });
});

module.exports = router;
