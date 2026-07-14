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

function rrfAdd(map, rows, branch) {
  const k = getConfig().rrfK;
  rows.forEach((row, index) => {
    const current = map.get(row.id) || { id: row.id, relevance: 0, branches: {} };
    current.relevance += 1 / (k + index + 1);
    current.branches[branch] = index + 1;
    map.set(row.id, current);
  });
}

async function search(userId, query, { limit = 20, kinds = [] } = {}) {
  const db = getDatabase();
  const requestedLimit = Math.min(100, Math.max(1, Number(limit) || 20));
  const candidateLimit = Math.max(50, requestedLimit * 4);
  const kindClause = kinds.length ? ` AND d.kind IN (${kinds.map(() => '?').join(',')})` : '';
  const expression = ftsExpression(query);
  const keywordRows = expression ? db.prepare(`SELECT d.id,bm25(search_fts) rank FROM search_fts
    JOIN search_documents d ON d.id=search_fts.rowid WHERE search_fts MATCH ? AND d.user_id=?${kindClause}
    ORDER BY rank LIMIT ?`).all(expression, userId, ...kinds, candidateLimit) : [];
  let semanticRows = [];
  if (isVectorReady()) {
    const queryVector = await embeddings.embed(query, 'query');
    semanticRows = db.prepare(`SELECT document_id id,distance FROM vec_search WHERE embedding MATCH ? AND user_id=? AND k=?`)
      .all(queryVector, userId, BigInt(candidateLimit)).map((row) => ({ ...row, id: Number(row.id) }))
      .filter((row) => !kinds.length || kinds.includes(db.prepare('SELECT kind FROM search_documents WHERE id=?').get(row.id)?.kind));
  }
  const fused = new Map();
  rrfAdd(fused, keywordRows, 'keyword');
  rrfAdd(fused, semanticRows, 'semantic');
  const maxRrf = 2 / (getConfig().rrfK + 1);
  const candidates = [...fused.values()].map((item) => {
    const document = db.prepare('SELECT * FROM search_documents WHERE id=? AND user_id=?').get(item.id, userId);
    if (!document) return null;
    const relevance = Math.min(1, item.relevance / maxRrf);
    const finalScore = document.kind === 'segment' ? relevance : scorer.score({ relevance, occurredAt: document.occurred_at, importance: document.importance }, getConfig());
    return { ...document, relevance, score: finalScore, branches: item.branches };
  }).filter(Boolean).sort((left, right) => right.score - left.score).slice(0, requestedLimit);
  return candidates;
}

module.exports = { search, ftsExpression };
