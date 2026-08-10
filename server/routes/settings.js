'use strict';

const express = require('express');
const service = require('../services/settings/settings_service');
const auth = require('../services/auth/auth_service');
const webauthn = require('../services/auth/webauthn_service');
const { requireAuth, requireScope, requireSession } = require('../middleware/auth');
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

const relyingParty = (req) => webauthn.resolveRelyingParty({
  origin: req.get('Origin'),
  selfOrigin: `${req.protocol}://${req.get('host')}`,
});

router.get('/security-keys', requireScope('settings:read'), (req, res) => res.json({ credentials: webauthn.listCredentials(req.auth.userId) }));
router.post('/security-keys/options', requireSession, requireScope('settings:write'), asyncRoute(async (req, res) => res.json(await webauthn.beginRegistration({
  userId: req.auth.userId, username: req.auth.user.username, rp: relyingParty(req),
}))));
router.post('/security-keys', requireSession, requireScope('settings:write'), validate(z.object({
  challengeId: z.string().min(1).max(64), response: z.object({}).passthrough(), label: z.string().max(64).optional(),
})), asyncRoute(async (req, res) => res.json(await webauthn.completeRegistration({
  userId: req.auth.userId, challengeId: req.body.challengeId, response: req.body.response, label: req.body.label, rp: relyingParty(req),
}))));
router.put('/security-keys/:id', requireSession, requireScope('settings:write'), validate(z.object({ label: z.string().min(1).max(64) })),
  (req, res) => res.json(webauthn.renameCredential(req.auth.userId, req.params.id, req.body.label)));
router.delete('/security-keys/:id', requireSession, requireScope('settings:write'),
  (req, res) => res.json(webauthn.deleteCredential(req.auth.userId, req.params.id)));

module.exports = router;
