'use strict';

const { getProvider } = require('../transcription/provider_registry');
const localAnalysis = require('../transcription/local_analysis');
const { alignSegments } = require('../transcription/speaker_alignment');
const { createLogger } = require('../utils/logger');

const logger = createLogger('inference-host');

// Turns one chunk of audio into transcript segments that know who was speaking.
// Runs local VAD/diarization first so silent chunks are never sent to the
// transcription service, then joins the returned segments to the local speaker
// turns by timestamp overlap. The native runtime and models are optional; without
// them the chunk is still transcribed, just without a speaker.
async function transcribe(input) {
  const analysis = localAnalysis.analyze(input.filename);
  if (!analysis.hasSpeech) return [];
  const segments = await getProvider().transcribe({ filename: input.filename, channelLayout: input.channelLayout });
  if (!analysis.analyzed || !analysis.turns.length) return segments;
  return alignSegments(segments, analysis.turns);
}

if (require.main === module) {
  process.on('message', async (message) => {
    if (!message || message.type !== 'transcribe') return;
    try {
      const segments = await transcribe(message.input);
      process.send?.({ type: 'result', requestId: message.requestId, segments });
    } catch (error) {
      logger.error('Inference request failed', { error });
      process.send?.({ type: 'error', requestId: message.requestId, error: { code: error.code || 'INFERENCE_FAILED', message: error.message, stack: error.stack } });
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
