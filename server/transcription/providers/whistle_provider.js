'use strict';

const { TranscriptionProvider } = require('../transcription_provider');
const { buildSegments } = require('../segment');
const { decodeAudio } = require('../audio_decode');
const { planWindows } = require('../local_asr/windowing');
const { wordsToSegments } = require('../local_asr/word_segments');
const localAsr = require('../local_asr');
const { notReadyReason } = require('../../local_runtime/not_ready_reason');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('whistle');
const SAMPLE_BYTES = 4;
let warnedLanguage = null;

// Speech recognition on this server, by the Whistle model.
//
// It takes the place of an external service behind the same contract: audio in,
// timestamped segments out. Everything around it — conditioning, silence
// detection, speaker alignment, vocabulary correction, persistence — is the
// shared pipeline and is unaware which provider answered.
//
// Whistle reads at most 30 s per pass and returns words, so this adapter does
// the two things a service would have done for it: it cuts a long chunk into
// windows and it groups the words back into segments.
class WhistleProvider extends TranscriptionProvider {
  constructor({ asr = localAsr } = {}) {
    super();
    this.asr = asr;
  }

  get metered() { return false; }

  // Stops the worker when the operator switches to another provider.
  dispose() { return this.asr.reset(); }

  // True only when the model is installed *and* a worker has loaded it. Being
  // asked is also what keeps the system moving: an absent runtime begins
  // installing, and a stopped worker is started. The worker manager polls this
  // and holds back transcription jobs until it is true, so audio is never leased
  // for a model that cannot read it.
  async ready() {
    const installer = this.asr.getInstaller();
    if (!installer.supported) return false;
    if (!installer.isInstalled()) {
      installer.ensureInstalled();
      return false;
    }
    const runtime = this.asr.getRuntime();
    runtime.ensureStarted();
    await runtime.whenSettled();
    if (!runtime.isReady()) return false;
    await runtime.healthCheck();
    return runtime.isReady();
  }

  notReadyReason() {
    return notReadyReason(this.asr.getInstaller().status())
      || this.asr.getRuntime().lastError?.message || 'The Whistle worker is starting.';
  }

  async fetchSegments({ filename, vocabulary = [] }) {
    const config = getConfig();
    const runtime = this.asr.getRuntime();
    if (!runtime.isReady()) {
      throw Object.assign(new Error(this.notReadyReason()), { code: 'LOCAL_ASR_UNAVAILABLE', retryable: true });
    }
    const language = this.language();
    const keywords = vocabulary.slice(0, config.localAsrKeywordLimit);
    const samples = decodeAudio(filename, 'mono')[0].samples;
    const segments = [];
    for (const window of planWindows(samples, { windowMs: config.localAsrWindowMs, searchMs: config.localAsrSplitSearchMs })) {
      const bytes = Buffer.from(samples.buffer, samples.byteOffset + window.startSample * SAMPLE_BYTES, (window.endSample - window.startSample) * SAMPLE_BYTES);
      const result = await runtime.transcribe({ samples: bytes.toString('base64'), language, keywords, wordTimestamps: true });
      segments.push(...wordsToSegments(result.words || [], {
        offsetMs: (window.startSample / 16_000) * 1000,
        language: result.language || language || null,
        gapMs: config.localAsrSegmentGapMs, maxMs: config.localAsrSegmentMaxMs,
      }));
    }
    return buildSegments(segments);
  }

  // The configured language when the model can read it; otherwise the model
  // detects it. A language outside the model's set would fail every chunk, which
  // is worse than reading it imperfectly, so it is said once and not applied.
  language() {
    const configured = providerSettings.getRuntime().transcription.language;
    if (!configured) return null;
    const supported = this.asr.getInstaller().languages();
    const code = String(configured).toLowerCase().split(/[-_]/)[0];
    if (supported.includes(code)) return code;
    if (warnedLanguage !== configured) {
      warnedLanguage = configured;
      logger.warn('The configured transcription language is not supported by Whistle; detecting it instead', { language: configured, supported });
    }
    return null;
  }
}

module.exports = { WhistleProvider };
