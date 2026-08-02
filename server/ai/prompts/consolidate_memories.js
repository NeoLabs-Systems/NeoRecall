'use strict';

const { MEMORY_TYPES, MINI_MEMORY_KINDS, ENTITY_KINDS } = require('../schemas/consolidation_schema');

function alternatives(values) {
  return values.join('|');
}

function localTimestamp(iso, timezone) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23', timeZoneName: 'longOffset',
  }).formatToParts(new Date(iso));
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const offset = value.timeZoneName === 'GMT' ? '+00:00' : value.timeZoneName.replace('GMT', '');
  return `${value.year}-${value.month}-${value.day}T${value.hour}:${value.minute}:${value.second}${offset}`;
}

function compactInput(conversations, timezone) {
  const conversationAliases = new Map();
  const segmentAliases = new Map();
  const speakerAliases = new Map();
  const reverseSpeakerAliases = new Map();
  const streamAliases = new Map();
  const reverseConversationAliases = new Map();
  const reverseSegmentAliases = new Map();
  let segmentOrdinal = 0;

  const compactConversations = conversations.map((conversation, conversationIndex) => {
    const conversationAlias = `c${conversationIndex + 1}`;
    conversationAliases.set(conversation.id, conversationAlias);
    reverseConversationAliases.set(conversationAlias, conversation.id);
    const conversationStart = Date.parse(conversation.startedAt);
    const streamKey = conversation.sessionId || conversation.id;
    if (!streamAliases.has(streamKey)) streamAliases.set(streamKey, `stream${streamAliases.size + 1}`);
    return {
      id: conversationAlias,
      stream: streamAliases.get(streamKey),
      recorded: {
        startedAtUtc: conversation.startedAt,
        endedAtUtc: conversation.endedAt,
        localStartedAt: localTimestamp(conversation.startedAt, timezone),
        localEndedAt: localTimestamp(conversation.endedAt, timezone),
      },
      segments: conversation.segments.map((segment) => {
        segmentOrdinal += 1;
        const segmentAlias = `s${segmentOrdinal}`;
        segmentAliases.set(segment.id, segmentAlias);
        reverseSegmentAliases.set(segmentAlias, segment.id);
        let speaker = null;
        if (segment.speakerClusterId) {
          if (!speakerAliases.has(segment.speakerClusterId)) {
            const alias = `speaker${speakerAliases.size + 1}`;
            speakerAliases.set(segment.speakerClusterId, alias);
            reverseSpeakerAliases.set(alias, segment.speakerClusterId);
          }
          speaker = speakerAliases.get(segment.speakerClusterId);
        }
        return {
          id: segmentAlias,
          offsetMs: Math.max(0, Date.parse(segment.started_at) - conversationStart),
          durationMs: Math.max(0, Date.parse(segment.ended_at) - Date.parse(segment.started_at)),
          speaker,
          language: segment.language || null,
          text: segment.text,
        };
      }),
    };
  });

  return {
    compactConversations,
    conversationAliases,
    segmentAliases,
    reverseConversationAliases,
    reverseSegmentAliases,
    reverseSpeakerAliases,
  };
}

function consolidationMessages({ conversations, previousDailySummary, timezone }, preparedReferences = null) {
  const references = preparedReferences || compactInput(conversations, timezone);
  const compactPreviousSummary = previousDailySummary ? {
    localDate: previousDailySummary.local_date,
    timezone: previousDailySummary.timezone,
    summaryEn: previousDailySummary.summary_en,
    coverageStartedAt: previousDailySummary.coverage_started_at,
    coverageEndedAt: previousDailySummary.coverage_ended_at,
    sourceCount: previousDailySummary.source_count,
  } : null;
  return [
    {
      role: 'system',
      content: `You consolidate personal transcripts into reliable memories. Return one JSON object matching the supplied contract.
All titles, summaries, topics, canonical entity names, and mini-memory text MUST be English, even when the source transcript is German or another language. Preserve proper names accurately.
The input conversation objects are provisional local groups, not authoritative conversation boundaries. Produce conversationSections that partition the transcript into coherent real-world conversations or topic areas. You may merge adjacent input conversations when they belong to the same stream and same real conversation, and split any input conversation when its topic or real-world conversation changes. Never combine segments from different streams. A speaker change alone, a brief aside, or a short pause is not a topic boundary. Do not force a fixed number or duration of sections.
Every conversation section needs a concise specific title and a faithful standalone summary. Ordinary ambient speech can be marked not memory-worthy, but it still needs an accurate title and summary. Mini-memories must be atomic and evidence-backed.
One real-world occasion is one memory. A single continuous meeting, lesson, lecture or call produces exactly one memory covering all of it, however long it ran and however many topics it moved through; use its internal topics and mini-memories to carry the detail instead of splitting it into several memories. A recording that merely spans a whole day is not one occasion: it produces one memory per distinct real-world occasion it captured. Choose the memory type that matches the occasion, and use ${alternatives(MEMORY_TYPES)} exactly as named — lesson covers a class, lecture, seminar or any taught session.
Each memory needs exactly one emoji that a person would recognize as the occasion at a glance — a meeting, a meal, a school lesson, a travel moment, a decision. Prefer a concrete, widely supported emoji over abstract symbols; never return text, multiple emoji, or skin-tone modifiers for this field.
Extract each distinct durable fact, decision, measurable requirement, task, promise, deadline, scheduled event, person or relationship, and location that is useful to recall. Perform a segment-by-segment completeness check so secondary assignees and commitments are not omitted merely because the parent memory mentions the topic. Completeness must not degrade with input length: a three-hour occasion carries proportionally more distinct facts, decisions, tasks and promises than a ten-minute one, and each phase of a long occasion deserves the same segment-by-segment attention as a short input would receive. Never summarize away extractable items because the input is large. Each mini-memory must contain exactly one independently searchable assertion; never combine distinct requirements, decisions, assignments, or promises in one mini-memory. Do not turn proposals, questions, negations, or uncertain statements into established facts. If the source explicitly says there is no task, do not create a task or promise from the negative instruction.
When the evidence names the actor for a task or promise, include that actor in textEn as well as in the entity relation. Do not rely on entity metadata to make an atomic memory understandable. If the actor is not identifiable from the evidence, do not invent one.
Each segment carries a speaker label. When the transcript itself identifies which speaker label a person entity's voice belongs to — for example the person introduces themselves, or another speaker addresses or names them while they are the one talking — set that entity's speakerAlias to that speaker label. Use null whenever the link is not directly supported by the transcript; never guess from a name alone, and never set speakerAlias for an entity that is not a person.
When one input conversation contains unrelated topics, create separate sections and memories with the specific supporting segment IDs for each topic.
Input startedAt and endedAt fields are authoritative UTC instants. localStartedAt and localEndedAt show the same instants in the user's IANA timezone. NeoRecall derives all output time ranges from cited segment IDs, so do not produce redundant timestamps. Do not state calendar dates in titles, summaries, or mini-memory text unless the date is spoken in the transcript itself: recording metadata can carry a wrong device clock, and a date written into prose cannot be corrected afterwards.
For mini-memory dueAt and occurredAt, NEVER calculate UTC. Return null or an object containing the exact local wall-clock value without an offset plus the applicable IANA timezone. Use the supplied user timezone for unqualified times. For a date-only deadline use 23:59:59 local time; for a date-only event use 00:00:00 local time. When the source gives only a vague part of day, retain that wording in text and return null rather than inventing an exact clock time. NeoRecall converts the object to UTC deterministically. Use null when the evidence does not support a date.
Use dueAt for task or promise deadlines. Use occurredAt for events and past occurrences. Status is only for tasks and promises; use null for other kinds.
Daily summary text covers memory-worthy material only. Exclude sections marked not memory-worthy. If there is no memory-worthy material and no previous daily summary, return dailySummary as null.
Across conversationSections, include EVERY input segment ID exactly once. Each section must contain a non-empty, chronologically contiguous range from one stream. Preserve segment order. Never omit, duplicate, reorder, or invent segment IDs.
Use only segment IDs present in the input. Never invent facts or IDs. Importance is 1–10. Confidence reflects evidential certainty. Return no prose outside JSON.`,
    },
    {
      role: 'user',
      content: JSON.stringify({ timezone, previousDailySummary: compactPreviousSummary, conversations: references.compactConversations, outputContract: {
        conversationSections: [{
          titleEn: 'Concise English title',
          summaryEn: 'Faithful English summary',
          memoryWorthy: true,
          topics: ['English topic'],
          sourceSegmentIds: ['contiguous input segment IDs'],
        }],
        entities: [{ ref: 'response-local ID', kind: alternatives(ENTITY_KINDS), canonicalNameEn: 'English canonical name', displayName: null,
          aliases: [{ value: 'name as found in source', language: 'ISO 639-1 language code or null' }],
          speakerAlias: 'speaker label this person is heard speaking as, or null' }],
        memories: [{ type: alternatives(MEMORY_TYPES), titleEn: 'English', summaryEn: 'English', emoji: '🤝', importance: 1,
          sourceSegmentIds: ['input segment ID'], topics: ['English'],
          entities: [{ ref: 'response-local entity ref', role: 'participant' }], miniMemories: [{ kind: alternatives(MINI_MEMORY_KINDS),
            textEn: 'English atomic statement', importance: 1, confidence: 0.5,
            dueAt: { localDateTime: 'YYYY-MM-DDTHH:mm:ss', timezone: 'IANA timezone' }, occurredAt: null, status: null,
            sourceSegmentIds: ['input segment ID'], entities: [] }] }],
        dailySummary: { localDate: 'YYYY-MM-DD', timezone, summaryEn: 'English cumulative summary' },
      } }),
    },
  ];
}

function prepareConsolidationRequest(input) {
  const references = compactInput(input.conversations, input.timezone);
  const messages = consolidationMessages(input, references);
  return { messages, references };
}

function restoreReferenceIds(output, references) {
  const segmentId = (alias) => references.reverseSegmentAliases.get(alias) || alias;
  for (const section of output.conversationSections) {
    section.sourceSegmentIds = section.sourceSegmentIds.map(segmentId);
  }
  for (const memory of output.memories) {
    memory.sourceSegmentIds = memory.sourceSegmentIds.map(segmentId);
    for (const miniMemory of memory.miniMemories) miniMemory.sourceSegmentIds = miniMemory.sourceSegmentIds.map(segmentId);
  }
  return output;
}

module.exports = { consolidationMessages, prepareConsolidationRequest, restoreReferenceIds, compactInput, localTimestamp };
