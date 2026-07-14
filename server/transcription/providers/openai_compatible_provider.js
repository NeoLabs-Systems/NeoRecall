'use strict';

const fs = require('node:fs');
const { TranscriptionProvider } = require('../transcription_provider');
const { getConfig } = require('../../config');

class OpenAICompatibleProvider extends TranscriptionProvider {
  async ready() { return Boolean(getConfig().transcriptionApiBaseUrl); }
  async transcribe({ filename }) {
    const config = getConfig();
    if (!config.transcriptionApiBaseUrl) throw Object.assign(new Error('TRANSCRIPTION_API_BASE_URL is not configured.'), { code: 'TRANSCRIPTION_PROVIDER_NOT_CONFIGURED' });
    const bytes = fs.readFileSync(filename);
    const form = new FormData();
    form.append('file', new Blob([bytes]), 'chunk.audio');
    form.append('model', process.env.TRANSCRIPTION_API_MODEL || 'whisper-1');
    form.append('response_format', 'verbose_json');
    const response = await fetch(`${config.transcriptionApiBaseUrl.replace(/\/$/, '')}/v1/audio/transcriptions`, {
      method: 'POST', headers: config.transcriptionApiKey ? { Authorization: `Bearer ${config.transcriptionApiKey}` } : {}, body: form,
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(payload.error?.message || `Transcription endpoint returned HTTP ${response.status}.`), { code: 'TRANSCRIPTION_HTTP_ERROR', status: response.status });
    const raw = payload.segments?.length ? payload.segments : [{ start: 0, end: payload.duration || 0, text: payload.text || '' }];
    return raw.filter((segment) => String(segment.text || '').trim()).map((segment) => ({
      text: String(segment.text).trim(), language: payload.language || null, startMs: Math.round(segment.start * 1000),
      endMs: Math.round(segment.end * 1000), sourceComponent: 'combined', asrConfidence: segment.avg_logprob ?? null,
      diarizationSpeaker: null, speakerEmbedding: null, speakerConfidence: null, overlappingSpeech: false,
    }));
  }
}

module.exports = { OpenAICompatibleProvider };
