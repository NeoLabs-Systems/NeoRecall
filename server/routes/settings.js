'use strict';

const express = require('express');
const service = require('../services/settings/settings_service');
const auth = require('../services/auth/auth_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { z } = require('zod');
const qrcode = require('qrcode');
const router = express.Router();
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);
router.use(requireAuth);
router.get('/', requireScope('settings:read'), (req, res) => res.json({ settings: service.get(req.auth.userId) }));
router.put('/', requireScope('settings:write'), (req, res, next) => { try { res.json({ settings: service.update(req.auth.userId, req.body) }); } catch (error) { next(error); } });

router.get('/2fa', requireScope('settings:read'), (req, res) => res.json(auth.getTwoFactorStatus(req.auth.userId)));
router.post('/2fa/setup', requireScope('settings:write'), asyncRoute(async (req, res) => {
  const setup = auth.beginTwoFactor(req.auth.userId, req.auth.user.username);
  const qrDataUrl = await qrcode.toDataURL(setup.otpauthUri, { width: 200, margin: 2 });
  res.json({ ...setup, qrDataUrl });
}));
router.post('/2fa/enable', requireScope('settings:write'), validate(z.object({ code: z.string().min(1) })), (req, res) => res.json({ ok: true, recoveryCodes: auth.activateTwoFactor(req.auth.userId, req.body.code) }));
router.delete('/2fa', requireScope('settings:write'), validate(z.object({ password: z.string().min(1), code: z.string().min(1).optional() })), asyncRoute(async (req, res) => { await auth.disableTwoFactor(req.auth.userId, req.body.password, req.body.code); res.json({ ok: true }); }));
router.post('/2fa/recovery-codes', requireScope('settings:write'), validate(z.object({ password: z.string().min(1), code: z.string().min(1) })), asyncRoute(async (req, res) => {
  res.json({ ok: true, recoveryCodes: await auth.regenerateRecoveryCodes(req.auth.userId, req.body.password, req.body.code) });
}));

module.exports = router;
