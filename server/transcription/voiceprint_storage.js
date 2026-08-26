'use strict';

const vectors = require('./speaker_embeddings');
const { sealBuffer, unsealBuffer } = require('../utils/crypto');

// Encryption boundary for enrolled voice biometrics.
//
// A voiceprint centroid and its preview clip identify a specific named person,
// which puts them in a different class from the rest of the store: they are the
// only rows that would let someone reading the database file recognise a voice.
// Every read and write of those two columns goes through here so the boundary
// is one file rather than a rule nobody remembers.
//
// Deliberately NOT applied to `speaker_clusters.centroid_embedding` or
// `speaker_turns.embedding`: those are anonymous, per-session, and deleted with
// the session — and to `search_embeddings.embedding`, which sqlite-vec reads
// inside SQL, where an encrypted blob is not a vector.
//
// `unsealBuffer` passes unsealed input through, so a database restored from a
// backup taken before migration 025 still reads.

// Float32Array requires the underlying byte offset to be 4-byte aligned.
// Decryption returns a pooled buffer whose offset happens to satisfy that
// today, but "happens to" is not a guarantee worth a corrupt read later.
function alignedVector(buffer) {
  if (!buffer) return null;
  return vectors.fromBuffer(buffer.byteOffset % Float32Array.BYTES_PER_ELEMENT === 0 ? buffer : Buffer.from(buffer));
}

// Reads a sealed centroid column into a vector.
function readCentroid(value) {
  return value ? alignedVector(unsealBuffer(value)) : null;
}

// Seals a vector or an already-serialized centroid buffer for storage.
function sealCentroid(value) {
  if (!value) return null;
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  return sealBuffer(bytes);
}

function readPreviewAudio(value) {
  return value ? unsealBuffer(value) : null;
}

function sealPreviewAudio(value) {
  return value ? sealBuffer(value) : null;
}

// `vectors.rank` for sealed rows. Same ordering contract: best score first.
function rankVoiceprints(vector, rows, field = 'centroid_embedding') {
  return rows
    .map((row) => ({ row, score: vectors.cosine(vector, readCentroid(row[field])) }))
    .sort((left, right) => right.score - left.score);
}

module.exports = { readCentroid, sealCentroid, readPreviewAudio, sealPreviewAudio, rankVoiceprints };
