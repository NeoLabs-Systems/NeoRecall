'use strict';

const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

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
  for (const [voiceprintId, turns] of grouped) {
    const selection = selectTurns(turns);
    if (!selection) continue;
    const current = database
      .prepare('SELECT quality FROM speaker_previews WHERE voiceprint_id=?')
      .get(voiceprintId);
    if (current && Number(current.quality) >= selection.quality) continue;
    const audio = extractPreview(
      chunk.temporary_path,
      chunk.channel_layout,
      selection,
    );
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
      .run(
        voiceprintId,
        chunk.user_id,
        audio,
        selection.durationMs,
        selection.quality,
      );
    captured += 1;
  }
  return captured;
}

function get(userId, voiceprintId) {
  return getDatabase()
    .prepare(
      `SELECT p.* FROM speaker_previews p
       JOIN voiceprints v ON v.id=p.voiceprint_id
       WHERE p.voiceprint_id=? AND p.user_id=? AND v.user_id=?`,
    )
    .get(voiceprintId, userId, userId);
}

module.exports = {
  selectTurns,
  extractPreview,
  captureFromChunk,
  get,
};
