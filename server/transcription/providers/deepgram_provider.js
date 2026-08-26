'use strict';

const fs = require('node:fs');
const { TranscriptionProvider } = require('../transcription_provider');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

function normalizedSegments(payload) {
  const utterances = payload?.results?.utterances;
  if (Array.isArray(utterances) && utterances.length) {
    return utterances.filter((item) => String(item.transcript || '').trim()).map((item) => ({
      text: String(item.transcript).trim(), language: item.language || null,
      startMs: Math.round((item.start || 0) * 1000), endMs: Math.round((item.end || item.start || 0) * 1000),
      sourceComponent: 'combined', asrConfidence: item.confidence ?? null, diarizationSpeaker: item.speaker ?? null,
      speakerEmbedding: null, speakerConfidence: null, overlappingSpeech: false,
    }));
  }
  const alternative = payload?.results?.channels?.[0]?.alternatives?.[0];
  const words = alternative?.words || [];
  const first = words[0];
  const last = words.at(-1);
  const text = String(alternative?.transcript || '').trim();
  return text ? [{
    text, language: alternative.languages?.[0] || payload?.results?.channels?.[0]?.detected_language || null,
    startMs: Math.round((first?.start || 0) * 1000), endMs: Math.round((last?.end || first?.start || 0) * 1000),
    sourceComponent: 'combined', asrConfidence: alternative.confidence ?? null, diarizationSpeaker: null,
    speakerEmbedding: null, speakerConfidence: null, overlappingSpeech: false,
  }] : [];
}

class DeepgramProvider extends TranscriptionProvider {
  async ready() {
    const settings = providerSettings.getRuntime().transcription;
    return Boolean(settings.baseUrl && settings.model && settings.apiKey);
  }

  async transcribe({ filename }) {
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
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.transcriptionTimeoutMs);
    try {
      const response = await fetch(url, {
        method: 'POST', signal: controller.signal,
        headers: { Authorization: `Token ${settings.apiKey}`, 'Content-Type': 'application/octet-stream' },
        body: fs.readFileSync(filename),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw Object.assign(new Error(payload?.err_msg || payload?.error || `Deepgram returned HTTP ${response.status}.`), { code: 'TRANSCRIPTION_HTTP_ERROR', status: response.status });
      return normalizedSegments(payload);
    } catch (error) {
      if (error.name === 'AbortError') throw Object.assign(new Error('The Deepgram transcription request timed out.'), { code: 'TRANSCRIPTION_TIMEOUT' });
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
}

module.exports = { DeepgramProvider, normalizedSegments };
