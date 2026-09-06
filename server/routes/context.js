'use strict';

const fs = require('node:fs');
const multer = require('multer');
const express = require('express');
const { z } = require('zod');
const { getConfig } = require('../config');
const { ensureRuntimeDirs } = require('../../runtime/paths');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const service = require('../services/context/context_service');

const upload = multer({
  storage: multer.diskStorage({
    destination: (_request, _file, done) => done(null, ensureRuntimeDirs().context),
    filename: (_request, _file, done) => done(null, `incoming-${Date.now()}-${Math.random().toString(16).slice(2)}.part`),
  }),
  limits: { fileSize: getConfig().contextMaxFileBytes, files: 1 },
});

function input(request) {
  return {
    kind: request.body.kind,
    noteText: request.body.noteText,
    contentType: request.body.contentType,
    capturedOffsetMs: request.body.capturedOffsetMs === undefined ? undefined : Number(request.body.capturedOffsetMs),
  };
}

function routerFor(target) {
  const router = express.Router({ mergeParams: true });
  const routeTarget = (req) => target === 'session'
    ? { sessionId: req.params.sessionId }
    : { memoryId: req.params.memoryId };
  router.use(requireAuth);
  router.get('/', requireScope(target === 'session' ? 'recordings:read' : 'memories:read'), (req, res) => {
    const items = target === 'session'
      ? service.listForSession(req.auth.userId, req.params.sessionId)
      : service.listForMemory(req.auth.userId, req.params.memoryId);
    res.json({ items });
  });
  router.put('/:itemId', requireScope(target === 'session' ? 'ingest:write' : 'memories:write'), upload.single('file'), (req, res, next) => {
    try {
      const item = service.create(req.auth.userId, target === 'session'
        ? { sessionId: req.params.sessionId }
        : { memoryId: req.params.memoryId }, req.params.itemId, input(req), req.file);
      res.status(201).json({ item });
    } catch (error) {
      if (req.file?.path && fs.existsSync(req.file.path)) fs.unlinkSync(req.file.path);
      next(error);
    }
  });
  router.patch('/:itemId', requireScope(target === 'session' ? 'ingest:write' : 'memories:write'), validate(z.object({ noteText: z.string().min(1) })), (req, res, next) => {
    try { res.json({ item: service.update(req.auth.userId, req.params.itemId, req.body, routeTarget(req)) }); } catch (error) { next(error); }
  });
  router.delete('/:itemId', requireScope(target === 'session' ? 'ingest:write' : 'memories:write'), (req, res, next) => {
    try { service.remove(req.auth.userId, req.params.itemId, routeTarget(req)); res.status(204).end(); } catch (error) { next(error); }
  });
  router.post('/:itemId/retry', requireScope(target === 'session' ? 'ingest:write' : 'memories:write'), (req, res, next) => {
    try { res.status(202).json({ item: service.retry(req.auth.userId, req.params.itemId, routeTarget(req)) }); } catch (error) { next(error); }
  });
  router.get('/:itemId/original', requireScope(target === 'session' ? 'recordings:read' : 'memories:read'), (req, res, next) => {
    try {
      const item = service.original(req.auth.userId, req.params.itemId, routeTarget(req));
      res.type(item.content_type || 'application/octet-stream');
      res.set('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(item.original_name)}`);
      res.sendFile(item.original_path);
    } catch (error) { next(error); }
  });
  return router;
}

module.exports = { sessionRouter: routerFor('session'), memoryRouter: routerFor('memory') };
