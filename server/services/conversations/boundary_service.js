'use strict';

const crypto = require('node:crypto');

function cosine(left, right) {
  if (!left || !right || left.length !== right.length) return 0;
  let dot = 0; let a = 0; let b = 0;
  for (let index = 0; index < left.length; index += 1) { dot += left[index] * right[index]; a += left[index] ** 2; b += right[index] ** 2; }
  return a && b ? dot / Math.sqrt(a * b) : 0;
}

function detectBoundaries(blocks, options = {}) {
  if (!blocks.length) return [];
  if (!Number.isFinite(options.hardGapMs) || !Number.isFinite(options.minimumDurationMs) || !Number.isFinite(options.valleyQuantile)) {
    throw new Error('Boundary thresholds must be supplied by validated configuration.');
  }
  const hardGapMs = options.hardGapMs;
  const minimumDurationMs = options.minimumDurationMs;
  const similarities = blocks.slice(1).map((block, index) => cosine(block.embedding, blocks[index].embedding));
  const sorted = [...similarities].sort((a, b) => a - b);
  const valleyThreshold = options.valleyThreshold ?? (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * options.valleyQuantile))] : -1);
  const conversations = [];
  let current = [blocks[0]];
  for (let index = 1; index < blocks.length; index += 1) {
    const previous = blocks[index - 1];
    const block = blocks[index];
    const gapMs = Date.parse(block.startedAt) - Date.parse(previous.endedAt);
    const speakerSetChanged = previous.speakerId && block.speakerId && previous.speakerId !== block.speakerId;
    const valley = similarities[index - 1] <= valleyThreshold;
    if (gapMs >= hardGapMs || (valley && speakerSetChanged)) {
      conversations.push(current);
      current = [block];
    } else current.push(block);
  }
  conversations.push(current);
  for (let index = 0; index < conversations.length; index += 1) {
    const group = conversations[index];
    const duration = Date.parse(group.at(-1).endedAt) - Date.parse(group[0].startedAt);
    if (duration >= minimumDurationMs || conversations.length === 1) continue;
    const left = conversations[index - 1];
    const right = conversations[index + 1];
    if (!left && right) { right.unshift(...group); conversations.splice(index, 1); index -= 1; }
    else if (left && !right) { left.push(...group); conversations.splice(index, 1); index -= 1; }
    else if (left && right) {
      const groupVector = group.at(-1).embedding;
      const leftScore = cosine(groupVector, left.at(-1).embedding);
      const rightScore = cosine(groupVector, right[0].embedding);
      (leftScore >= rightScore ? left : right)[leftScore >= rightScore ? 'push' : 'unshift'](...group);
      conversations.splice(index, 1); index -= 1;
    }
  }
  return conversations.map((group) => ({
    id: crypto.randomUUID(), segmentIds: group.flatMap((block) => block.segmentIds || [block.id]),
    startedAt: group[0].startedAt, endedAt: group.at(-1).endedAt,
  }));
}

module.exports = { cosine, detectBoundaries };
