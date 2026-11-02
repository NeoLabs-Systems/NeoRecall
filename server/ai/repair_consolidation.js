'use strict';

const { consolidationSchema, conversationSection, entity, memory, miniMemory, MEMORY_MAX_COUNT, MINI_MEMORY_MAX_COUNT, ENTITY_MAX_COUNT } = require('./schemas/consolidation_schema');

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

// A small model's most common slips, which carry the right meaning in the wrong
// type: a number as text, one id where a list was asked for, a missing list.
// Corrected, never invented — a value that cannot be read is left alone and the
// piece it belongs to is dropped by validation below.
function numeric(value) {
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value);
  return value;
}
function list(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}
function clamp(value, minimum, maximum) {
  const number = numeric(value);
  return Number.isFinite(number) ? Math.min(maximum, Math.max(minimum, number)) : number;
}

function coerceMini(raw) {
  if (!isObject(raw)) return raw;
  return { ...raw, importance: clamp(raw.importance, 1, 10), confidence: clamp(raw.confidence, 0, 1), sourceSegmentIds: list(raw.sourceSegmentIds), entities: list(raw.entities) };
}

function coerceMemory(raw) {
  if (!isObject(raw)) return raw;
  return {
    ...raw, importance: clamp(raw.importance, 1, 10), sourceSegmentIds: list(raw.sourceSegmentIds),
    topics: list(raw.topics), entities: list(raw.entities), continuesMemoryIds: list(raw.continuesMemoryIds),
    miniMemories: list(raw.miniMemories).map(coerceMini),
  };
}

// Keeps what a window's answer got right and drops what it got wrong.
//
// The contract is large — sections that partition the window, memories that cite
// them, entities, action items — and a model of a couple of billion parameters
// satisfies all of it at once only some of the time. Rejecting the whole answer
// over one malformed action item throws away the correct title, summary and
// sections beside it, and since a schema failure narrows and eventually
// quarantines the conversation, the same input then fails for good.
//
// Every piece that survives has passed the same strict schema as before, and its
// citations are restricted to what this window actually contained; nothing
// unvalidated reaches the database. What is lost is only what was malformed, and
// the counts of it are returned so it is logged rather than silent. If nothing
// usable remains the answer is still refused.
function repairConsolidation(raw, { segmentIds, continuationMemoryIds = [] }) {
  if (!isObject(raw)) return { value: null, dropped: { reason: 'the answer was not an object' } };
  const inWindow = new Set(segmentIds);
  const allowedContinuations = new Set(continuationMemoryIds);
  const dropped = { sections: 0, entities: 0, memories: 0, miniMemories: 0 };
  const citable = (ids) => [...new Set(list(ids).filter((id) => inWindow.has(id)))];

  const entities = [];
  for (const candidate of list(raw.entities).slice(0, ENTITY_MAX_COUNT)) {
    const parsed = entity.safeParse(candidate);
    if (parsed.success) entities.push(parsed.data); else dropped.entities += 1;
  }
  const entityRefs = new Set(entities.map((item) => item.ref));

  let sections = [];
  for (const candidate of list(raw.conversationSections)) {
    const parsed = conversationSection.safeParse(isObject(candidate)
      ? { ...candidate, topics: list(candidate.topics), sourceSegmentIds: citable(candidate.sourceSegmentIds) } : candidate);
    if (parsed.success) sections.push(parsed.data); else dropped.sections += 1;
  }

  const memories = [];
  for (const candidate of list(raw.memories).slice(0, MEMORY_MAX_COUNT)) {
    const coerced = coerceMemory(candidate);
    if (!isObject(coerced)) { dropped.memories += 1; continue; }
    const miniMemories = [];
    for (const mini of coerced.miniMemories.slice(0, MINI_MEMORY_MAX_COUNT)) {
      const parsed = miniMemory.safeParse(isObject(mini) ? {
        ...mini, sourceSegmentIds: citable(mini.sourceSegmentIds), entities: list(mini.entities).filter((item) => entityRefs.has(item?.ref)),
      } : mini);
      if (parsed.success) miniMemories.push(parsed.data); else dropped.miniMemories += 1;
    }
    const parsed = memory.safeParse({
      ...coerced, miniMemories, sourceSegmentIds: citable(coerced.sourceSegmentIds),
      entities: coerced.entities.filter((item) => entityRefs.has(item?.ref)),
      continuesMemoryIds: [...new Set(coerced.continuesMemoryIds.filter((id) => allowedContinuations.has(id)))],
    });
    if (parsed.success) memories.push(parsed.data); else dropped.memories += 1;
  }

  // A memory is anchored to the sections it cites, and the later checks require
  // those to be memory-worthy. The model wrote the memory, so where it also
  // marked the section it cites as not worth a memory, the memory is believed.
  const cited = new Set(memories.flatMap((item) => item.sourceSegmentIds));
  sections = sections.map((section) => (section.memoryWorthy || !section.sourceSegmentIds.some((id) => cited.has(id))
    ? section : { ...section, memoryWorthy: true }));

  // No usable section but a usable memory: the memory already says what the
  // stretch was about, so one section carries its words over the whole window.
  if (!sections.length && memories.length) {
    const lead = memories[0];
    sections = [{ titleEn: lead.titleEn, summaryEn: lead.summaryEn, memoryWorthy: true, topics: lead.topics, continuesPrevious: false, sourceSegmentIds: [...segmentIds] }];
  }

  const parsed = consolidationSchema.safeParse({ conversationSections: sections, entities, memories, dailySummary: null });
  if (!parsed.success) return { value: null, dropped: { ...dropped, reason: 'nothing usable remained' } };
  return { value: parsed.data, dropped };
}

// The day's summary is one sentence in one field. A small model sometimes names
// the field differently or wraps the text in a list; the prose is what matters and
// is read from wherever it was put. Anything that is not text still fails.
function repairDailySummary(raw) {
  if (!isObject(raw)) return null;
  const candidates = [raw.summaryEn, ...Object.values(raw)];
  for (const candidate of candidates) {
    const text = Array.isArray(candidate) ? candidate.filter((part) => typeof part === 'string').join(' ') : candidate;
    if (typeof text === 'string' && text.trim()) return { summaryEn: text.trim() };
  }
  return null;
}

module.exports = { repairConsolidation, repairDailySummary };
