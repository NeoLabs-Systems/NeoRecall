'use strict';

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

function groupDuration(group) {
  return Date.parse(group.blocks.at(-1).endedAt) - Date.parse(group.blocks[0].startedAt);
}

function groupCharacters(group) {
  return group.blocks.reduce((sum, block) => sum + (block.characterCount || 0), 0);
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
  const hardGapMs = options.hardGapMs;
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
    const strongSemanticShift = Number.isFinite(similarity)
      && similarity <= valleyThreshold
      && (
        prominence === null
          ? similarity <= valleyThreshold - options.semanticValleyProminence
          : prominence >= options.semanticValleyProminence
      );
    const softGapShift = gapMs >= options.softGapMs
      && (!Number.isFinite(similarity) || similarity <= options.semanticSimilarityThreshold);
    const projectedDuration = Date.parse(block.endedAt) - Date.parse(current.blocks[0].startedAt);
    const projectedCharacters = currentCharacters + (block.characterCount || 0);
    const safetyBoundary = projectedDuration > options.maximumDurationMs
      || projectedCharacters > options.maximumCharacters;
    if (gapMs >= hardGapMs || softGapShift || strongSemanticShift || safetyBoundary) {
      conversations.push(current);
      const boundaryReason = safetyBoundary ? 'safety'
        : gapMs >= hardGapMs ? 'hard-gap'
          : softGapShift ? 'soft-gap' : 'semantic';
      current = {
        blocks: [block],
        boundaryScore: Number.isFinite(similarity) ? similarity : null,
        boundaryReason,
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
    const canMergeLeft = canMerge(left) && group.boundaryReason !== 'safety';
    const canMergeRight = canMerge(right, true) && right?.boundaryReason !== 'safety';
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

module.exports = { cosine, averageEmbeddings, contextualSimilarity, detectBoundaries };
