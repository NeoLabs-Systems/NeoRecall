'use strict';

const { getDatabase } = require('../../db/database');
const settings = require('../settings/settings_service');
const { zip } = require('../../utils/zip');

// A readable dump of one account. Secrets, biometric blobs, other users, and
// the live database file are all out of scope — this is a backup the owner can
// open in Nextcloud, not a restore image.

function rows(sql, userId) {
  return getDatabase().prepare(sql).all(userId);
}

function build(userId) {
  const user = getDatabase().prepare('SELECT id, username, email, created_at FROM users WHERE id=?').get(userId);
  if (!user) throw Object.assign(new Error('User not found.'), { code: 'USER_NOT_FOUND', retryable: false });

  const payload = {
    account: { id: user.id, username: user.username, email: user.email, createdAt: user.created_at },
    settings: settings.get(userId),
    devices: rows('SELECT name, platform, kind, created_at, last_heartbeat_at FROM devices WHERE user_id=? AND revoked_at IS NULL', userId),
    sessions: rows(`SELECT id, client_uuid, device_started_at, device_ended_at, timezone, status, created_at
      FROM recording_sessions WHERE user_id=?`, userId),
    conversations: rows(`SELECT id, started_at, ended_at, state, title_en, summary_en, topics_json, created_at
      FROM conversations WHERE user_id=?`, userId),
    transcripts: rows(`SELECT public_id, conversation_id, started_at, ended_at, text, language
      FROM transcript_segments WHERE user_id=? ORDER BY started_at`, userId),
    memories: rows(`SELECT public_id, type, title_en, summary_en, importance, started_at, ended_at, pinned, archived, created_at
      FROM memories WHERE user_id=?`, userId),
    miniMemories: rows(`SELECT public_id, kind, text_en, importance, confidence, created_at FROM mini_memories WHERE user_id=?`, userId),
    dailySummaries: rows(`SELECT local_date, timezone, summary_en, coverage_started_at, coverage_ended_at, state, created_at
      FROM daily_summaries WHERE user_id=?`, userId),
    speakers: rows('SELECT id, display_name FROM voiceprints WHERE user_id=?', userId),
    entities: rows(`SELECT kind, canonical_name_en, display_name, created_at FROM entities WHERE user_id=?`, userId),
    context: rows(`SELECT kind, captured_at, note_text, original_name, content_type, extracted_text, analysis_text, created_at
      FROM recording_context_items WHERE user_id=?`, userId),
  };

  const manifest = {
    version: 1,
    kind: 'neorecall-user-backup',
    exportedAt: new Date().toISOString(),
    userId: user.id,
    username: user.username,
    counts: {
      devices: payload.devices.length,
      sessions: payload.sessions.length,
      conversations: payload.conversations.length,
      transcripts: payload.transcripts.length,
      memories: payload.memories.length,
      miniMemories: payload.miniMemories.length,
      dailySummaries: payload.dailySummaries.length,
      speakers: payload.speakers.length,
      entities: payload.entities.length,
      context: payload.context.length,
    },
  };

  return zip([
    { name: 'manifest.json', data: `${JSON.stringify(manifest, null, 2)}\n` },
    { name: 'data.json', data: `${JSON.stringify(payload)}\n` },
  ]);
}

module.exports = { build };
