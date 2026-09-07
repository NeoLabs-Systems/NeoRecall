'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-clustering-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const clustering = require('../../server/speakers/clustering');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

// Thresholds are read rather than written down, so these stay true as defaults
// move. The geometry is the same trick the matching tests use: every vector is a
// unit vector whose first component is its cosine to [1,0], so a case can state
// the similarity it needs instead of picking coordinates and hoping.
const limits = () => require('../../server/services/settings/processing_settings_service').get();
function at(similarity, axis = 1) {
  const vector = new Float32Array([similarity, 0, 0]);
  vector[axis] = Math.sqrt(Math.max(0, 1 - similarity * similarity));
  return vector;
}
function voice(id, ...embeddings) { return { id, embeddings }; }
function groupsOf(result) {
  return result.map((group) => [...group.memberIds].sort()).sort((left, right) => left[0].localeCompare(right[0]));
}

test('two voices at the merge threshold become one, and just below it stay apart', () => {
  const { speakerClusterMergeThreshold: bar } = limits();
  const merged = clustering.cluster([voice('a', new Float32Array([1, 0, 0])), voice('b', at(bar))], { threshold: bar });
  assert.deepEqual(groupsOf(merged), [['a', 'b']]);

  const apart = clustering.cluster(
    [voice('a', new Float32Array([1, 0, 0])), voice('b', at(bar - 0.01))], { threshold: bar },
  );
  assert.deepEqual(groupsOf(apart), [['a'], ['b']]);
});

test('a forbidden pair never merges, however alike the two sound', () => {
  const { speakerClusterMergeThreshold: bar } = limits();
  // Two people talking over each other on one microphone can score arbitrarily
  // high — the diarizer blends them. Overlap is the harder evidence and has to
  // win over similarity, or the pass merges the two speakers in the room.
  const result = clustering.cluster(
    [voice('a', new Float32Array([1, 0, 0])), voice('b', at(0.99))],
    { threshold: bar, forbidden: (left, right) => [left, right].sort().join() === 'a,b' },
  );
  assert.deepEqual(groupsOf(result), [['a'], ['b']]);
});

test('a constraint survives the merge that hides the voice carrying it', () => {
  const { speakerClusterMergeThreshold: bar } = limits();
  // b and c merge first. The a/b constraint must then forbid a joining the
  // group, or a cannot-link is defeated by merging in a different order.
  const result = clustering.cluster(
    [voice('a', new Float32Array([1, 0, 0])), voice('b', at(0.97)), voice('c', at(0.98))],
    { threshold: bar, forbidden: (left, right) => [left, right].sort().join() === 'a,b' },
  );
  assert.deepEqual(groupsOf(result), [['a'], ['b', 'c']]);
});

test('a near-tie against a voice below the bar merges nothing', () => {
  const { speakerClusterMergeThreshold: bar, speakerClusterMargin: margin } = limits();
  // The reading is genuinely doubtful only when the rival does not itself clear
  // the bar: the pair barely qualifies, something almost as close does not, and
  // both readings are equally weak. That is the case the margin exists for.
  const result = clustering.cluster([
    voice('a', new Float32Array([1, 0, 0])),
    voice('b', at(bar + margin / 4, 1)),
    voice('c', at(bar - margin / 4, 2)),
  ], { threshold: bar, margin });
  assert.equal(result.length, 3, 'a borderline pair with an equally borderline rival stays apart');
});

test('several copies of one voice do not block each other into staying apart', () => {
  const { speakerClusterMergeThreshold: bar, speakerClusterMargin: margin } = limits();
  // The reported bug in miniature. Three clusters that are one person score
  // alike against each other, so each one's nearest rival is another copy of
  // itself. Applying the margin against a rival that also clears the bar has all
  // three block all the others, nothing merges, and the person keeps three
  // labels — which is precisely the complaint.
  const result = clustering.cluster([
    voice('a', new Float32Array([1, 0, 0])),
    voice('b', at(0.97, 1)),
    voice('c', at(0.96, 1)),
  ], { threshold: bar, margin });
  assert.deepEqual(groupsOf(result), [['a', 'b', 'c']]);
});

test('a clear pair still merges while a third voice hovers nearby', () => {
  const { speakerClusterMergeThreshold: bar, speakerClusterMargin: margin } = limits();
  // The margin must not be so blunt that any bystander blocks every merge. c
  // sits just under the bar — close enough to be considered, not close enough to
  // join — which is the case the margin must let through.
  const result = clustering.cluster([
    voice('a', new Float32Array([1, 0, 0])),
    voice('b', at(0.95, 1)),
    voice('c', at(bar - 0.02, 2)),
  ], { threshold: bar, margin });
  assert.deepEqual(groupsOf(result), [['a', 'b'], ['c']]);
});

test('the result is a fixed point: clustering it again changes nothing', () => {
  const { speakerClusterMergeThreshold: bar, speakerClusterMargin: margin } = limits();
  const items = [
    voice('a', new Float32Array([1, 0, 0])),
    voice('b', at(0.96, 1)),
    voice('c', at(0.05, 2)),
  ];
  const first = clustering.cluster(items, { threshold: bar, margin });
  // Re-feed each group as one voice carrying all its members' measurements,
  // which is what the engine does on a second run over the same conversation.
  const regrouped = first.map((group) => voice(
    group.id,
    ...group.memberIds.flatMap((id) => items.find((item) => item.id === id).embeddings),
  ));
  assert.deepEqual(groupsOf(clustering.cluster(regrouped, { threshold: bar, margin })),
    groupsOf(first).map((members) => [members[0]]));
});

test('a voice with no usable measurement comes back as itself rather than vanishing', () => {
  const { speakerClusterMergeThreshold: bar } = limits();
  // Every turn overlapped, so nothing about this voice is safe to compare. It
  // still has to appear in the output or the caller's bookkeeping loses a
  // cluster that real transcript rows point at.
  const result = clustering.cluster(
    [voice('a', new Float32Array([1, 0, 0])), { id: 'silent', embeddings: [] }], { threshold: bar },
  );
  assert.deepEqual(groupsOf(result), [['a'], ['silent']]);
});

test('averaging keeps one stray measurement from carrying a whole voice', () => {
  const { speakerClusterMergeThreshold: bar } = limits();
  // Single linkage would merge on the one close pair. A room recording produces
  // exactly this — one bad turn that resembles somebody else — and merging on it
  // is how two people become one.
  const result = clustering.cluster([
    voice('a', new Float32Array([1, 0, 0]), new Float32Array([1, 0, 0]), new Float32Array([1, 0, 0])),
    voice('b', at(0.99), at(0.1, 2), at(0.1, 2)),
  ], { threshold: bar });
  assert.deepEqual(groupsOf(result), [['a'], ['b']], 'the bulk of the evidence decides, not the closest pair');
});
