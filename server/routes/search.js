'use strict';

const express = require('express');
const { z } = require('zod');
const search = require('../services/search/search_service');
const ask = require('../services/search/ask_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { asyncRoute } = require('../middleware/async_route');
const { slidingWindow } = require('../middleware/rate_limit');
const { getConfig } = require('../config');
const { HttpError } = require('../middleware/error_handler');

const searchQuery = z.object({
  q: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  kinds: z.preprocess(
    (value) => (value == null || value === '' ? [] : String(value).split(',').map((kind) => kind.trim()).filter(Boolean)),
    z.array(z.enum(search.DOCUMENT_KINDS)),
  ).optional(),
});

const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('search:read'), validate(searchQuery, 'query'), asyncRoute(async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (!q) throw new HttpError(400, 'QUERY_REQUIRED', 'Search query is required.');
  const found = await search.search(req.auth.userId, q, { limit: req.query.limit, kinds: req.query.kinds || [] });
  res.json({ results: found.results, weakCount: found.weakCount });
}));
router.post('/ask', requireScope('search:ask'), slidingWindow({ windowMs: 60_000, limit: getConfig().askBurstPerMinute, code: 'ASK_BURST_LIMITED' }),
  validate(z.object({ question: z.string().min(1).max(4000) })), asyncRoute(async (req, res) => res.json(await ask.ask(req.auth.userId, req.body.question))));
module.exports = router;
