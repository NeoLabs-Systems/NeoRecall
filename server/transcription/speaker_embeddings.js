'use strict';

// Beyond this many samples a centroid stops moving in any meaningful way, and a
// profile enrolled from one microphone can never migrate toward the same voice
// heard through another. Capping the weight of the accumulated history keeps a
// profile adaptive for the lifetime of a recording setup instead of freezing it
// around whatever the first conversation sounded like.
const CENTROID_WEIGHT_CAP = 50;

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

// Speaker embeddings are not unit vectors, and their magnitude tracks loudness
// and turn length rather than who was talking. Averaging them as they come
// lets one loud or long sample dominate a centroid and drag its direction off
// the voice it stands for, until the person stops matching their own profile
// and a duplicate is minted for them. Comparison is unaffected — cosine already
// ignores magnitude — so this only matters where vectors are combined.
function normalize(vector) {
  if (!vector) return null;
  let norm = 0;
  for (let i = 0; i < vector.length; i += 1) norm += vector[i] ** 2;
  if (!norm) return vector;
  const scale = 1 / Math.sqrt(norm);
  const output = new Float32Array(vector.length);
  for (let i = 0; i < vector.length; i += 1) output[i] = vector[i] * scale;
  return output;
}

// Folds one sample into a centroid as a weighted mean of directions. Accepts a
// centroid stored before normalization existed: it is normalized on the way in,
// so an older profile converges to a unit vector on its next update with no
// migration and no change to how it scores in the meantime.
function updateCentroid(existing, existingCount, sample) {
  const current = normalize(existing);
  const next = normalize(sample);
  const weight = Math.min(Math.max(0, existingCount), CENTROID_WEIGHT_CAP);
  const output = new Float32Array(next.length);
  for (let i = 0; i < next.length; i += 1) output[i] = (current[i] * weight + next[i]) / (weight + 1);
  return normalize(output);
}

function rank(vector, rows, field = 'centroid_embedding') {
  return rows.map((row) => ({ row, score: cosine(vector, fromBuffer(row[field])) })).sort((left, right) => right.score - left.score);
}

module.exports = { fromBuffer, cosine, normalize, updateCentroid, rank, CENTROID_WEIGHT_CAP };
