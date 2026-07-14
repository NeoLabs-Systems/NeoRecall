'use strict';

function fromBuffer(buffer) {
  if (!buffer) return null;
  return new Float32Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / Float32Array.BYTES_PER_ELEMENT);
}

function cosine(left, right) {
  if (!left || !right || left.length !== right.length) return -1;
  let dot = 0; let normLeft = 0; let normRight = 0;
  for (let i = 0; i < left.length; i += 1) { dot += left[i] * right[i]; normLeft += left[i] ** 2; normRight += right[i] ** 2; }
  return normLeft && normRight ? dot / Math.sqrt(normLeft * normRight) : -1;
}

function updateCentroid(existing, existingCount, sample) {
  const output = new Float32Array(sample.length);
  for (let i = 0; i < sample.length; i += 1) output[i] = (existing[i] * existingCount + sample[i]) / (existingCount + 1);
  return output;
}

function rank(vector, rows, field = 'centroid_embedding') {
  return rows.map((row) => ({ row, score: cosine(vector, fromBuffer(row[field])) })).sort((left, right) => right.score - left.score);
}

module.exports = { fromBuffer, cosine, updateCentroid, rank };
