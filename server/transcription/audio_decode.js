'use strict';

const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getConfig } = require('../config');

function channelCount(layout) {
  if (layout === 'mono') return 1;
  if (['stereo', 'microphone_left_system_right'].includes(layout)) return 2;
  throw Object.assign(new Error(`Unsupported channel layout: ${layout}`), { code: 'UNSUPPORTED_CHANNEL_LAYOUT' });
}

function decodeAudio(filename, layout) {
  const channels = channelCount(layout);
  const result = spawnSync(ffmpegPath, ['-v', 'error', '-i', filename, '-vn', '-ac', String(channels), '-ar', '16000', '-f', 'f32le', 'pipe:1'], {
    encoding: null, maxBuffer: getConfig().maxUploadBytes * 8,
  });
  if (result.status !== 0) {
    const error = new Error(`ffmpeg could not decode the chunk: ${String(result.stderr || '').slice(0, 500)}`);
    error.code = 'AUDIO_DECODE_FAILED'; throw error;
  }
  const raw = new Float32Array(result.stdout.buffer, result.stdout.byteOffset, Math.floor(result.stdout.byteLength / 4));
  if (channels === 1) return [{ name: 'combined', samples: new Float32Array(raw), sampleRate: 16000 }];
  const left = new Float32Array(Math.floor(raw.length / 2));
  const right = new Float32Array(left.length);
  for (let index = 0; index < left.length; index += 1) { left[index] = raw[index * 2]; right[index] = raw[index * 2 + 1]; }
  const names = layout === 'microphone_left_system_right' ? ['microphone', 'system'] : ['left', 'right'];
  return [{ name: names[0], samples: left, sampleRate: 16000 }, { name: names[1], samples: right, sampleRate: 16000 }];
}

module.exports = { decodeAudio, channelCount };
