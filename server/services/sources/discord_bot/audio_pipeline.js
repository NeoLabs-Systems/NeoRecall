'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Readable, pipeline } = require('stream');
const prism = require('prism-media');
const { createAudioResource, StreamType } = require('@discordjs/voice');

// Discord always sends 48kHz stereo Opus in 20ms (960-sample) frames.
const SAMPLE_RATE = 48000;
const CHANNELS = 2;
const FRAME_SIZE = 960;

// A minimal WAV header is 44 bytes; anything at or below that carries no audio.
const WAV_HEADER_BYTES = 44;

/**
 * Transcode a Discord Opus stream into a temporary WAV file (PCM s16le, 48kHz
 * stereo). Resolves with `{ path, size }`; the caller owns the file. Rejects if
 * the ffmpeg/decoder pipeline fails, cleaning up the partial file first.
 *
 * @param {import('stream').Readable} opusStream Raw Opus packet stream from the voice receiver.
 * @returns {Promise<{ path: string, size: number }>}
 */
function opusStreamToWav(opusStream) {
  return new Promise((resolve, reject) => {
    const tempPath = path.join(os.tmpdir(), `discord-${crypto.randomUUID()}.wav`);
    const decoder = new prism.opus.Decoder({ frameSize: FRAME_SIZE, channels: CHANNELS, rate: SAMPLE_RATE });
    // prism.FFmpeg auto-appends 'pipe:1' as the output (see prism-media
    // core/FFmpeg.js). Do NOT add 'pipe:1' here or ffmpeg receives two outputs
    // ('-f wav pipe:1 pipe:1'), the second has no format, ffmpeg exits, and the
    // pipeline dies with `write EPIPE`.
    const encoder = new prism.FFmpeg({
      args: ['-f', 's16le', '-ar', String(SAMPLE_RATE), '-ac', String(CHANNELS), '-i', 'pipe:0', '-f', 'wav'],
    });
    const fileStream = fs.createWriteStream(tempPath);

    pipeline(opusStream, decoder, encoder, fileStream, (err) => {
      if (err) {
        fs.promises.unlink(tempPath).catch(() => {});
        reject(err);
        return;
      }
      let size = 0;
      try {
        size = fs.statSync(tempPath).size;
      } catch (statErr) {
        reject(statErr);
        return;
      }
      resolve({ path: tempPath, size });
    });
  });
}

/**
 * Discord only delivers inbound audio to clients that are themselves
 * transmitting. This produces an endless stream of Opus silence so the
 * connection keeps its UDP path open and the receiver keeps getting packets.
 *
 * @returns {import('@discordjs/voice').AudioResource}
 */
function createSilenceResource() {
  const silence = new Readable({
    read() {
      // 20ms of s16le stereo silence per frame.
      this.push(Buffer.alloc(FRAME_SIZE * CHANNELS * 2));
    },
  });
  return createAudioResource(silence, { inputType: StreamType.Raw });
}

/**
 * Compute the SHA-256 hex digest of a file without loading it fully into memory.
 *
 * @param {string} filePath
 * @returns {Promise<string>}
 */
function hashFile(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

module.exports = {
  SAMPLE_RATE,
  CHANNELS,
  FRAME_SIZE,
  WAV_HEADER_BYTES,
  opusStreamToWav,
  createSilenceResource,
  hashFile,
};
