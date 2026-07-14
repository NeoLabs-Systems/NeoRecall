'use strict';

const express = require('express');
const { z } = require('zod');
const search = require('../services/search/search_service');
const ask = require('../services/search/ask_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { slidingWindow } = require('../middleware/rate_limit');
const { getConfig } = require('../config');
const { HttpError } = require('../middleware/error_handler');

const router = express.Router();
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);
router.use(requireAuth);
router.get('/', requireScope('search:read'), asyncRoute(async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (!q) throw new HttpError(400, 'QUERY_REQUIRED', 'Search query is required.');
  const kinds = req.query.kinds ? String(req.query.kinds).split(',').filter(Boolean) : [];
  res.json({ results: await search.search(req.auth.userId, q, { limit: req.query.limit, kinds }) });
}));
router.post('/ask', requireScope('search:ask'), slidingWindow({ windowMs: 60_000, limit: getConfig().askBurstPerMinute, code: 'ASK_BURST_LIMITED' }),
  validate(z.object({ question: z.string().min(1).max(4000) })), asyncRoute(async (req, res) => res.json(await ask.ask(req.auth.userId, req.body.question))));
module.exports = router;
