'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getConfig } = require('../../config');

function parseWav(file) {
  const bytes = require('../../utils/sealed_fs').readFileSync(file);
  if (bytes.length < 44 || bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') {
    return null;
  }
  let offset = 12;
  let sampleRate;
  let byteRate;
  let channels;
  let blockAlign;
  let dataStart;
  let dataSize;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ' && size >= 16) {
      channels = bytes.readUInt16LE(offset + 10);
      sampleRate = bytes.readUInt32LE(offset + 12);
      byteRate = bytes.readUInt32LE(offset + 16);
      blockAlign = bytes.readUInt16LE(offset + 20);
    }
    if (id === 'data') {
      dataStart = offset + 8;
      dataSize = size;
      break;
    }
    offset += 8 + size + (size % 2);
  }
  if (!byteRate || !channels || dataStart === undefined) return null;
  const end = Math.min(bytes.length, dataStart + dataSize);
  return {
    pcm: bytes.subarray(dataStart, end),
    sampleRate: sampleRate || 16000,
    channels,
    byteRate,
    blockAlign: blockAlign || channels * 2,
  };
}

function wrapWav(pcm, sampleRate, channels) {
  const blockAlign = channels * 2;
  const byteRate = sampleRate * blockAlign;
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(16, 34);
  header.write('data', 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function skipOverlap(pcm, byteRate, blockAlign, overlapMs) {
  if (!overlapMs || overlapMs <= 0) return pcm;
  const skip = Math.min(pcm.length, Math.floor((overlapMs / 1000) * byteRate));
  return pcm.subarray(skip - (skip % Math.max(1, blockAlign)));
}

function concatWavParts(parts, dest) {
  let sampleRate;
  let channels;
  let byteRate;
  let blockAlign;
  const pcmParts = [];
  for (let index = 0; index < parts.length; index += 1) {
    const wav = parseWav(parts[index].file);
    if (!wav) return false;
    if (!sampleRate) {
      sampleRate = wav.sampleRate;
      channels = wav.channels;
      byteRate = wav.byteRate;
      blockAlign = wav.blockAlign;
    } else if (wav.sampleRate !== sampleRate || wav.channels !== channels) {
      return false;
    }
    const pcm = index === 0 ? wav.pcm : skipOverlap(wav.pcm, byteRate, blockAlign, parts[index].overlapMs);
    pcmParts.push(pcm);
  }
  fs.writeFileSync(dest, wrapWav(Buffer.concat(pcmParts), sampleRate, channels), { mode: 0o600 });
  return true;
}

function concatListPath(file) {
  return `'${String(file).replace(/'/g, "'\\''")}'`;
}

function concatWithFfmpeg(parts, dest) {
  if (!ffmpegPath) throw new Error('ffmpeg is not available to join a recording.');
  const sealedFs = require('../../utils/sealed_fs');
  const opened = parts.map((part) => ({ part, file: sealedFs.materialize(part.file) }));
  const listFile = `${dest}.concat.txt`;
  const lines = [];
  for (let index = 0; index < opened.length; index += 1) {
    lines.push(`file ${concatListPath(opened[index].file.path)}`);
    if (index > 0 && opened[index].part.overlapMs > 0) {
      lines.push(`inpoint ${(opened[index].part.overlapMs / 1000).toFixed(3)}`);
    }
  }
  fs.writeFileSync(listFile, `${lines.join('\n')}\n`, { mode: 0o600 });
  try {
    const result = spawnSync(ffmpegPath, [
      '-hide_banner', '-y', '-f', 'concat', '-safe', '0', '-i', listFile,
      '-c:a', 'pcm_s16le', dest,
    ], { encoding: 'utf8', timeout: getConfig().cloudConcatTimeoutMs });
    if (result.status !== 0 || !fs.existsSync(dest) || !fs.statSync(dest).size) {
      throw new Error(`ffmpeg could not join the recording: ${String(result.stderr || result.error || '').slice(0, 500)}`);
    }
    fs.chmodSync(dest, 0o600);
  } finally {
    try { fs.unlinkSync(listFile); } catch { /* the joined file is what matters */ }
    for (const item of opened) item.file.cleanup();
  }
}

function concatRecording(parts, dest) {
  if (!parts.length) throw new Error('A recording assembly has no audio parts.');
  fs.mkdirSync(path.dirname(dest), { recursive: true, mode: 0o700 });
  if (concatWavParts(parts, dest)) return dest;
  concatWithFfmpeg(parts, dest);
  return dest;
}

module.exports = { concatRecording, parseWav, wrapWav };
