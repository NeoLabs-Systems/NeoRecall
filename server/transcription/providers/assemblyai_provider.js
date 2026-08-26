'use strict';

const fs = require('node:fs');
const { TranscriptionProvider } = require('../transcription_provider');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function normalizedSegments(payload) {
  if (Array.isArray(payload.utterances) && payload.utterances.length) {
    return payload.utterances.filter((item) => String(item.text || '').trim()).map((item) => ({
      text: String(item.text).trim(), language: payload.language_code || null,
      startMs: Math.round(item.start || 0), endMs: Math.round(item.end || item.start || 0),
      sourceComponent: 'combined', asrConfidence: item.confidence ?? null, diarizationSpeaker: item.speaker ?? null,
      speakerEmbedding: null, speakerConfidence: null, overlappingSpeech: false,
    }));
  }
  const words = payload.words || [];
  const text = String(payload.text || '').trim();
  return text ? [{
    text, language: payload.language_code || null, startMs: Math.round(words[0]?.start || 0),
    endMs: Math.round(words.at(-1)?.end || words[0]?.start || 0), sourceComponent: 'combined',
    asrConfidence: payload.confidence ?? null, diarizationSpeaker: null, speakerEmbedding: null,
    speakerConfidence: null, overlappingSpeech: false,
  }] : [];
}

class AssemblyAIProvider extends TranscriptionProvider {
  async ready() {
    const settings = providerSettings.getRuntime().transcription;
    return Boolean(settings.baseUrl && settings.apiKey);
  }

  async request(url, options, deadline) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw Object.assign(new Error('The AssemblyAI transcription request timed out.'), { code: 'TRANSCRIPTION_TIMEOUT' });
    const response = await fetch(url, { ...options, signal: AbortSignal.timeout(remaining) });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(payload.error || `AssemblyAI returned HTTP ${response.status}.`), { code: 'TRANSCRIPTION_HTTP_ERROR', status: response.status });
    return payload;
  }

  async transcribe({ filename }) {
    const config = getConfig();
    const settings = providerSettings.getRuntime().transcription;
    if (!settings.baseUrl || !settings.apiKey) {
      throw Object.assign(new Error('AssemblyAI requires a base URL and API key.'), { code: 'TRANSCRIPTION_PROVIDER_NOT_CONFIGURED' });
    }
    const headers = { Authorization: settings.apiKey };
    const deadline = Date.now() + config.transcriptionTimeoutMs;
    const uploaded = await this.request(`${settings.baseUrl}/v2/upload`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/octet-stream' }, body: fs.readFileSync(filename),
    }, deadline);
    const submitted = await this.request(`${settings.baseUrl}/v2/transcript`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ audio_url: uploaded.upload_url, ...(settings.model ? { speech_models: [settings.model] } : {}) }),
    }, deadline);
    let transcript = submitted;
    while (!['completed', 'error'].includes(transcript.status)) {
      await sleep(Math.min(config.transcriptionPollIntervalMs, Math.max(0, deadline - Date.now())));
      transcript = await this.request(`${settings.baseUrl}/v2/transcript/${submitted.id}`, { headers }, deadline);
    }
    if (transcript.status === 'error') throw Object.assign(new Error(transcript.error || 'AssemblyAI could not transcribe the audio.'), { code: 'TRANSCRIPTION_PROVIDER_ERROR', retryable: false });
    return normalizedSegments(transcript);
  }
}

module.exports = { AssemblyAIProvider, normalizedSegments };
