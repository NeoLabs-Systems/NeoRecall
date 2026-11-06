'use strict';

// "Connect NeoRouter", under /api/v1/admin/neorouter (admins only, from the
// admin router's own guard). Routes only validate and translate; the work is in
// server/ai/neorouter.

const express = require('express');
const { z } = require('zod');
const connection = require('../ai/neorouter/connection');
const { describeOffer } = require('../ai/neorouter/offer');
const roles = require('../ai/neorouter/roles');
const signIn = require('../ai/neorouter/sign_in');
const audit = require('../services/audit/audit_service');
const { HttpError } = require('../middleware/error_handler');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');

const router = express.Router();

// The settings page always asks the router afresh: what a key may use is
// changed in NeoRouter, not here.
async function describe() {
  const current = connection.get();
  if (!current) return { connected: false, address: null, roles: [], offer: null, reachable: false, unreachableReason: null };
  let offer = null;
  let unreachableReason = null;
  try {
    offer = await describeOffer(current, { fresh: true });
  } catch (error) {
    unreachableReason = error.message;
  }
  return { connected: true, address: current.origin, roles: roles.activeRoles(), offer, reachable: Boolean(offer), unreachableReason };
}

router.get('/', asyncRoute(async (req, res) => res.json({ allRoles: connection.ROLES, ...(await describe()) })));

router.post('/connect', validate(z.object({ address: z.string().trim().min(1).max(2_048) })), asyncRoute(async (req, res) => {
  try {
    const started = await signIn.begin({ userId: req.auth.userId, address: req.body.address });
    audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'neorouter_connect_started', ipAddress: req.ip });
    res.json(started);
  } catch (error) {
    throw new HttpError(400, error.code || 'NEOROUTER_CONNECT_FAILED', error.message);
  }
}));

router.get('/connect/:id', (req, res) => {
  const result = signIn.status(req.params.id, req.auth.userId);
  if (!result) throw new HttpError(404, 'NEOROUTER_SIGN_IN_EXPIRED', 'This sign-in expired. Start again.');
  if (result.status === 'completed') audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'neorouter_connected', ipAddress: req.ip });
  res.json(result);
});

router.put('/roles', validate(z.object({ roles: z.array(z.enum(connection.ROLES)).max(connection.ROLES.length) })), (req, res) => {
  try {
    const active = roles.updateRoles(req.body.roles);
    audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'neorouter_roles_updated', ipAddress: req.ip, metadata: { roles: active } });
    res.json({ roles: active });
  } catch (error) {
    throw new HttpError(400, error.code || 'NEOROUTER_ROLES_FAILED', error.message);
  }
});

router.delete('/', (req, res) => {
  roles.disconnect();
  audit.record({ actorType: 'admin', actorId: req.auth.userId, action: 'neorouter_disconnected', ipAddress: req.ip });
  res.json({ success: true });
});

module.exports = router;
