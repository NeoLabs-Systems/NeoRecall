'use strict';

const express = require('express');
const { z } = require('zod');
const auth = require('../services/auth/auth_service');
const { requireAuth, requireSession } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { slidingWindow } = require('../middleware/rate_limit');

const router = express.Router();
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);
const context = (req) => ({ ipAddress: req.ip, userAgent: req.get('User-Agent') });

router.post('/register', slidingWindow({ windowMs: 60_000, limit: 10 }), validate(z.object({
  username: z.string().min(3).max(64), email: z.string().email().optional().nullable(), password: z.string().min(12).max(1024),
})), asyncRoute(async (req, res) => res.status(201).json(await auth.register(req.body, context(req)))));

router.post('/login', slidingWindow({ windowMs: 60_000, limit: 10 }), validate(z.object({
  account: z.string().min(1).max(320), password: z.string().max(1024), twoFactorCode: z.string().max(64).optional(),
})), asyncRoute(async (req, res) => res.json(await auth.login(req.body, context(req)))));

router.use(requireAuth);
router.get('/me', (req, res) => res.json({ user: req.user }));
router.post('/logout', (req, res) => { if (req.auth.type === 'session') auth.logout(req.auth.sessionId); res.status(204).end(); });
router.use(requireSession);
router.post('/logout-all', (req, res) => { auth.logoutAll(req.auth.userId); res.status(204).end(); });
router.put('/password', validate(z.object({ currentPassword: z.string(), newPassword: z.string().min(12).max(1024) })),
  asyncRoute(async (req, res) => { await auth.changePassword(req.auth.userId, req.body.currentPassword, req.body.newPassword); res.status(204).end(); }));
router.delete('/account', validate(z.object({ password: z.string(), twoFactorCode: z.string().optional() })),
  asyncRoute(async (req, res) => { await auth.deleteAccount(req.auth.userId, req.body.password, req.body.twoFactorCode); res.status(204).end(); }));
router.post('/2fa/setup', (req, res) => res.json(auth.beginTwoFactor(req.auth.userId, req.user.username)));
router.post('/2fa/verify', validate(z.object({ code: z.string().min(6).max(64) })), (req, res) => {
  res.json({ recoveryCodes: auth.activateTwoFactor(req.auth.userId, req.body.code) });
});
router.delete('/2fa', validate(z.object({ password: z.string(), code: z.string().min(1) })),
  asyncRoute(async (req, res) => { await auth.disableTwoFactor(req.auth.userId, req.body.password, req.body.code); res.status(204).end(); }));

module.exports = router;
