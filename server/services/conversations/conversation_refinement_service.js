'use strict';

const crypto = require('node:crypto');
const membership = require('./conversation_membership_service');

const REFINEMENT_METHOD = 'time-context-embedding+llm-topic';
const REFINEMENT_VERSION = '3';

function orderedStreamSegments(conversations) {
  const streams = new Map();
  for (const conversation of conversations) {
    const streamId = conversation.sessionId || conversation.id;
    if (!streams.has(streamId)) streams.set(streamId, []);
    for (const segment of conversation.segments) {
      streams.get(streamId).push({
        ...segment,
        originalConversationId: conversation.id,
        streamId,
      });
    }
  }
  for (const segments of streams.values()) {
    segments.sort((left, right) => (
      Date.parse(left.started_at) - Date.parse(right.started_at)
      || Date.parse(left.ended_at) - Date.parse(right.ended_at)
      || String(left.id).localeCompare(String(right.id))
    ));
  }
  return streams;
}

function invalidSections(message) {
  return Object.assign(new Error(message), { code: 'AI_REFERENCE_INVALID' });
}

function validateConversationSections(sections, conversations) {
  if (!sections.length) throw invalidSections('Conversation refinement must produce at least one section.');
  const streams = orderedStreamSegments(conversations);
  const segmentIndex = new Map();
  for (const [streamId, segments] of streams) {
    segments.forEach((segment, index) => segmentIndex.set(segment.id, { streamId, index, segment }));
  }

  const rangesByStream = new Map();
  const seen = new Set();
  const normalized = sections.map((section, outputIndex) => {
    const references = section.sourceSegmentIds.map((id) => {
      const reference = segmentIndex.get(id);
      if (!reference) throw invalidSections('A conversation section cited a segment outside the consolidation input.');
      if (seen.has(id)) throw invalidSections('A transcript segment appeared in more than one conversation section.');
      seen.add(id);
      return reference;
    });
    const streamId = references[0].streamId;
    if (references.some((reference) => reference.streamId !== streamId)) {
      throw invalidSections('A conversation section mixed independent recording streams.');
    }
    for (let index = 1; index < references.length; index += 1) {
      if (references[index].index !== references[index - 1].index + 1) {
        throw invalidSections('Conversation section segments must be contiguous and chronological.');
      }
    }
    const normalizedSection = {
      ...section,
      outputIndex,
      streamId,
      startIndex: references[0].index,
      endIndex: references.at(-1).index,
      segments: references.map((reference) => reference.segment),
    };
    if (!rangesByStream.has(streamId)) rangesByStream.set(streamId, []);
    rangesByStream.get(streamId).push(normalizedSection);
    return normalizedSection;
  });

  for (const [streamId, segments] of streams) {
    const ranges = (rangesByStream.get(streamId) || []).sort((left, right) => left.startIndex - right.startIndex);
    let expectedIndex = 0;
    for (const range of ranges) {
      if (range.startIndex !== expectedIndex) {
        throw invalidSections('Conversation sections must cover each recording stream without gaps or overlaps.');
      }
      expectedIndex = range.endIndex + 1;
    }
    if (expectedIndex !== segments.length) {
      throw invalidSections('Conversation sections omitted transcript segments.');
    }
  }
  if (seen.size !== segmentIndex.size) throw invalidSections('Conversation sections omitted transcript segments.');
  return normalized.sort((left, right) => (
    Date.parse(left.segments[0].started_at) - Date.parse(right.segments[0].started_at)
    || left.outputIndex - right.outputIndex
  ));
}

function normalizedTopics(topics) {
  const seen = new Set();
  return topics.map((topic) => topic.trim()).filter((topic) => {
    const key = topic.toLocaleLowerCase('en-US');
    if (!topic || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function applyConversationSections(database, userId, runId, sections, conversations) {
  const validated = validateConversationSections(sections, conversations);
  const originalIds = new Set(conversations.map((conversation) => conversation.id));
  const retainedOriginalIds = new Set();
  const plans = validated.map((section) => {
    const preferredId = section.segments[0].originalConversationId;
    const id = originalIds.has(preferredId) && !retainedOriginalIds.has(preferredId)
      ? preferredId
      : crypto.randomUUID();
    if (originalIds.has(id)) retainedOriginalIds.add(id);
    return {
      ...section,
      id,
      startedAt: section.segments[0].started_at,
      endedAt: section.segments.at(-1).ended_at,
      topics: normalizedTopics(section.topics),
      originConversationId: preferredId,
    };
  });

  // Refinement is the authoritative pass, so it also settles the conversation
  // insight: whatever a live preview wrote while the conversation was still
  // recording is replaced here and marked final, and no later preview may
  // overwrite it.
  const update = database.prepare(`UPDATE conversations SET
    started_at=?,ended_at=?,state=?,boundary_method=?,boundary_score=NULL,boundary_version=?,
    title_en=?,summary_en=?,topics_json=?,memory_worthy=?,insight_state='final',insight_characters=?,
    insight_updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),refined_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
    refinement_run_id=?,origin_conversation_id=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=? AND user_id=?`);
  const insert = database.prepare(`INSERT INTO conversations
    (id,user_id,started_at,ended_at,state,boundary_method,boundary_score,boundary_version,
      title_en,summary_en,topics_json,memory_worthy,insight_state,insight_characters,insight_updated_at,
      refined_at,refinement_run_id,origin_conversation_id)
    VALUES (?,?,?,?,?,?,NULL,?,?,?,?,?,'final',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'),
      strftime('%Y-%m-%dT%H:%M:%fZ','now'),?,?)`);

  for (const plan of plans) {
    const state = plan.memoryWorthy ? 'consolidated' : 'not_memory_worthy';
    const parameters = [
      plan.startedAt,
      plan.endedAt,
      state,
      REFINEMENT_METHOD,
      REFINEMENT_VERSION,
      plan.titleEn,
      plan.summaryEn,
      JSON.stringify(plan.topics),
      Number(plan.memoryWorthy),
      plan.segments.reduce((sum, segment) => sum + segment.text.length, 0),
      runId,
      plan.originConversationId,
    ];
    if (originalIds.has(plan.id)) {
      const result = update.run(...parameters, plan.id, userId);
      if (result.changes !== 1) throw invalidSections('A provisional conversation disappeared during refinement.');
    } else {
      insert.run(plan.id, userId, ...parameters);
    }
    membership.assignSegments(
      database,
      userId,
      plan.id,
      plan.segments.map((segment) => segment.id),
      { publicIds: true },
    );
  }

  const remove = database.prepare('DELETE FROM conversations WHERE id=? AND user_id=?');
  for (const originalId of originalIds) {
    if (!retainedOriginalIds.has(originalId)) remove.run(originalId, userId);
  }
  for (const plan of plans) membership.rebuildConversationSpeakers(database, userId, plan.id);

  const segmentConversationIds = new Map();
  for (const plan of plans) {
    for (const segment of plan.segments) segmentConversationIds.set(segment.id, plan.id);
  }
  return { conversations: plans, segmentConversationIds };
}

module.exports = {
  REFINEMENT_METHOD,
  REFINEMENT_VERSION,
  orderedStreamSegments,
  validateConversationSections,
  applyConversationSections,
};
