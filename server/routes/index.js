'use strict';

const express = require('express');
const { requireAuth } = require('../middleware/auth');
const { getConfig } = require('../config');
const { CHUNK_RECEIPT_BATCH_LIMIT } = require('../services/ingest/limits');

const router = express.Router();
router.get('/meta', requireAuth, (req, res) => {
  const config = getConfig();
  res.json({
    product: 'NeoRecall', version: require('../../package.json').version,
    user: req.user,
    capabilities: { localTranscription: false, diarization: false, semanticSearch: true,
      displayAudio: 'client-dependent', wearableStreaming: false, oauthPublicRoutes: true,
      gzipAudioUpload: true },
    limits: { maxUploadBytes: config.maxUploadBytes, chunkMinMs: config.chunkMinMs, chunkMaxMs: config.chunkMaxMs,
      chunkTargetMs: config.chunkTargetMs, chunkOverlapMs: config.chunkOverlapMs, importPartBytes: config.importPartBytes,
      minimumConsolidationIntervalMs: config.minConsolidationIntervalMs,
      chunkReceiptBatch: CHUNK_RECEIPT_BATCH_LIMIT },
  });
});
router.use('/auth', require('./auth'));
router.use('/api-keys', require('./api_keys'));
router.use('/devices', require('./devices'));
router.use('/ingest', require('./ingest'));
router.use('/imports', require('./imports'));
router.use('/recordings', require('./recordings'));
router.use('/transcripts', require('./transcripts'));
router.use('/conversations', require('./conversations'));
router.use('/speakers', require('./speakers'));
router.use('/memories/consolidations', require('./consolidations'));
router.use('/memories', require('./memories'));
router.use('/mini-memories', require('./mini_memories'));
router.use('/daily-summaries', require('./daily_summaries'));
router.use('/search', require('./search'));
router.use('/settings', require('./settings'));
router.use('/events', require('./events'));
router.use('/diagnostics', require('./diagnostics'));
router.use('/sources', require('./sources'));
module.exports = router;
