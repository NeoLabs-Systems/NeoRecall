'use strict';

const express = require('express');
const { z } = require('zod');
const auth = require('../services/auth/admin_auth_service');
const admin = require('../services/admin/admin_service');
const adminTwoFactor = require('../services/auth/admin_two_factor_service');
const audit = require('../services/audit/audit_service');
const processingSettings = require('../services/settings/processing_settings_service');
const { requireAdmin } = require('../middleware/admin_auth');
const { validate } = require('../middleware/validate');
const { slidingWindow } = require('../middleware/rate_limit');

const router = express.Router();
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);
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
router.patch('/users/:id', validate(z.object({ disabled: z.boolean() })), (req, res, next) => { try {
  admin.setUserDisabled(req.params.id, req.body.disabled); audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, affectedUserId: req.params.id, action: req.body.disabled ? 'user_disabled' : 'user_enabled', ipAddress: req.ip }); res.status(204).end();
} catch (error) { next(error); } });
router.get('/jobs', (req, res) => res.json({ jobs: admin.listJobs(req.query) }));
router.post('/jobs/:id/retry', (req, res, next) => { try { admin.retryJob(req.params.id); res.status(204).end(); } catch (error) { next(error); } });
router.post('/jobs/:id/cancel', (req, res, next) => { try { admin.cancelJob(req.params.id); res.status(204).end(); } catch (error) { next(error); } });
router.get('/ai-requests', (req, res) => res.json({ requests: admin.aiRequests(req.query.limit) }));
router.get('/audit', (req, res) => res.json({ entries: admin.audit(req.query.limit) }));
router.get('/processing-settings', (req, res) => res.json({ settings: processingSettings.get() }));
router.put('/processing-settings', (req, res, next) => { try {
  const settings = processingSettings.update(req.body);
  audit.record({ actorType: 'admin', actorId: req.adminAuth.adminId, action: 'processing_settings_updated', ipAddress: req.ip, metadata: req.body });
  res.json({ settings });
} catch (error) { next(error); } });

router.get('/settings/2fa', (req, res) => res.json(adminTwoFactor.getStatus(req.adminAuth.adminId)));
router.post('/settings/2fa/setup', (req, res) => res.json(adminTwoFactor.beginSetup(req.adminAuth.adminId, req.adminAuth.username)));
router.post('/settings/2fa/enable', validate(z.object({ code: z.string().min(1) })), (req, res) => res.json({ ok: true, recoveryCodes: adminTwoFactor.activateTwoFactor(req.adminAuth.adminId, req.body.code) }));
router.delete('/settings/2fa', validate(z.object({ code: z.string().min(1) })), (req, res) => { adminTwoFactor.disableTwoFactor(req.adminAuth.adminId, req.body.code); res.json({ ok: true }); });
router.post('/settings/2fa/recovery-codes', validate(z.object({ code: z.string().min(1) })), (req, res) => res.json({ ok: true, recoveryCodes: adminTwoFactor.regenerateRecoveryCodes(req.adminAuth.adminId, req.body.code) }));

module.exports = router;
