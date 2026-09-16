'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');

const FIXTURE = path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav');
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-audio-'));
process.env.NEORECALL_HOME = HOME;

// The audio models live in the real installation, not in this throwaway home.
// Linking them in is what lets this run against actual speech rather than
// against hand-written vectors that assume the answer.
const installedModels = path.join(os.homedir(), '.neorecall', 'models');
if (fs.existsSync(installedModels)) {
  fs.mkdirSync(path.dirname(path.join(HOME, 'models')), { recursive: true });
  try { fs.symlinkSync(installedModels, path.join(HOME, 'models')); } catch { /* already linked */ }
}

const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const localAnalysis = require('../../server/transcription/local_analysis');
const { alignSegments } = require('../../server/transcription/speaker_alignment');
const { buildSegments } = require('../../server/transcription/segment');
const transcribeHandler = require('../../server/workers/handlers/transcribe_handler');
const engine = require('../../server/speakers/identity_engine');
const membership = require('../../server/services/conversations/conversation_membership_service');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(HOME, { recursive: true, force: true });
});

const available = localAnalysis.available();
const START = '2026-08-01T09:00:00.000Z';

function durationSeconds(file) {
  const probe = spawnSync(ffmpegPath, ['-i', file, '-f', 'null', '-'], { encoding: 'utf8' });
  const match = /Duration: (\d+):(\d+):(\d+\.\d+)/.exec(probe.stderr);
  if (!match) return 0;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

// The fixture is eighteen seconds; a real conversation is minutes. Repeating it
// gives the chunker something the size of what it actually sees, which matters
// because every quantity in this pipeline is measured per chunk: at the shipped
// thirty-second chunk size a speaker is fingerprinted from tens of seconds of
// speech, and at three seconds from almost none. A test built on tiny chunks
// measures the embedding model's behaviour on fragments, not this code's.
function longRecording(passes = 8) {
  const list = path.join(HOME, 'passes.txt');
  const combined = path.join(HOME, 'long.wav');
  fs.writeFileSync(list, Array(passes).fill(`file '${FIXTURE}'`).join('\n'));
  const result = spawnSync(ffmpegPath, ['-v', 'error', '-f', 'concat', '-safe', '0', '-i', list,
    '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', combined], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return combined;
}

function sliceChunks(source, seconds) {
  const total = durationSeconds(source);
  const files = [];
  for (let offset = 0; offset < total; offset += seconds) {
    const file = path.join(HOME, `chunk-${files.length}.wav`);
    const result = spawnSync(ffmpegPath, ['-v', 'error', '-ss', String(offset), '-t', String(seconds),
      '-i', source, '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', file], { encoding: 'utf8' });
    if (result.status !== 0 || !fs.existsSync(file) || fs.statSync(file).size < 2000) break;
    files.push({ file, offsetMs: Math.round(offset * 1000), durationMs: Math.round(seconds * 1000) });
  }
  return files;
}

function seedRecording() {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `audio-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, START, START, START);
  db.prepare(`INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')`).run(sourceId, sessionId, sourceId);
  return { userId, sessionId, sourceId };
}

function seedChunk({ userId, sessionId, sourceId }, sequence, piece) {
  const db = getDatabase();
  const chunkId = crypto.randomUUID();
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,temporary_path,state)
    VALUES (?,?,?,?,?,?,?,?,'wav','pcm_s16le','mono',?,?,?,?,'processing')`)
    .run(chunkId, userId, sessionId, sourceId, sequence, chunkId, crypto.randomBytes(32).toString('hex'),
      fs.statSync(piece.file).size, START, piece.offsetMs, piece.durationMs, piece.file);
  return db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
}

// The real local pipeline, minus the transcription service. Diarization,
// embedding extraction and alignment all run for real; only the words are
// stand-ins, because who spoke does not depend on what was said.
function segmentsFor(piece) {
  const analysis = localAnalysis.analyze(piece.file);
  if (!analysis.analyzed || !analysis.hasSpeech || !analysis.turns.length) return [];
  const spoken = analysis.turns.map((turn) => ({
    text: 'gesprochener Text', startMs: turn.startMs, endMs: turn.endMs, sourceComponent: 'combined',
  }));
  return alignSegments(buildSegments(spoken), analysis.turns);
}

test('two real speakers stay two people through the whole pipeline', { skip: !available && 'audio models unavailable' }, () => {
  const db = getDatabase();
  const recording = seedRecording();
  const { chunkTargetMs } = require('../../server/config').getConfig();
  const pieces = sliceChunks(longRecording(), chunkTargetMs / 1000);
  assert.ok(pieces.length >= 4, 'the recording yields several chunks to work with');

  let persisted = 0;
  pieces.forEach((piece, sequence) => {
    const chunk = seedChunk(recording, sequence, piece);
    const segments = segmentsFor(piece);
    if (!segments.length) return;
    persisted += transcribeHandler.persistSegments(chunk, segments);
  });
  assert.ok(persisted > 0, 'the pipeline produced transcript segments with speaker turns');

  const conversationId = crypto.randomUUID();
  db.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(conversationId, recording.userId, START, '2026-08-01T09:30:00.000Z');
  db.prepare('UPDATE transcript_segments SET conversation_id=? WHERE user_id=?').run(conversationId, recording.userId);
  membership.rebuildConversationSpeakers(db, recording.userId, conversationId);

  const labels = () => db.prepare('SELECT COUNT(DISTINCT local_label) count FROM conversation_speakers WHERE conversation_id=?')
    .get(conversationId).count;
  const before = labels();

  const result = engine.resolveConversation(db, recording.userId, conversationId);
  const voiceprints = db.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(recording.userId).count;

  // Two people is the fixture's ground truth, and this asserts the direction
  // that actually costs something. Failing to merge a split voice is a label the
  // user can still read past; merging two real people writes one person's words
  // under another's name, and a pass that re-clusters on similarity is exactly
  // the code that could do it. Real speech is where that risk lives — synthetic
  // vectors are chosen by the test and cannot catch it.
  assert.equal(labels(), 2, `two speakers, two labels (was ${before})`);
  assert.equal(voiceprints, 2, 'and two durable people');
  assert.equal(result.mergedClusters, 0, 'nothing to merge here, and nothing merged');
  assert.ok(labels() <= before, 'resolution never invents a speaker');
});

test('resolving the same real conversation twice is a fixed point', { skip: !available && 'audio models unavailable' }, () => {
  const db = getDatabase();
  const conversation = db.prepare('SELECT id,user_id FROM conversations ORDER BY created_at DESC LIMIT 1').get();
  const again = engine.resolveConversation(db, conversation.user_id, conversation.id);
  assert.equal(again.mergedClusters, 0);
  assert.equal(again.assignedTurns, 0);
});
