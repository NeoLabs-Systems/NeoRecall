'use strict';

const { decodeAudio } = require('../transcription/audio_decode');
const { getProvider } = require('../transcription/provider_registry');
const { createLogger } = require('../utils/logger');

const logger = createLogger('inference-host');

async function transcribe(input) {
  const provider = getProvider();
  const components = input.provider === 'sherpa' ? decodeAudio(input.filename, input.channelLayout) : undefined;
  return provider.transcribe({ filename: input.filename, components, channelLayout: input.channelLayout });
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
  Promise.resolve(getProvider().ready()).then((ready) => process.send?.({ type: 'ready', ready })).catch((error) => process.send?.({ type: 'ready', ready: false, error: error.message }));
}

module.exports = { transcribe };
