'use strict';

// Provisional conversation boundaries.
//
// A pause is not a topic change. Time on its own may therefore separate two
// *sittings* and nothing finer: that is the hard gap, sized so anything shorter
// is still one occasion. Every boundary below it needs semantic evidence that
// the subject actually moved on, and a shift has to persist — a single aside
// inside a meeting is not a new conversation.
//
// Evidence that is missing is not evidence of a change. An absent embedding
// never cuts, so detection groups a recording the same way whether or not the
// embedding job has caught up with the transcript; a run that lacks evidence
// leaves the conversation whole and open, and the next run decides again with
// the evidence it has by then. Splitting on absent evidence is what made the
// same recording group differently depending on queue timing.
//
// Erring towards one conversation is deliberate. Over-splitting is the
// irreversible mistake here — a closed group is never reconsidered, and each
// fragment becomes its own memory card — while under-splitting is corrected
// downstream by the consolidation model, which reads the full transcript and
// may still split or merge what this produced.

const crypto = require('node:crypto');

function cosine(left, right) {
  if (!left || !right || left.length !== right.length) return 0;
  let dot = 0; let a = 0; let b = 0;
  for (let index = 0; index < left.length; index += 1) { dot += left[index] * right[index]; a += left[index] ** 2; b += right[index] ** 2; }
  return a && b ? dot / Math.sqrt(a * b) : 0;
}

function averageEmbeddings(blocks) {
  const embeddings = blocks.map((block) => block.embedding).filter(Boolean);
  if (!embeddings.length) return null;
  const dimensions = embeddings[0].length;
  if (!dimensions || embeddings.some((embedding) => embedding.length !== dimensions)) return null;
  const average = new Float32Array(dimensions);
  for (const embedding of embeddings) {
    for (let index = 0; index < dimensions; index += 1) average[index] += embedding[index];
  }
  for (let index = 0; index < dimensions; index += 1) average[index] /= embeddings.length;
  return average;
}

function contextualSimilarity(blocks, boundaryIndex, contextSegments) {
  const left = averageEmbeddings(blocks.slice(Math.max(0, boundaryIndex - contextSegments), boundaryIndex));
  const right = averageEmbeddings(blocks.slice(boundaryIndex, boundaryIndex + contextSegments));
  return left && right ? cosine(left, right) : null;
}

function surroundingBaseline(similarities, index, radius) {
  const nearby = similarities.slice(Math.max(0, index - radius), index)
    .concat(similarities.slice(index + 1, index + radius + 1))
    .filter(Number.isFinite)
    .sort((left, right) => left - right);
  if (!nearby.length) return null;
  return nearby[Math.floor(nearby.length / 2)];
}

// Which boundaries a group shorter than the minimum duration may be folded back
// across. Only the two evidence-bearing ones: they are a judgement about what
// was said, and the bias here is towards one conversation carrying several
// subjects. The other two are statements about the recording itself — a ceiling
// that must hold, and a pause long enough to be a separate sitting — and
// dissolving those would put two unrelated recordings in one conversation.
const MERGEABLE_BOUNDARIES = new Set([null, 'soft-gap', 'semantic']);

function groupDuration(group) {
  return Date.parse(group.blocks.at(-1).endedAt) - Date.parse(group.blocks[0].startedAt);
}

function groupCharacters(group) {
  return group.blocks.reduce((sum, block) => sum + (block.characterCount || 0), 0);
}

// Why the block at a candidate position begins a new conversation, or null when
// it continues the current one. Pure, so the rules can be read and tested on
// their own rather than inferred from the loop that applies them.
//
// Order is the policy: a ceiling that must not be exceeded, then the gap that
// separates two sittings, and only then the two evidence-bearing rules. A gap
// shorter than the hard gap never decides anything by itself.
function boundaryReason({
  gapMs, similarity, prominence, fullContext, projectedDurationMs, projectedCharacters,
}, options) {
  if (projectedDurationMs > options.maximumDurationMs || projectedCharacters > options.maximumCharacters) return 'safety';
  if (gapMs >= options.hardGapMs) return 'hard-gap';
  // No embedding, no opinion. The conversation stays whole and this position is
  // judged again on the next run, once the embedding job has caught up.
  if (!Number.isFinite(similarity)) return null;
  // A long pause the subject did not survive. Both halves are required: the
  // pause alone is a break in a meeting, the dissimilarity alone is ordinary
  // between two consecutive utterances.
  if (gapMs >= options.softGapMs && similarity <= options.semanticSimilarityThreshold) return 'soft-gap';
  // A valley in the running similarity, and only where a full context window
  // exists on both sides. Without that, one aside — or the newest utterance of
  // a recording that is still going — would cut a conversation that the speech
  // after it shows was never interrupted.
  if (fullContext && Number.isFinite(prominence)
    && similarity <= options.valleyThreshold
    && prominence >= options.semanticValleyProminence) return 'semantic';
  return null;
}

function detectBoundaries(blocks, options = {}) {
  if (!blocks.length) return [];
  const required = [
    'hardGapMs', 'softGapMs', 'minimumDurationMs', 'valleyQuantile',
    'semanticSimilarityThreshold', 'semanticValleyProminence',
    'semanticContextSegments', 'maximumDurationMs', 'maximumCharacters',
  ];
  if (required.some((key) => !Number.isFinite(options[key]))) {
    throw new Error('Boundary thresholds must be supplied by validated configuration.');
  }
  const minimumDurationMs = options.minimumDurationMs;
  const contextSegments = options.semanticContextSegments;
  const similarities = blocks.slice(1).map((_, index) => contextualSimilarity(blocks, index + 1, contextSegments));
  const sorted = similarities.filter(Number.isFinite).sort((left, right) => left - right);
  const adaptiveThreshold = sorted.length
    ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * options.valleyQuantile))]
    : -1;
  const valleyThreshold = options.valleyThreshold
    ?? Math.min(options.semanticSimilarityThreshold, adaptiveThreshold);
  const conversations = [];
  let current = { blocks: [blocks[0]], boundaryScore: null, boundaryReason: null };
  let currentCharacters = blocks[0].characterCount || 0;
  for (let index = 1; index < blocks.length; index += 1) {
    const previous = blocks[index - 1];
    const block = blocks[index];
    const gapMs = Date.parse(block.startedAt) - Date.parse(previous.endedAt);
    const similarity = similarities[index - 1];
    const baseline = surroundingBaseline(similarities, index - 1, contextSegments);
    const prominence = baseline === null ? null : baseline - similarity;
    const projectedCharacters = currentCharacters + (block.characterCount || 0);
    const reason = boundaryReason({
      gapMs,
      similarity,
      prominence,
      fullContext: index - contextSegments >= 0 && index + contextSegments <= blocks.length,
      projectedDurationMs: Date.parse(block.endedAt) - Date.parse(current.blocks[0].startedAt),
      projectedCharacters,
    }, { ...options, valleyThreshold });
    if (reason) {
      conversations.push(current);
      current = {
        blocks: [block],
        boundaryScore: Number.isFinite(similarity) ? similarity : null,
        boundaryReason: reason,
      };
      currentCharacters = block.characterCount || 0;
    } else {
      current.blocks.push(block);
      currentCharacters = projectedCharacters;
    }
  }
  conversations.push(current);
  for (let index = 0; index < conversations.length; index += 1) {
    const group = conversations[index];
    const duration = groupDuration(group);
    if (duration >= minimumDurationMs || conversations.length === 1) continue;
    const left = conversations[index - 1];
    const right = conversations[index + 1];
    const canMerge = (target, prepend = false) => {
      if (!target) return false;
      const combined = {
        blocks: prepend ? [...group.blocks, ...target.blocks] : [...target.blocks, ...group.blocks],
      };
      return groupDuration(combined) <= options.maximumDurationMs
        && groupCharacters(combined) <= options.maximumCharacters;
    };
    const canMergeLeft = canMerge(left) && MERGEABLE_BOUNDARIES.has(group.boundaryReason);
    const canMergeRight = canMerge(right, true) && MERGEABLE_BOUNDARIES.has(right?.boundaryReason);
    if (!canMergeLeft && canMergeRight) {
      right.blocks.unshift(...group.blocks);
      right.boundaryScore = group.boundaryScore;
      right.boundaryReason = group.boundaryReason;
      conversations.splice(index, 1);
      index -= 1;
    } else if (canMergeLeft && !canMergeRight) {
      left.blocks.push(...group.blocks);
      conversations.splice(index, 1);
      index -= 1;
    } else if (canMergeLeft && canMergeRight) {
      const groupVector = averageEmbeddings(group.blocks);
      const leftVector = averageEmbeddings(left.blocks);
      const rightVector = averageEmbeddings(right.blocks);
      const leftScore = groupVector && leftVector ? cosine(groupVector, leftVector) : -1;
      const rightScore = groupVector && rightVector ? cosine(groupVector, rightVector) : -1;
      if (leftScore >= rightScore) left.blocks.push(...group.blocks);
      else {
        right.blocks.unshift(...group.blocks);
        right.boundaryScore = group.boundaryScore;
        right.boundaryReason = group.boundaryReason;
      }
      conversations.splice(index, 1);
      index -= 1;
    }
  }
  return conversations.map((group) => ({
    id: crypto.randomUUID(), segmentIds: group.blocks.flatMap((block) => block.segmentIds || [block.id]),
    startedAt: group.blocks[0].startedAt, endedAt: group.blocks.at(-1).endedAt,
    boundaryScore: group.boundaryScore,
  }));
}

module.exports = { cosine, averageEmbeddings, contextualSimilarity, boundaryReason, detectBoundaries };
