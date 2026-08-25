'use strict';

const { getProvider } = require('../transcription/provider_registry');
const { createLogger } = require('../utils/logger');

const logger = createLogger('inference-host');

async function transcribe(input) {
  const provider = getProvider();
  return provider.transcribe({ filename: input.filename, channelLayout: input.channelLayout });
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
