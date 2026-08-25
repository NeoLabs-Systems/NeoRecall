'use strict';

const {
  MEMORY_TYPES, MINI_MEMORY_KINDS, ENTITY_KINDS,
  MEMORY_MAX_COUNT, MINI_MEMORY_MAX_COUNT, ENTITY_MAX_COUNT,
} = require('../schemas/consolidation_schema');

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

function compactInput(conversations, timezone, continuationCandidates = []) {
  const conversationAliases = new Map();
  const segmentAliases = new Map();
  const memoryAliases = new Map();
  const speakerAliases = new Map();
  const reverseSpeakerAliases = new Map();
  const streamAliases = new Map();
  const reverseConversationAliases = new Map();
  const reverseSegmentAliases = new Map();
  const reverseMemoryAliases = new Map();
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

  // The two facts that separate "this occasion is still running" from "the same
  // subject came up again" are how much time passed and whether the recording
  // ever stopped. Both are arithmetic over timestamps and stream ids, which a
  // model should not be asked to redo — and neither of them decides anything on
  // its own; they are evidence for the model's decision.
  const inputStartedAt = conversations.reduce((earliest, conversation) => (
    !earliest || Date.parse(conversation.startedAt) < Date.parse(earliest) ? conversation.startedAt : earliest
  ), null);
  const compactContinuationCandidates = continuationCandidates.map((memory, index) => {
    const alias = `m${index + 1}`;
    memoryAliases.set(memory.publicId, alias);
    reverseMemoryAliases.set(alias, memory.publicId);
    const sharedStreams = (memory.sessionIds || []).map((id) => streamAliases.get(id)).filter(Boolean);
    return {
      id: alias,
      type: memory.type,
      titleEn: memory.titleEn,
      summaryEn: memory.summaryEn,
      startedAt: localTimestamp(memory.startedAt, timezone),
      endedAt: localTimestamp(memory.endedAt, timezone),
      minutesBeforeThisInput: inputStartedAt
        ? Math.round((Date.parse(inputStartedAt) - Date.parse(memory.endedAt)) / 60_000)
        : null,
      recordedInSameStreamAsThisInput: sharedStreams.length > 0,
      topics: memory.topics,
      highlights: memory.highlights,
    };
  });

  return {
    compactConversations, compactContinuationCandidates,
    conversationAliases,
    segmentAliases,
    memoryAliases,
    reverseConversationAliases,
    reverseSegmentAliases, reverseMemoryAliases,
    reverseSpeakerAliases,
  };
}

/// Splits the compacted transcript into windows that each fit one request.
///
/// A model running on this machine holds a fixed number of tokens at once, and a
/// four-hour lecture does not fit in any of them. Windows are cut on segment
/// boundaries and stay in order, so every window is a contiguous stretch of one
/// stream — which is what section validation requires and what lets the engine
/// join a section that spans two windows back together afterwards.
///
/// A conversation is never split across windows unless it is too large to be a
/// window on its own, so in the ordinary case a window is one whole occasion.
function windowConversations(compactConversations, budgetCharacters) {
  const windows = [];
  let current = [];
  let size = 0;
  const flush = () => { if (current.length) windows.push(current); current = []; size = 0; };

  for (const conversation of compactConversations) {
    const envelope = JSON.stringify({ ...conversation, segments: [] }).length;
    let batch = [];
    let batchSize = envelope;
    const pushBatch = () => {
      if (!batch.length) return;
      current.push({ ...conversation, segments: batch });
      size += batchSize;
      batch = [];
      batchSize = envelope;
    };
    for (const segment of conversation.segments) {
      const segmentSize = JSON.stringify(segment).length;
      // A single segment larger than a whole window cannot be split further —
      // it is one recognized utterance — so it is placed alone and the request
      // is allowed to be oversized rather than silently dropped. The provider
      // refuses it if it truly does not fit, which surfaces as a configuration
      // problem instead of as missing evidence.
      if (batch.length && size + batchSize + segmentSize > budgetCharacters) {
        pushBatch();
        flush();
      }
      batch.push(segment);
      batchSize += segmentSize;
    }
    pushBatch();
    if (size >= budgetCharacters) flush();
  }
  flush();
  return windows.length ? windows : [[]];
}

/// What the next window is told about the occasion still in progress.
///
/// Only the trailing section can continue — windows are chronological — so this
/// carries exactly that one section and the memory built from it, not the whole
/// history. The size of a request therefore does not grow with the number of
/// windows already processed.
function carryOverFor(merged) {
  if (!merged?.conversationSections?.length) return null;
  const section = merged.conversationSections.at(-1);
  const memory = merged.memories.length ? merged.memories.at(-1) : null;
  const sectionSegments = new Set(section.sourceSegmentIds);
  const continuable = memory && memory.sourceSegmentIds.some((id) => sectionSegments.has(id)) ? memory : null;
  return {
    section: {
      titleEn: section.titleEn, summaryEn: section.summaryEn, topics: section.topics, memoryWorthy: section.memoryWorthy,
    },
    memory: continuable ? {
      type: continuable.type, titleEn: continuable.titleEn, summaryEn: continuable.summaryEn,
      emoji: continuable.emoji, importance: continuable.importance, topics: continuable.topics,
      continuesMemoryIds: continuable.continuesMemoryIds,
    } : null,
  };
}

const WINDOW_INSTRUCTIONS = `This request is one window of a transcript that was too long to read at once. The window before it has already been described, and its description is supplied as carryOver. The occasion it describes may still be running in this window.
Set continuesPrevious to true on your FIRST conversation section when this window opens in the middle of the occasion carryOver.section describes, and on the memory built from that section when it continues carryOver.memory. In that case write the title and summary of the WHOLE occasion — everything carryOver already says plus what this window adds — because NeoRecall replaces the earlier text with yours. Never refer to a previous window, never say the transcript is partial, and never repeat carryOver's segment IDs: cite only segment IDs from this window.
Set continuesPrevious to false on every other section and memory, including when this window opens a new occasion. Only the first section of the window may set it to true.
When a memory continues carryOver.memory, preserve its continuesMemoryIds. You may add another continuation candidate only if the wider evidence shows that candidate is another fragment of the exact same occasion.
`;

function consolidationMessages({ conversations, previousDailySummary, timezone, continuationCandidates = [], carryOver = null }, preparedReferences = null) {
  const references = preparedReferences || compactInput(conversations, timezone, continuationCandidates);
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
memoryWorthy is a high bar. Set it true only for a substantial real-world occasion someone would open later as its own card — a meeting, lesson, multi-turn discussion, decision session, introduction with lasting context, or other experience with lasting narrative. Set it false for brief exchanges, hellos, logistics check-ins, one- or two-turn replies, ambient chatter, or any short stretch whose whole value is a single atomic fact, task, or promise. Those short items are not memories: if they appear inside a larger worthy occasion, put them in miniMemories under that memory; if the whole conversation is short and not a real occasion, mark the section not memory-worthy and create no memory for it.
One real-world occasion is one memory. A single continuous meeting, lesson, lecture or call produces exactly one memory covering all of it, however long it ran and however many topics it moved through; use its internal topics and mini-memories to carry the detail instead of splitting it into several memories. A recording that merely spans a whole day is not one occasion: it produces one memory per distinct real-world occasion it captured. Prefer zero memories over inventing thin ones. Choose the memory type that matches the occasion, and use ${alternatives(MEMORY_TYPES)} exactly as named — lesson covers a class, lecture, seminar or any taught session.
continuationCandidates are memory cards NeoRecall already wrote, close enough in time or recording to be worth comparing with this input. Each carries minutesBeforeThisInput (how long after that card ended this input begins) and recordedInSameStreamAsThisInput (whether the recording ran on without stopping).
For every output memory, first write continuationReasoning: one sentence naming what the new segments say about whether this is the same sitting as a candidate, or null when there are no candidates. Then set continuesMemoryIds accordingly. Decide it as one question: is this the SAME sitting — the same people, still in the room, carrying on — or a later separate occasion?
Same sitting looks like: the speech picks up mid-thread ("back to the integrator", "as we just calculated"), no restart, no greeting, no re-introduction, minutes rather than hours since the candidate ended, and the recording never stopped.
A later occasion looks like: an opening or a greeting, the material introduced from the beginning, a new or partly new group, an explicit reference to the earlier sitting as something that already happened ("like this morning", "as we did last week", "for those who missed it"), or a long gap. Speech that calls the subject "the same exercise" or "the same topic" as an earlier sitting is telling you it is a DIFFERENT sitting, not a continuation. A matching title, topic, type, course or recurring meeting never merges anything on its own.
Use [] whenever the transcript does not show the earlier sitting still running.
If several candidate cards are duplicate fragments of the same continuing occasion, claim all of them in one output memory so NeoRecall can absorb them into one card. A candidate id may appear in at most one output memory. Write that memory's title, summary, type, emoji, importance and topics for the WHOLE combined occasion, including what the claimed candidates already say. Its sourceSegmentIds and miniMemories must still cite only new input segments. Existing highlights are preserved automatically, so do not repeat one unless the new transcript adds materially new information. Candidate text is context for the continuation decision and combined prose; never treat it as new transcript evidence.
An otherwise short section that clearly continues a candidate's substantial occasion remains memoryWorthy: extending that card does not create a thin new card.
Each memory needs exactly one emoji that a person would recognize as the occasion at a glance — a meeting, a meal, a school lesson, a travel moment, a decision. Prefer a concrete, widely supported emoji over abstract symbols; never return text, multiple emoji, or skin-tone modifiers for this field.
Extract each distinct durable fact, decision, measurable requirement, task, promise, deadline, scheduled event, person or relationship, and location that is useful to recall. Perform a segment-by-segment completeness check so secondary assignees and commitments are not omitted merely because the parent memory mentions the topic. Completeness must not degrade with input length: a three-hour occasion carries proportionally more distinct facts, decisions, tasks and promises than a ten-minute one, and each phase of a long occasion deserves the same segment-by-segment attention as a short input would receive. Never summarize away extractable items because the input is large. Each mini-memory must contain exactly one independently searchable assertion; never combine distinct requirements, decisions, assignments, or promises in one mini-memory. Do not turn proposals, questions, negations, or uncertain statements into established facts. If the source explicitly says there is no task, do not create a task or promise from the negative instruction.
When the evidence names the actor for a task or promise, include that actor in textEn as well as in the entity relation. Do not rely on entity metadata to make an atomic memory understandable. If the actor is not identifiable from the evidence, do not invent one.
Each segment carries a speaker label. When the transcript itself identifies which speaker label a person entity's voice belongs to — for example the person introduces themselves, or another speaker addresses or names them while they are the one talking — set that entity's speakerAlias to that speaker label. Use null whenever the link is not directly supported by the transcript; never guess from a name alone, and never set speakerAlias for an entity that is not a person.
When one input conversation contains unrelated topics, create separate sections and memories with the specific supporting segment IDs for each topic.
Input startedAt and endedAt fields are authoritative UTC instants. localStartedAt and localEndedAt show the same instants in the user's IANA timezone. NeoRecall derives all output time ranges from cited segment IDs, so do not produce redundant timestamps. Do not state calendar dates in titles, summaries, or mini-memory text unless the date is spoken in the transcript itself: recording metadata can carry a wrong device clock, and a date written into prose cannot be corrected afterwards.
For mini-memory dueAt and occurredAt, NEVER calculate UTC. Return null or an object containing the exact local wall-clock value without an offset plus the applicable IANA timezone. Use the supplied user timezone for unqualified times. For a date-only deadline use 23:59:59 local time; for a date-only event use 00:00:00 local time. When the source gives only a vague part of day, retain that wording in text and return null rather than inventing an exact clock time. NeoRecall converts the object to UTC deterministically. Use null when the evidence does not support a date.
Use dueAt for task or promise deadlines. Use occurredAt for events and past occurrences. Status is only for tasks and promises; use null for other kinds.
Always return dailySummary as null. The day is summarised by a separate request once every part of the transcript has been read; this one only describes what it was given.
Across conversationSections, include EVERY input segment ID exactly once. Each section must contain a non-empty, chronologically contiguous range from one stream. Preserve segment order. Never omit, duplicate, reorder, or invent segment IDs.
Use only segment IDs present in the input. Never invent facts or IDs. Importance is 1–10. Confidence reflects evidential certainty. Return no prose outside JSON.
This request is one bounded pass: return at most ${MEMORY_MAX_COUNT} memories, at most ${MINI_MEMORY_MAX_COUNT} mini-memories per memory, and at most ${ENTITY_MAX_COUNT} entities. These are budgets to spend well, not quotas to fill. When the transcript offers more than fits, keep the items a person would actually search for later — decisions, commitments with an owner, deadlines, numbers, named people — and drop restatements, pleasantries and anything already implied by the memory summary. Conversation sections are not limited: partition the whole input however many sections it takes.
${carryOver ? WINDOW_INSTRUCTIONS : ''}`,
    },
    {
      role: 'user',
      content: JSON.stringify({
        timezone,
        previousDailySummary: compactPreviousSummary,
        continuationCandidates: references.compactContinuationCandidates,
        ...(carryOver ? { carryOver } : {}),
        conversations: references.compactConversations,
        outputContract: {
          conversationSections: [{
            titleEn: 'Concise English title',
            summaryEn: 'Faithful English summary',
            memoryWorthy: true,
            continuesPrevious: false,
            topics: ['English topic'],
            sourceSegmentIds: ['contiguous input segment IDs'],
          }],
          entities: [{ ref: 'response-local ID', kind: alternatives(ENTITY_KINDS), canonicalNameEn: 'English canonical name', displayName: null,
            aliases: [{ value: 'name as found in source', language: 'ISO 639-1 language code or null' }],
            speakerAlias: 'speaker label this person is heard speaking as, or null' }],
          memories: [{ type: alternatives(MEMORY_TYPES), continuesPrevious: false,
            continuationReasoning: 'one sentence, or null when there are no candidates', continuesMemoryIds: [],
            titleEn: 'English', summaryEn: 'English', emoji: '🤝', importance: 1,
            sourceSegmentIds: ['input segment ID'], topics: ['English'],
            entities: [{ ref: 'response-local entity ref', role: 'participant' }], miniMemories: [{ kind: alternatives(MINI_MEMORY_KINDS),
              textEn: 'English atomic statement', importance: 1, confidence: 0.5,
              dueAt: { localDateTime: 'YYYY-MM-DDTHH:mm:ss', timezone: 'IANA timezone' }, occurredAt: null, status: null,
              sourceSegmentIds: ['input segment ID'], entities: [] }] }],
          dailySummary: null,
        },
      }),
    },
  ];
}

/// Builds every request one consolidation run needs.
///
/// Aliasing happens once for the whole candidate set, so a segment has the same
/// identifier in whichever window it lands and the engine can resolve every
/// response against one reference table. `budgetCharacters` is what the provider
/// can read in a single request; when the transcript fits inside it there is
/// exactly one window and the result is identical to the unwindowed request.
function prepareConsolidationRequest(input, budgetCharacters = Infinity) {
  const references = compactInput(input.conversations, input.timezone, input.continuationCandidates);
  const windows = windowConversations(references.compactConversations, budgetCharacters);
  return {
    references,
    windows: windows.map((compactConversations, index) => ({
      compactConversations,
      segmentIds: compactConversations.flatMap((conversation) => conversation.segments.map((segment) => segment.id)),
      continuationMemoryIds: references.compactContinuationCandidates.map((memory) => memory.id),
      messages: (carryOver) => consolidationMessages({ ...input, carryOver }, { ...references, compactConversations }),
    })),
  };
}

function restoreReferenceIds(output, references) {
  const segmentId = (alias) => references.reverseSegmentAliases.get(alias) || alias;
  const memoryId = (alias) => references.reverseMemoryAliases.get(alias) || alias;
  for (const section of output.conversationSections) {
    section.sourceSegmentIds = section.sourceSegmentIds.map(segmentId);
  }
  for (const memory of output.memories) {
    memory.continuesMemoryIds = (memory.continuesMemoryIds || []).map(memoryId);
    memory.sourceSegmentIds = memory.sourceSegmentIds.map(segmentId);
    for (const miniMemory of memory.miniMemories) miniMemory.sourceSegmentIds = miniMemory.sourceSegmentIds.map(segmentId);
  }
  return output;
}

module.exports = {
  consolidationMessages, prepareConsolidationRequest, restoreReferenceIds, compactInput, localTimestamp,
  windowConversations, carryOverFor,
};
