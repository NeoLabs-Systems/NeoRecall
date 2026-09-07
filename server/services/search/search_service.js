'use strict';

const { getDatabase, isVectorReady } = require('../../db/database');
const { getConfig } = require('../../config');
const embeddings = require('../../embeddings/embedding_service');
const scorer = require('./retrieval_scorer');

function ftsExpression(query) {
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
  const terms = [...segmenter.segment(query)].filter((entry) => entry.isWordLike).map((entry) => entry.segment.replace(/"/g, '""')).slice(0, 30);
  return terms.map((term) => `"${term}"`).join(' OR ');
}

// Every stored embedding is unit length, so the squared L2 distance the vector
// index reports and cosine similarity are the same measurement: d² = 2 - 2·cos.
function cosineSimilarity(distance) {
  return Math.max(-1, Math.min(1, 1 - (distance * distance) / 2));
}

function rrfAdd(map, rows, branch) {
  const k = getConfig().rrfK;
  rows.forEach((row, index) => {
    const current = map.get(row.id) || { id: row.id, relevance: 0, branches: {} };
    current.relevance += 1 / (k + index + 1);
    current.branches[branch] = index + 1;
    map.set(row.id, current);
  });
}

// Reads every candidate document in one statement.
//
// The fused set is up to a few hundred ids and each one used to cost its own
// prepared lookup — twice over, because the kind filter looked them up again.
function documentsById(db, userId, ids) {
  const found = new Map();
  for (let offset = 0; offset < ids.length; offset += 400) {
    const batch = ids.slice(offset, offset + 400);
    const rows = db.prepare(`SELECT * FROM search_documents WHERE user_id=? AND id IN (${batch.map(() => '?').join(',')})`).all(userId, ...batch);
    for (const row of rows) found.set(row.id, row);
  }
  return found;
}

/**
 * Hybrid retrieval over one user's archive.
 *
 * `from`/`to` are ISO instants bounding `occurred_at`; `wholeWindow` adds the
 * window's own documents newest-first as a third branch, which is what answers a
 * question about a period rather than about a topic.
 *
 * Returns the ranked candidates plus `weakCount`: semantic neighbours that were
 * near enough to be returned by the index but too far to be evidence.
 */
async function search(userId, query, { limit = 20, kinds = [], from = null, to = null, wholeWindow = false } = {}) {
  const db = getDatabase();
  const config = getConfig();
  const requestedLimit = Math.min(100, Math.max(1, Number(limit) || 20));
  const candidateLimit = Math.max(50, requestedLimit * 4);
  const kindClause = kinds.length ? ` AND d.kind IN (${kinds.map(() => '?').join(',')})` : '';
  const windowClause = `${from ? ' AND d.occurred_at>=?' : ''}${to ? ' AND d.occurred_at<?' : ''}`;
  const windowValues = [from, to].filter((value) => value !== null);
  const expression = ftsExpression(query);
  const keywordRows = expression ? db.prepare(`SELECT d.id,bm25(search_fts) rank FROM search_fts
    JOIN search_documents d ON d.id=search_fts.rowid WHERE search_fts MATCH ? AND d.user_id=?${kindClause}${windowClause}
    ORDER BY rank LIMIT ?`).all(expression, userId, ...kinds, ...windowValues, candidateLimit) : [];

  let semanticRows = [];
  let weakCount = 0;
  if (isVectorReady()) {
    const queryVector = await embeddings.embed(query, 'query');
    const neighbours = db.prepare('SELECT document_id id,distance FROM vec_search WHERE embedding MATCH ? AND user_id=? AND k=?')
      .all(queryVector, userId, BigInt(candidateLimit)).map((row) => ({ id: Number(row.id), similarity: cosineSimilarity(row.distance) }));
    semanticRows = neighbours.filter((row) => row.similarity >= config.semanticSimilarityFloor);
    weakCount = neighbours.length - semanticRows.length;
  }

  const windowRows = wholeWindow && (from || to)
    ? db.prepare(`SELECT d.id FROM search_documents d WHERE d.user_id=?${kindClause}${windowClause}
      ORDER BY d.occurred_at DESC LIMIT ?`).all(userId, ...kinds, ...windowValues, config.askTimeWindowLimit)
    : [];

  const fused = new Map();
  rrfAdd(fused, keywordRows, 'keyword');
  rrfAdd(fused, semanticRows, 'semantic');
  rrfAdd(fused, windowRows, 'window');
  const similarityById = new Map(semanticRows.map((row) => [row.id, row.similarity]));
  const branchCount = 1 + (isVectorReady() ? 1 : 0) + (windowRows.length ? 1 : 0);
  const maxRrf = branchCount / (config.rrfK + 1);

  const items = [...fused.values()];
  const documents = documentsById(db, userId, items.map((item) => item.id));
  const candidates = items.map((item) => {
    const document = documents.get(item.id);
    if (!document) return null;
    if (kinds.length && !kinds.includes(document.kind)) return null;
    if (from && document.occurred_at < from) return null;
    if (to && document.occurred_at >= to) return null;
    const relevance = Math.min(1, item.relevance / maxRrf);
    // Scored the same way whatever the kind. Segments used to skip the scorer
    // and keep their raw fused relevance, which let a passing remark outrank the
    // memory written about the thing the question was actually asking for.
    return {
      ...document,
      relevance,
      similarity: similarityById.get(item.id) ?? null,
      score: scorer.score({ relevance, occurredAt: document.occurred_at, importance: document.importance }, config),
      branches: item.branches,
    };
  }).filter(Boolean).sort((left, right) => right.score - left.score).slice(0, requestedLimit);
  return { results: candidates, weakCount };
}

// The most recent thing the archive holds, whatever kind it is.
//
// Read when a question's period comes back empty: "nothing was recorded today"
// is only half an answer, and the other half — when something last was — is
// usually the part that explains why.
function latestActivity(userId, { kinds = [] } = {}) {
  const kindClause = kinds.length ? ` AND kind IN (${kinds.map(() => '?').join(',')})` : '';
  return getDatabase().prepare(`SELECT kind,title,occurred_at FROM search_documents
    WHERE user_id=?${kindClause} ORDER BY occurred_at DESC LIMIT 1`).get(userId, ...kinds) || null;
}

module.exports = { search, latestActivity, ftsExpression, cosineSimilarity };
