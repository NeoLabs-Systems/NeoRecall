'use strict';

const fs = require('node:fs/promises');
const { TranscriptionProvider } = require('../transcription_provider');
const { buildSegments } = require('../segment');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function normalizedSegments(payload) {
  if (Array.isArray(payload.utterances) && payload.utterances.length) {
    return buildSegments(payload.utterances.map((item) => ({
      text: item.text || '', language: payload.language_code || null,
      startMs: item.start, endMs: item.end || item.start,
      asrConfidence: item.confidence ?? null, diarizationSpeaker: item.speaker ?? null,
    })));
  }
  const words = payload.words || [];
  return buildSegments([{
    text: payload.text || '', language: payload.language_code || null,
    startMs: words[0]?.start, endMs: words.at(-1)?.end || words[0]?.start,
    asrConfidence: payload.confidence ?? null,
  }]);
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

  async fetchSegments({ filename, vocabulary = [] }) {
    const config = getConfig();
    const settings = providerSettings.getRuntime().transcription;
    if (!settings.baseUrl || !settings.apiKey) {
      throw Object.assign(new Error('AssemblyAI requires a base URL and API key.'), { code: 'TRANSCRIPTION_PROVIDER_NOT_CONFIGURED' });
    }
    const headers = { Authorization: settings.apiKey };
    const deadline = Date.now() + config.transcriptionTimeoutMs;
    const uploaded = await this.request(`${settings.baseUrl}/v2/upload`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/octet-stream' }, body: await fs.readFile(filename),
    }, deadline);
    const submitted = await this.request(`${settings.baseUrl}/v2/transcript`, {
      method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ audio_url: uploaded.upload_url, ...(settings.model ? { speech_models: [settings.model] } : {}),
        ...(vocabulary.length ? { keyterms_prompt: vocabulary } : {}) }),
    }, deadline);
    let transcript = submitted;
    while (!['completed', 'error'].includes(transcript.status)) {
      // Never a zero-length wait: at the deadline the next request throws
      // TRANSCRIPTION_TIMEOUT, and polling flat out until it does would spin.
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw Object.assign(new Error('The AssemblyAI transcription request timed out.'), { code: 'TRANSCRIPTION_TIMEOUT' });
      await sleep(Math.min(config.transcriptionPollIntervalMs, remaining));
      transcript = await this.request(`${settings.baseUrl}/v2/transcript/${submitted.id}`, { headers }, deadline);
    }
    if (transcript.status === 'error') throw Object.assign(new Error(transcript.error || 'AssemblyAI could not transcribe the audio.'), { code: 'TRANSCRIPTION_PROVIDER_ERROR', retryable: false });
    return normalizedSegments(transcript);
  }
}

module.exports = { AssemblyAIProvider, normalizedSegments };
