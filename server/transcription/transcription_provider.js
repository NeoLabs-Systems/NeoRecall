'use strict';

const { getConfig } = require('../config');
const providerSettings = require('../services/settings/provider_settings_service');
const { createLogger } = require('../utils/logger');
const vocabularyCorrection = require('./vocabulary_correction');

const logger = createLogger('transcription');

// One transcription service.
//
// Subclasses implement `fetchSegments` — the part that differs per service —
// and inherit the parts that must not: vocabulary correction, timing, and the
// failure log that names the endpoint. Those three used to live inside the
// OpenAI-compatible provider alone, which meant a Deepgram or AssemblyAI user
// silently got no vocabulary correction however they had it configured, and a
// failure that named nothing.
class TranscriptionProvider {
  // Calls the service and returns segments built with `buildSegment`.
  async fetchSegments(_input) { throw new Error('TranscriptionProvider.fetchSegments must be implemented.'); }

  async ready() { return false; }

  async transcribe(input) {
    const { vocabulary = [], vocabularyCorrectionEnabled = true } = input;
    const settings = providerSettings.getRuntime().transcription;
    const startedAt = Date.now();
    try {
      const raw = await this.fetchSegments(input);
      const segments = vocabularyCorrectionEnabled
        ? this.correctVocabulary(raw, vocabulary)
        : raw;
      const corrected = segments.filter((segment, index) => segment.text !== raw[index].text).length;
      if (corrected) logger.info('Applied conservative vocabulary correction', { corrected });
      logger.debug('Transcribed a recording', {
        provider: settings.provider, model: settings.model,
        seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
        segments: segments.length, language: segments[0]?.language ?? null,
      });
      return segments;
    } catch (error) {
      // Named here rather than left to the worker, because the worker only sees
      // "the job failed" and the endpoint, model and wording are what actually
      // identify the problem.
      logger.warn('Transcription request failed', {
        provider: settings.provider, model: settings.model, endpoint: settings.baseUrl,
        errorCode: error.code || 'TRANSCRIPTION_FAILED', httpStatus: error.status || null,
        seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
        reason: String(error.message || '').slice(0, 400),
      });
      throw error;
    }
  }

  correctVocabulary(segments, vocabulary) {
    const config = getConfig();
    return vocabularyCorrection.correctSegments(segments, vocabulary, {
      minimumLength: config.vocabularyCorrectionMinimumLength,
      maximumDistance: config.vocabularyCorrectionMaximumDistance,
      similarityThreshold: config.vocabularyCorrectionSimilarity,
      ambiguityMargin: config.vocabularyCorrectionAmbiguityMargin,
    });
  }
}

module.exports = { TranscriptionProvider };
