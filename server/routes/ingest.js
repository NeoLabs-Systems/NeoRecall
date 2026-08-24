'use strict';

const express = require('express');
const multer = require('multer');
const { z } = require('zod');
const service = require('../services/ingest/ingest_service');
const tempAudio = require('../services/ingest/temp_audio_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const { validate } = require('../middleware/validate');
const { HttpError } = require('../middleware/error_handler');
const { getConfig } = require('../config');
const { isIanaTimezone } = require('../utils/time');

const router = express.Router();
const storage = multer.diskStorage({
  destination: (_req, _file, callback) => callback(null, require('../../runtime/paths').ensureRuntimeDirs().audioTmp),
  filename: (_req, _file, callback) => callback(null, require('node:path').basename(tempAudio.incomingPath())),
});
const upload = multer({ storage, limits: { fileSize: getConfig().maxUploadBytes, files: 1 } });
const asyncRoute = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch(next);

router.use(requireAuth, requireScope('ingest:write'));
const sourceSchema = z.object({
  id: z.string().uuid().optional(), clientUuid: z.string().min(8).max(128), kind: z.enum(['microphone', 'system', 'combined', 'import', 'wearable']),
  channelLayout: z.string().min(1).max(80), sampleRate: z.number().int().positive().max(384000),
  sampleFormat: z.string().min(1).max(40), metadata: z.record(z.unknown()).optional(),
});
router.post('/sessions', validate(z.object({
  id: z.string().uuid().optional(), deviceId: z.string().uuid(), clientUuid: z.string().min(8).max(128), startedAt: z.string().datetime(),
  timezone: z.string().min(1).max(100).refine(isIanaTimezone, 'Invalid IANA timezone'), clockOffsetMs: z.number().optional(), consentAttestedAt: z.string().datetime(),
  sources: z.array(sourceSchema).min(1).max(8),
})), (req, res, next) => { try { res.status(201).json(service.createSession(req.auth.userId, req.body)); } catch (error) { next(error); } });
router.get('/sessions/:id/sync-state', (req, res, next) => { try { res.json(service.syncState(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
router.patch('/sessions/:id', validate(z.object({
  endedAt: z.string().datetime(), status: z.enum(['ended', 'interrupted']).default('ended'),
  sources: z.array(z.object({ id: z.string().uuid(), finalSequence: z.number().int().min(-1) })).optional(),
})), (req, res, next) => { try { res.json(service.closeSession(req.auth.userId, req.params.id, req.body)); } catch (error) { next(error); } });
router.post('/sessions/:id/sources', validate(sourceSchema), (req, res, next) => { try { res.status(201).json(service.addSource(req.auth.userId, req.params.id, req.body)); } catch (error) { next(error); } });
router.patch('/sessions/:id/sources/:sourceId', validate(z.object({ finalSequence: z.number().int().min(-1) })), (req, res, next) => {
  try { res.json(service.closeSource(req.auth.userId, req.params.id, req.params.sourceId, req.body.finalSequence)); } catch (error) { next(error); }
});
const gapSchema = z.object({
  id: z.string().uuid().optional(), sourceId: z.string().uuid(), startOffsetMs: z.number().int().nonnegative(),
  endOffsetMs: z.number().int().positive(), startSequence: z.number().int().nonnegative().optional(),
  endSequence: z.number().int().nonnegative().optional(),
  reason: z.enum(['sleep', 'permission_lost', 'storage_full', 'capture_error', 'user_paused', 'device_shutdown']),
}).refine((gap) => gap.endOffsetMs > gap.startOffsetMs &&
  (gap.startSequence === undefined) === (gap.endSequence === undefined) &&
  (gap.startSequence === undefined || gap.endSequence >= gap.startSequence), 'Gap sequence coverage must be a complete, ordered range.');
router.post('/sessions/:id/gaps', validate(z.object({ gaps: z.array(gapSchema).min(1).max(1000) })),
  (req, res, next) => { try { service.addGaps(req.auth.userId, req.params.id, req.body.gaps); res.status(204).end(); } catch (error) { next(error); } });

router.put('/sessions/:id/sources/:sourceId/chunks/:sequence', upload.single('audio'), asyncRoute(async (req, res) => {
  const sequence = Number(req.params.sequence);
  const idempotencyKey = req.get('Idempotency-Key');
  const hash = req.get('X-Chunk-Sha256');
  if (!Number.isInteger(sequence) || sequence < 0) throw new HttpError(400, 'INVALID_SEQUENCE', 'Chunk sequence must be a non-negative integer.');
  if (!idempotencyKey || idempotencyKey.length > 200) throw new HttpError(400, 'IDEMPOTENCY_KEY_REQUIRED', 'Idempotency-Key is required.');
  if (!/^[a-f0-9]{64}$/i.test(hash || '')) throw new HttpError(400, 'INVALID_HASH', 'X-Chunk-Sha256 must be a hexadecimal SHA-256 digest.');
  const contentType = req.file?.mimetype || 'application/octet-stream';
  const container = req.get('X-Audio-Container') || contentType.split('/')[1]?.split(';')[0] || 'bin';
  const input = {
    idempotencyKey, sha256: hash.toLowerCase(), durationMs: Number(req.get('X-Chunk-Duration-Ms')),
    overlapMs: Number(req.get('X-Chunk-Overlap-Ms') || 0), channelLayout: req.get('X-Channel-Layout') || 'mono',
    monotonicOffsetMs: Number(req.get('X-Monotonic-Offset-Ms')), deviceStartedAt: req.get('X-Device-Started-At'),
    container, codec: req.get('X-Audio-Codec') || 'pcm_s16le',
    contentEncoding: req.get('X-Audio-Content-Encoding') || 'identity',
    isFinal: req.get('X-Final-Chunk') === 'true',
  };
  if (!['identity', 'gzip'].includes(input.contentEncoding)) throw new HttpError(400, 'INVALID_AUDIO_ENCODING', 'Unsupported audio content encoding.');
  if (![input.durationMs, input.overlapMs, input.monotonicOffsetMs].every(Number.isInteger) || !input.deviceStartedAt) throw new HttpError(400, 'INVALID_CHUNK_METADATA', 'Chunk timing headers are invalid or incomplete.');
  const receipt = await service.acceptChunk(req.auth.userId, req.params.id, req.params.sourceId, sequence, input, req.file);
  res.status(receipt.state === 'uploaded' && !receipt.duplicate ? 202 : 200).json({ receipt });
}));

router.post('/chunks/status', validate(z.object({ chunkIds: z.array(z.string().uuid()).min(1).max(500) })), (req, res) => res.json({ receipts: service.status(req.auth.userId, req.body.chunkIds) }));
router.post('/chunks/released', validate(z.object({ chunkIds: z.array(z.string().uuid()).min(1).max(500) })), (req, res) => res.json({ released: service.released(req.auth.userId, req.body.chunkIds) }));
router.get('/stream', (_req, _res, next) => next(new HttpError(501, 'FEATURE_NOT_ENABLED', 'Wearable streaming is not enabled in v1.')));

module.exports = router;
