'use strict';

const express = require('express');
const multer = require('multer');
const path = require('node:path');
const crypto = require('node:crypto');
const { z } = require('zod');
const service = require('../services/ingest/import_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { HttpError } = require('../middleware/error_handler');
const { ensureRuntimeDirs } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { isIanaTimezone } = require('../utils/time');

const router = express.Router();
const upload = multer({ storage: multer.diskStorage({ destination: (_req, _file, done) => done(null, ensureRuntimeDirs().importTmp),
  filename: (_req, _file, done) => done(null, `incoming-${crypto.randomUUID()}.part`) }), limits: { fileSize: getConfig().importPartBytes + 1, files: 1 } });
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);
router.use(requireAuth, requireScope('ingest:write'));
router.post('/', validate(z.object({ id: z.string().uuid().optional(), deviceId: z.string().uuid().optional(), originalName: z.string().min(1).max(512),
  contentType: z.string().min(1).max(120), totalSize: z.number().int().positive(), sha256: z.string().regex(/^[a-f0-9]{64}$/i),
  partSize: z.number().int().positive().optional(), captureTime: z.string().datetime().optional(), timezone: z.string().min(1).max(100).refine(isIanaTimezone, 'Invalid IANA timezone').optional() })),
  (req, res, next) => { try { res.status(201).json(service.declare(req.auth.userId, { ...req.body, sha256: req.body.sha256.toLowerCase() })); } catch (error) { next(error); } });
router.get('/:id', (req, res, next) => { try { res.json(service.get(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
router.put('/:id/parts/:part', upload.single('part'), asyncRoute(async (req, res) => {
  const part = Number(req.params.part); if (!Number.isInteger(part) || part < 0) throw new HttpError(400, 'INVALID_PART', 'Part number is invalid.');
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(req.get('Content-Range') || '');
  const digest = req.get('X-Part-Sha256');
  if (!range || !/^[a-f0-9]{64}$/i.test(digest || '')) throw new HttpError(400, 'INVALID_PART_METADATA', 'Content-Range and X-Part-Sha256 are required.');
  res.json(await service.acceptPart(req.auth.userId, req.params.id, part, { rangeStart: Number(range[1]), rangeEnd: Number(range[2]), total: Number(range[3]), sha256: digest.toLowerCase() }, req.file));
}));
router.post('/:id/complete', asyncRoute(async (req, res) => res.status(202).json(await service.complete(req.auth.userId, req.params.id))));
router.delete('/:id', (req, res, next) => { try { service.cancel(req.auth.userId, req.params.id); res.status(204).end(); } catch (error) { next(error); } });
module.exports = router;
