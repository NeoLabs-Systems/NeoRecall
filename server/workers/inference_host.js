'use strict';

const { getProvider } = require('../transcription/provider_registry');
const localAnalysis = require('../transcription/local_analysis');
const { alignSegments } = require('../transcription/speaker_alignment');
const { createLogger } = require('../utils/logger');

const logger = createLogger('inference-host');

/// Turns one chunk of audio into transcript segments that know who was speaking.
///
/// Two things happen to the same seconds of audio, and the order matters. The
/// local pass runs first because it can end the job: a chunk the voice detector
/// finds no speech in is silence, and silence is never sent anywhere. On a
/// recorder left running all day that is most of the day, and skipping it is the
/// difference between paying to transcribe a conversation and paying to
/// transcribe a room.
///
/// When there is speech, the file goes to the transcription service unaltered —
/// it is far better at deciding where a sentence begins than any cut this
/// process could make — and comes back as segments on the chunk's own timeline.
/// The local diarizer has meanwhile produced speaker turns on that same
/// timeline, so the two are joined by overlap: each segment takes the voice it
/// most overlaps with, and its embedding with it. That embedding is the whole
/// point. It is what a service cannot give back, and what lets the same voice be
/// recognised in a recording made next week.
///
/// The native runtime and its models are both optional. Without them the chunk
/// is transcribed exactly as before and the segments simply carry no speaker —
/// a transcript with no names is worth far more than no transcript.
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
