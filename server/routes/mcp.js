'use strict';

const express = require('express');
const mcp = require('../services/mcp/mcp_service');
const oauth = require('../services/auth/oauth_service');
const { callerBaseUrl, wwwAuthenticate } = require('../services/auth/oauth_urls');
const { slidingWindow } = require('../middleware/rate_limit');
const { asyncRoute } = require('../middleware/async_route');
const { HttpError } = require('../middleware/error_handler');

const router = express.Router();

function authenticate(req, res) {
  const header = String(req.get('authorization') || '');
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const auth = oauth.authenticateAccessToken(token);
  if (auth) return auth;
  res.set('WWW-Authenticate', wwwAuthenticate(callerBaseUrl(req)));
  res.status(401).json({ error: 'Unauthorized' });
  return null;
}

function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id: id ?? null, error: { code, message } };
}

function rpcResult(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function toolContent(value, isError = false) {
  return {
    content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }],
    ...(isError ? { isError: true } : {}),
  };
}

async function handleRpc(auth, body) {
  if (!body || body.jsonrpc !== '2.0' || typeof body.method !== 'string') {
    return rpcError(body?.id ?? null, -32600, 'Invalid Request');
  }
  const { id, method, params } = body;
  if (method === 'initialize') return rpcResult(id, mcp.initialize());
  if (method === 'notifications/initialized') return null;
  if (method === 'ping') return rpcResult(id, {});
  if (method === 'tools/list') return rpcResult(id, mcp.listTools());
  if (method === 'tools/call') {
    const name = String(params?.name || '').trim();
    try {
      const result = await mcp.callTool(auth, name, params?.arguments || {});
      return rpcResult(id, toolContent(result));
    } catch (error) {
      const message = error instanceof HttpError ? error.message : 'Tool call failed.';
      return rpcResult(id, toolContent({ error: message }, true));
    }
  }
  return rpcError(id, -32601, `Method not found: ${method}`);
}

router.get('/mcp', (req, res) => {
  if (!authenticate(req, res)) return;
  res.set('Allow', 'POST');
  return res.status(405).json({ error: 'Method Not Allowed' });
});

router.post('/mcp', slidingWindow({ windowMs: 60_000, limit: 120 }), asyncRoute(async (req, res) => {
  const auth = authenticate(req, res);
  if (!auth) return;
  const body = req.body;
  if (Array.isArray(body)) {
    const results = [];
    for (const item of body) {
      const reply = await handleRpc(auth, item);
      if (reply) results.push(reply);
    }
    return res.json(results);
  }
  const reply = await handleRpc(auth, body);
  if (!reply) return res.status(204).end();
  return res.json(reply);
}));

module.exports = router;
