'use strict';

const { getProvider } = require('../transcription/provider_registry');
const audioPreprocess = require('../transcription/audio_preprocess');
const localAnalysis = require('../transcription/local_analysis');
const { alignSegments } = require('../transcription/speaker_alignment');
const { getConfig } = require('../config');
const { createLogger } = require('../utils/logger');
const usageLimits = require('../services/usage/usage_limit_service');

const logger = createLogger('inference-host');

// Turns one chunk of audio into transcript segments that know who was speaking.
// Conditions the audio first, then runs local VAD/diarization so silent chunks
// are never sent to the transcription service, then joins the returned segments
// to the local speaker turns by timestamp overlap. Conditioning, the native
// runtime and the models are all optional; without any of them the chunk is
// still transcribed, just from the original bytes and without a speaker.
//
// Conditioning is duration-preserving by construction, which is what lets the
// speaker turns measured here still describe the original recording — the
// speaker previews cut later read that original file.
async function transcribe(input, report = () => {}) {
  const opened = require('../utils/sealed_fs').materialize(input.filename);
  let prepared;
  try {
    prepared = audioPreprocess.prepare(opened.path, {
      channelLayout: input.channelLayout, durationMs: input.durationMs,
    });
  } catch (error) {
    opened.cleanup();
    throw error;
  }
  report({ seconds: prepared.seconds, applied: prepared.applied, fellBack: prepared.fellBack });
  try {
    // Speaker detection reads the original recording by default. Conditioning
    // helps a transcription service and hurts the local audio models, which
    // were trained on unprocessed speech and read the low frequencies a
    // high-pass removes as part of who is talking. See
    // docs/docs/configuration.md.
    const analysisFile = getConfig().audioPreprocessTarget === 'stt+analysis' ? prepared.filename : opened.path;
    const analysis = localAnalysis.analyze(analysisFile);
    if (!analysis.hasSpeech) return [];
    let releaseReservation = () => {};
    if (input.userId) {
      const admitted = usageLimits.enforce(input.userId, 'transcription', {
        reserve: usageLimits.transcriptionSecondsFor(input.durationMs),
      });
      releaseReservation = admitted.releaseReservation;
    }
    if (prepared.applied.length) {
      logger.info('Conditioned audio before transcription', {
        applied: prepared.applied, seconds: Number(prepared.seconds.toFixed(3)),
        inputLufs: prepared.inputLufs, outputLufs: prepared.outputLufs,
      });
    }
    try {
      const segments = await getProvider().transcribe({
        filename: prepared.filename, channelLayout: input.channelLayout, vocabulary: input.vocabulary || [],
        vocabularyCorrectionEnabled: input.vocabularyCorrectionEnabled !== false,
      });
      if (input.userId && input.chunkId) {
        usageLimits.recordTranscription(input.userId, input.chunkId, input.durationMs);
      }
      if (!analysis.analyzed || !analysis.turns.length) return segments;
      return alignSegments(segments, analysis.turns);
    } finally {
      releaseReservation();
    }
  } finally {
    // The single deletion point, and it has to stay one: derived audio must not
    // outlive the request that needed it.
    prepared.cleanup();
    opened.cleanup();
  }
}

if (require.main === module) {
  process.on('message', async (message) => {
    if (!message || message.type !== 'transcribe') return;
    try {
      const segments = await transcribe(message.input, (preprocess) => {
        process.send?.({ type: 'diagnostics', requestId: message.requestId, preprocess });
      });
      process.send?.({ type: 'result', requestId: message.requestId, segments });
    } catch (error) {
      logger.error('Inference request failed', { error });
      process.send?.({ type: 'error', requestId: message.requestId, error: {
        code: error.code || 'INFERENCE_FAILED',
        message: error.message,
        stack: error.stack,
        retryAt: error.retryAt || null,
        details: error.details || null,
        status: error.status || null,
      } });
    }
  });
  let readinessPending = false;
  const reportReadiness = async () => {
    if (readinessPending) return;
    readinessPending = true;
    try {
      process.send?.({ type: 'ready', ready: await getProvider().ready() });
    } catch (error) {
      process.send?.({ type: 'ready', ready: false, error: error.message });
    } finally {
      readinessPending = false;
    }
  };
  reportReadiness();
  const readinessTimer = setInterval(reportReadiness, 5_000);
  readinessTimer.unref();
}

module.exports = { transcribe };
