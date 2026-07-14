'use strict';

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
  const reverseConversationAliases = new Map();
  const reverseSegmentAliases = new Map();
  let segmentOrdinal = 0;

  const compactConversations = conversations.map((conversation, conversationIndex) => {
    const conversationAlias = `c${conversationIndex + 1}`;
    conversationAliases.set(conversation.id, conversationAlias);
    reverseConversationAliases.set(conversationAlias, conversation.id);
    const conversationStart = Date.parse(conversation.startedAt);
    return {
      id: conversationAlias,
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
          if (!speakerAliases.has(segment.speakerClusterId)) speakerAliases.set(segment.speakerClusterId, `speaker${speakerAliases.size + 1}`);
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

  return { compactConversations, conversationAliases, segmentAliases, reverseConversationAliases, reverseSegmentAliases };
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
Create episodic memories only for meaningful material. Ordinary ambient speech may be assessed as not memory-worthy. Split conversations by topic when appropriate. Mini-memories must be atomic and evidence-backed.
Extract each distinct durable fact, decision, measurable requirement, task, promise, deadline, scheduled event, person or relationship, and location that is useful to recall. Perform a segment-by-segment completeness check so secondary assignees and commitments are not omitted merely because the parent memory mentions the topic. Each mini-memory must contain exactly one independently searchable assertion; never combine distinct requirements, decisions, assignments, or promises in one mini-memory. Do not turn proposals, questions, negations, or uncertain statements into established facts. If the source explicitly says there is no task, do not create a task or promise from the negative instruction.
When the evidence names the actor for a task or promise, include that actor in textEn as well as in the entity relation. Do not rely on entity metadata to make an atomic memory understandable. If the actor is not identifiable from the evidence, do not invent one.
When one input conversation contains unrelated topics, create separate memories with the specific supporting segment IDs for each topic.
Input startedAt and endedAt fields are authoritative UTC instants. localStartedAt and localEndedAt show the same instants in the user's IANA timezone. Memory startedAt and endedAt remain ISO-8601 UTC timestamps.
For mini-memory dueAt and occurredAt, NEVER calculate UTC. Return null or an object containing the exact local wall-clock value without an offset plus the applicable IANA timezone. Use the supplied user timezone for unqualified times. For a date-only deadline use 23:59:59 local time; for a date-only event use 00:00:00 local time. When the source gives only a vague part of day, retain that wording in text and return null rather than inventing an exact clock time. NeoRecall converts the object to UTC deterministically. Use null when the evidence does not support a date.
Memory startedAt and endedAt describe when the cited recorded episode occurred, not a future event discussed during it.
Use dueAt for task or promise deadlines. Use occurredAt for events and past occurrences. Status is only for tasks and promises; use null for other kinds.
Daily summary text and sourceCount cover memory-worthy material only. Exclude conversations assessed as not memory-worthy. If there is no memory-worthy material and no previous daily summary, return dailySummary as null.
Return exactly one conversationAssessments entry for EVERY input conversation, including material that is not memory-worthy. Keep the input order. Never omit or duplicate an input conversation.
Use only conversation and segment IDs present in the input. Never invent facts or IDs. Importance is 1–10. Confidence reflects evidential certainty. Return no prose outside JSON.`,
    },
    {
      role: 'user',
      content: JSON.stringify({ timezone, previousDailySummary: compactPreviousSummary, conversations: references.compactConversations, outputContract: {
        conversationAssessments: [{ conversationId: 'input ID', memoryWorthy: true }],
        entities: [{ ref: 'response-local ID', kind: 'person|organization|project|location|other', canonicalNameEn: 'English canonical name', displayName: null,
          aliases: [{ value: 'name as found in source', language: 'ISO 639-1 language code or null' }] }],
        memories: [{ type: 'meeting|conversation|project_discussion|introduction|decision|experience|other', titleEn: 'English', summaryEn: 'English', importance: 1,
          startedAt: 'ISO timestamp', endedAt: 'ISO timestamp', sourceConversationIds: ['input ID'], sourceSegmentIds: ['input ID'], topics: ['English'],
          entities: [{ ref: 'response-local entity ref', role: 'participant' }], miniMemories: [{ kind: 'fact|event|location|person|relationship|task|promise',
            textEn: 'English atomic statement', importance: 1, confidence: 0.5,
            dueAt: { localDateTime: 'YYYY-MM-DDTHH:mm:ss', timezone: 'IANA timezone' }, occurredAt: null, status: null,
            sourceSegmentIds: ['input ID'], entities: [] }] }],
        dailySummary: { localDate: 'YYYY-MM-DD', timezone, summaryEn: 'English cumulative summary', coverageStartedAt: null, coverageEndedAt: null, sourceCount: 0 },
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
  const conversationId = (alias) => references.reverseConversationAliases.get(alias) || alias;
  const segmentId = (alias) => references.reverseSegmentAliases.get(alias) || alias;
  for (const assessment of output.conversationAssessments) assessment.conversationId = conversationId(assessment.conversationId);
  for (const memory of output.memories) {
    memory.sourceConversationIds = memory.sourceConversationIds.map(conversationId);
    memory.sourceSegmentIds = memory.sourceSegmentIds.map(segmentId);
    for (const miniMemory of memory.miniMemories) miniMemory.sourceSegmentIds = miniMemory.sourceSegmentIds.map(segmentId);
  }
  return output;
}

module.exports = { consolidationMessages, prepareConsolidationRequest, restoreReferenceIds, compactInput, localTimestamp };
