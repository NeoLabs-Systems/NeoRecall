'use strict';

const fs = require('node:fs/promises');
const { TranscriptionProvider } = require('../transcription_provider');
const { buildSegments, secondsToMs } = require('../segment');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

function normalizedSegments(payload) {
  const utterances = payload?.results?.utterances;
  if (Array.isArray(utterances) && utterances.length) {
    return buildSegments(utterances.map((item) => ({
      text: item.transcript || '', language: item.language || null,
      startMs: secondsToMs(item.start), endMs: secondsToMs(item.end || item.start),
      asrConfidence: item.confidence ?? null, diarizationSpeaker: item.speaker ?? null,
    })));
  }
  const alternative = payload?.results?.channels?.[0]?.alternatives?.[0];
  const words = alternative?.words || [];
  const first = words[0];
  const last = words.at(-1);
  return buildSegments([{
    text: alternative?.transcript || '',
    language: alternative?.languages?.[0] || payload?.results?.channels?.[0]?.detected_language || null,
    startMs: secondsToMs(first?.start), endMs: secondsToMs(last?.end || first?.start),
    asrConfidence: alternative?.confidence ?? null,
  }]);
}

class DeepgramProvider extends TranscriptionProvider {
  async ready() {
    const settings = providerSettings.getRuntime().transcription;
    return Boolean(settings.baseUrl && settings.model && settings.apiKey);
  }

  async fetchSegments({ filename, vocabulary = [] }) {
    const config = getConfig();
    const settings = providerSettings.getRuntime().transcription;
    if (!settings.baseUrl || !settings.model || !settings.apiKey) {
      throw Object.assign(new Error('Deepgram requires a base URL, model, and API key.'), { code: 'TRANSCRIPTION_PROVIDER_NOT_CONFIGURED' });
    }
    const url = new URL(`${settings.baseUrl}/v1/listen`);
    url.searchParams.set('model', settings.model);
    url.searchParams.set('smart_format', 'true');
    url.searchParams.set('utterances', 'true');
    url.searchParams.set('detect_language', 'true');
    const vocabularyParameter = /^nova-3(?:$|-)/i.test(settings.model) ? 'keyterm' : 'keywords';
    for (const term of vocabulary) url.searchParams.append(vocabularyParameter, term);
    try {
      const response = await fetch(url, {
        method: 'POST', signal: AbortSignal.timeout(config.transcriptionTimeoutMs),
        headers: { Authorization: `Token ${settings.apiKey}`, 'Content-Type': 'application/octet-stream' },
        body: await fs.readFile(filename),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw Object.assign(new Error(payload?.err_msg || payload?.error || `Deepgram returned HTTP ${response.status}.`), { code: 'TRANSCRIPTION_HTTP_ERROR', status: response.status });
      return normalizedSegments(payload);
    } catch (error) {
      if (error.name === 'AbortError' || error.name === 'TimeoutError') {
        throw Object.assign(new Error('The Deepgram transcription request timed out.'), { code: 'TRANSCRIPTION_TIMEOUT' });
      }
      throw error;
    }
  }
}

module.exports = { DeepgramProvider, normalizedSegments };
