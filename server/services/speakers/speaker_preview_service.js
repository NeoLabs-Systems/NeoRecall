'use strict';

const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const voiceprintStorage = require('../../transcription/voiceprint_storage');

function channelIndex(layout, sourceComponent) {
  if (!['stereo', 'microphone_left_system_right'].includes(layout)) return 0;
  if (layout === 'microphone_left_system_right') return sourceComponent === 'system' ? 1 : 0;
  return sourceComponent === 'right' ? 1 : 0;
}

function selectTurns(turns) {
  const { speakerPreviewMinimumMs, speakerPreviewMaximumMs } = getConfig();
  const ranked = [...turns]
    .filter((turn) => !turn.overlapping_speech && turn.end_ms > turn.start_ms)
    .sort((left, right) => {
      const quality = Number(right.quality || 0) - Number(left.quality || 0);
      if (quality !== 0) return quality;
      return (right.end_ms - right.start_ms) - (left.end_ms - left.start_ms);
    });
  const selected = [];
  let durationMs = 0;
  for (const turn of ranked) {
    if (durationMs >= speakerPreviewMaximumMs) break;
    const available = turn.end_ms - turn.start_ms;
    const used = Math.min(available, speakerPreviewMaximumMs - durationMs);
    if (used <= 0) continue;
    selected.push({ ...turn, end_ms: turn.start_ms + used });
    durationMs += used;
  }
  if (durationMs < speakerPreviewMinimumMs) return null;
  return {
    turns: selected.sort((left, right) => left.start_ms - right.start_ms),
    durationMs,
    quality:
      selected.reduce(
        (sum, turn) =>
          sum +
          Number(turn.quality || 0) *
            Math.max(1, turn.end_ms - turn.start_ms),
        0,
      ) / durationMs,
  };
}

function extractPreview(filename, channelLayout, selection) {
  const filters = selection.turns.map((turn, index) => {
    const start = (turn.start_ms / 1000).toFixed(3);
    const end = (turn.end_ms / 1000).toFixed(3);
    const channel = channelIndex(channelLayout, turn.source_component);
    return `[0:a]atrim=start=${start}:end=${end},asetpts=PTS-STARTPTS,pan=mono|c0=c${channel}[p${index}]`;
  });
  const inputs = selection.turns.map((_, index) => `[p${index}]`).join('');
  filters.push(`${inputs}concat=n=${selection.turns.length}:v=0:a=1[out]`);
  const result = spawnSync(
    ffmpegPath,
    [
      '-v',
      'error',
      '-i',
      filename,
      '-filter_complex',
      filters.join(';'),
      '-map',
      '[out]',
      '-ar',
      '16000',
      '-c:a',
      'pcm_s16le',
      '-f',
      'wav',
      'pipe:1',
    ],
    { encoding: null, maxBuffer: getConfig().speakerPreviewMaxBytes },
  );
  if (result.status !== 0 || !result.stdout?.length) {
    const error = new Error(
      `ffmpeg could not create the speaker preview: ${String(result.stderr || '').slice(0, 500)}`,
    );
    error.code = 'SPEAKER_PREVIEW_FAILED';
    throw error;
  }
  const output = Buffer.from(result.stdout);
  if (
    output.length >= 44 &&
    output.toString('ascii', 0, 4) === 'RIFF' &&
    output.toString('ascii', 8, 12) === 'WAVE'
  ) {
    output.writeUInt32LE(output.length - 8, 4);
    const dataOffset = output.indexOf(Buffer.from('data'), 12);
    if (dataOffset >= 0 && dataOffset + 8 <= output.length) {
      output.writeUInt32LE(output.length - dataOffset - 8, dataOffset + 4);
    }
  }
  return output;
}

function wavAudio(bytes) {
  if (!bytes || bytes.length < 44) return null;
  let offset = 12;
  let byteRate;
  let sampleRate;
  let dataStart;
  let dataSize;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ') {
      sampleRate = bytes.readUInt32LE(offset + 12);
      byteRate = bytes.readUInt32LE(offset + 16);
    }
    if (id === 'data') {
      dataStart = offset + 8;
      dataSize = size;
      break;
    }
    offset += 8 + size + (size % 2);
  }
  if (!byteRate || dataStart === undefined) return null;
  const end = Math.min(bytes.length, dataStart + dataSize);
  return {
    pcm: bytes.subarray(dataStart, end),
    byteRate,
    sampleRate: sampleRate || 16000,
  };
}

function wavDurationMs(bytes) {
  const audio = wavAudio(bytes);
  if (!audio) return 0;
  return Math.floor((audio.pcm.length / audio.byteRate) * 1000);
}

function wrapMonoPcmWav(pcm, sampleRate = 16000) {
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write('data', 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

// Original chunk audio is deleted after persist, so later chunks cannot
// re-extract earlier speech. Concatenate the already-stored clip with this
// chunk's excerpt, capped at the configured maximum.
function concatPreviewAudio(first, second, maxDurationMs) {
  const left = wavAudio(first);
  const right = wavAudio(second);
  if (!left || !right) {
    const error = new Error('Speaker preview audio is not a readable WAV clip.');
    error.code = 'SPEAKER_PREVIEW_FAILED';
    throw error;
  }
  const sampleRate = left.sampleRate || 16000;
  const maxPcmBytes = Math.floor((maxDurationMs / 1000) * sampleRate) * 2;
  const remaining = Math.max(0, maxPcmBytes - left.pcm.length);
  const take = remaining ? right.pcm.subarray(0, remaining - (remaining % 2)) : Buffer.alloc(0);
  return wrapMonoPcmWav(Buffer.concat([left.pcm, take]), sampleRate);
}

function capSelection(selection, remainingMs) {
  if (!selection || remainingMs <= 0) return null;
  if (selection.durationMs <= remainingMs) return selection;
  let used = 0;
  const turns = [];
  for (const turn of selection.turns) {
    if (used >= remainingMs) break;
    const available = turn.end_ms - turn.start_ms;
    const take = Math.min(available, remainingMs - used);
    if (take <= 0) continue;
    turns.push({ ...turn, end_ms: turn.start_ms + take });
    used += take;
  }
  if (used <= 0) return null;
  const quality = turns.reduce(
    (sum, turn) => sum + Number(turn.quality || 0) * Math.max(1, turn.end_ms - turn.start_ms),
    0,
  ) / used;
  return { turns, durationMs: used, quality };
}

function candidatesForChunk(database, chunkId) {
  return database
    .prepare(
      `SELECT st.voiceprint_id,st.start_ms,st.end_ms,st.quality,st.overlapping_speech,
        COALESCE(ts.source_component,'combined') source_component
       FROM speaker_turns st
       LEFT JOIN transcript_segments ts
         ON ts.chunk_id=st.chunk_id
        AND ts.speaker_cluster_id=st.cluster_id
        AND ts.chunk_start_ms=st.start_ms
        AND ts.chunk_end_ms=st.end_ms
       WHERE st.chunk_id=? AND st.voiceprint_id IS NOT NULL
       ORDER BY st.start_ms`,
    )
    .all(chunkId);
}

function shouldReplacePreview(current, selection, targetDurationMs) {
  if (!current) return true;
  const currentIsFull = current.duration_ms >= targetDurationMs;
  const selectionIsFull = selection.durationMs >= targetDurationMs;
  if (currentIsFull !== selectionIsFull) return selectionIsFull;
  return selection.quality > Number(current.quality);
}

function storePreview(database, { voiceprintId, userId, audio, durationMs, quality }) {
  const { speakerPreviewMinimumMs, speakerPreviewMaximumMs } = getConfig();
  const clamped = Math.max(speakerPreviewMinimumMs, Math.min(speakerPreviewMaximumMs, durationMs));
  database
    .prepare(
      `INSERT INTO speaker_previews
        (voiceprint_id,user_id,audio,content_type,duration_ms,quality)
       VALUES (?,?,?,'audio/wav',?,?)
       ON CONFLICT(voiceprint_id) DO UPDATE SET
         audio=excluded.audio,
         content_type=excluded.content_type,
         duration_ms=excluded.duration_ms,
         quality=excluded.quality,
         updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
    )
    .run(voiceprintId, userId, voiceprintStorage.sealPreviewAudio(audio), clamped, quality);
}

function captureFromChunk(chunk) {
  if (!chunk?.temporary_path) return 0;
  const database = getDatabase();
  const grouped = new Map();
  for (const turn of candidatesForChunk(database, chunk.id)) {
    const turns = grouped.get(turn.voiceprint_id) || [];
    turns.push(turn);
    grouped.set(turn.voiceprint_id, turns);
  }
  let captured = 0;
  const targetDurationMs = getConfig().speakerPreviewMaximumMs;
  for (const [voiceprintId, turns] of grouped) {
    const selection = selectTurns(turns);
    if (!selection) continue;
    const current = database
      .prepare('SELECT duration_ms,quality,audio FROM speaker_previews WHERE voiceprint_id=?')
      .get(voiceprintId);

    let audio;
    let durationMs;
    let quality;
    const existing = current ? voiceprintStorage.readPreviewAudio(current.audio) : null;
    const currentMs = existing ? (wavDurationMs(existing) || current.duration_ms) : 0;

    if (!current) {
      audio = extractPreview(chunk.temporary_path, chunk.channel_layout, selection);
      durationMs = wavDurationMs(audio) || selection.durationMs;
      quality = selection.quality;
    } else if (currentMs >= targetDurationMs) {
      if (!shouldReplacePreview({ ...current, duration_ms: currentMs }, selection, targetDurationMs)) continue;
      audio = extractPreview(chunk.temporary_path, chunk.channel_layout, selection);
      durationMs = wavDurationMs(audio) || selection.durationMs;
      quality = selection.quality;
    } else if (selection.durationMs >= targetDurationMs) {
      audio = extractPreview(chunk.temporary_path, chunk.channel_layout, selection);
      durationMs = wavDurationMs(audio) || selection.durationMs;
      quality = selection.quality;
    } else {
      const remainingMs = targetDurationMs - currentMs;
      // Ask for a little extra so a short ffmpeg atrim cannot leave the clip
      // just under the Speakers display floor; concat still caps at the max.
      const addition = capSelection(selection, remainingMs + 100);
      if (!addition) continue;
      const extra = extractPreview(chunk.temporary_path, chunk.channel_layout, addition);
      audio = concatPreviewAudio(existing, extra, targetDurationMs);
      durationMs = wavDurationMs(audio);
      if (durationMs <= currentMs) continue;
      const addedMs = durationMs - currentMs;
      quality = (Number(current.quality) * currentMs + addition.quality * addedMs) / durationMs;
    }

    storePreview(database, {
      voiceprintId,
      userId: chunk.user_id,
      audio,
      durationMs,
      quality,
    });
    captured += 1;
  }
  return captured;
}

// Returns the preview with playable audio. This is the only path that unseals a
// clip, and it is already scoped to the owning account twice over.
function get(userId, voiceprintId) {
  const row = getDatabase()
    .prepare(
      `SELECT p.* FROM speaker_previews p
       JOIN voiceprints v ON v.id=p.voiceprint_id
       WHERE p.voiceprint_id=? AND p.user_id=? AND v.user_id=?`,
    )
    .get(voiceprintId, userId, userId);
  return row ? { ...row, audio: voiceprintStorage.readPreviewAudio(row.audio) } : row;
}

module.exports = {
  selectTurns,
  extractPreview,
  concatPreviewAudio,
  wavDurationMs,
  captureFromChunk,
  get,
  shouldReplacePreview,
};
