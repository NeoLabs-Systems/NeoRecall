'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { TranscriptionProvider } = require('../transcription_provider');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

const AUDIO_TYPES = Object.freeze({
  '.flac': 'audio/flac', '.mp3': 'audio/mpeg', '.mp4': 'audio/mp4', '.mpeg': 'audio/mpeg',
  '.mpga': 'audio/mpeg', '.m4a': 'audio/mp4', '.ogg': 'audio/ogg', '.wav': 'audio/wav', '.webm': 'audio/webm',
});

function normalizedSegments(payload) {
  const raw = payload.segments?.length ? payload.segments : [{ start: 0, end: payload.duration || 0, text: payload.text || '' }];
  return raw.filter((segment) => String(segment.text || '').trim()).map((segment) => ({
    text: String(segment.text).trim(), language: payload.language || null, startMs: Math.round((segment.start || 0) * 1000),
    endMs: Math.round((segment.end || segment.start || 0) * 1000), sourceComponent: 'combined', asrConfidence: segment.avg_logprob ?? null,
    diarizationSpeaker: segment.speaker ?? null, speakerEmbedding: null, speakerConfidence: null, overlappingSpeech: false,
  }));
}

function transcriptionEndpoint(value) {
  const url = new URL(value);
  if (url.pathname.replace(/\/+$/, '').endsWith('/audio/transcriptions')) return url.toString().replace(/\/$/, '');
  url.pathname = `${url.pathname.replace(/\/+$/, '')}/audio/transcriptions`;
  return url.toString();
}

class OpenAICompatibleProvider extends TranscriptionProvider {
  async ready() {
    const settings = providerSettings.getRuntime().transcription;
    const definition = providerSettings.TRANSCRIPTION_PROVIDERS[settings.provider];
    return Boolean(settings.baseUrl && (definition.modelOptional || settings.model) && (!definition.requiresApiKey || settings.apiKey));
  }
  async transcribe({ filename }) {
    const config = getConfig();
    const settings = providerSettings.getRuntime().transcription;
    const definition = providerSettings.TRANSCRIPTION_PROVIDERS[settings.provider];
    if (!settings.baseUrl || (!definition.modelOptional && !settings.model)) throw Object.assign(new Error('The transcription endpoint is not fully configured.'), { code: 'TRANSCRIPTION_PROVIDER_NOT_CONFIGURED' });
    const bytes = fs.readFileSync(filename);
    const extension = path.extname(filename).toLowerCase();
    const form = new FormData();
    form.append('file', new Blob([bytes], { type: AUDIO_TYPES[extension] || 'application/octet-stream' }), `chunk${extension || '.wav'}`);
    if (settings.model) form.append('model', settings.model);
    if (settings.language) form.append('language', settings.language);
    form.append('response_format', settings.responseFormat);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.transcriptionTimeoutMs);
    try {
      const response = await fetch(transcriptionEndpoint(settings.baseUrl), {
        method: 'POST', signal: controller.signal,
        headers: settings.apiKey ? { Authorization: `Bearer ${settings.apiKey}` } : {}, body: form,
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw Object.assign(new Error(payload.error?.message || `Transcription endpoint returned HTTP ${response.status}.`), { code: 'TRANSCRIPTION_HTTP_ERROR', status: response.status });
      return normalizedSegments(payload);
    } catch (error) {
      if (error.name === 'AbortError') throw Object.assign(new Error('The transcription request timed out.'), { code: 'TRANSCRIPTION_TIMEOUT' });
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
}

module.exports = { OpenAICompatibleProvider, normalizedSegments, transcriptionEndpoint };
