'use strict';

const crypto = require('node:crypto');
const { getDatabase, isVectorReady } = require('../db/database');
const { sha256 } = require('../utils/crypto');
const embeddingService = require('./embedding_service');
const jobs = require('../services/jobs/job_service');
const manifest = require('../../models/manifest.json');
const packageJson = require('../../package.json');

function embeddingModelRevision() {
  const modelName = require('../config').getConfig().embeddingModel;
  const asset = manifest.models.find((item) => item.huggingFace?.repo === modelName);
  const modelRevision = asset?.huggingFace?.revision || 'custom';
  return `${packageJson.dependencies['@huggingface/transformers']}:${modelName}@${modelRevision}`;
}

function removeDocumentRows(database, documents) {
  const deleteDocument = database.prepare('DELETE FROM search_documents WHERE id=?');
  const deleteVector = isVectorReady() ? database.prepare('DELETE FROM vec_search WHERE document_id=?') : null;
  for (const document of documents) {
    if (deleteVector) deleteVector.run(BigInt(document.id));
    deleteDocument.run(document.id);
  }
  return documents.length;
}

function removeBySources(database, userId, sources) {
  const select = database.prepare('SELECT id FROM search_documents WHERE user_id=? AND kind=? AND source_id=?');
  const documents = sources.flatMap(({ kind, sourceId }) => select.all(userId, kind, String(sourceId)));
  return removeDocumentRows(database, documents);
}

function removeForUser(database, userId) {
  return removeDocumentRows(database, database.prepare('SELECT id FROM search_documents WHERE user_id=?').all(userId));
}

function upsertDocument({ userId, kind, sourceId, title = null, body, occurredAt, importance = 0 }, database = getDatabase()) {
  const textHash = sha256(`${title || ''}\n${body}`);
  database.prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(user_id,kind,source_id) DO UPDATE SET title=excluded.title,body=excluded.body,
    occurred_at=excluded.occurred_at,importance=excluded.importance,text_hash=excluded.text_hash,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`)
    .run(userId, kind, String(sourceId), title, body, occurredAt, importance, textHash);
  const document = database.prepare('SELECT * FROM search_documents WHERE user_id=? AND kind=? AND source_id=?').get(userId, kind, String(sourceId));
  jobs.enqueue({ userId, resourceType: 'search_document', resourceId: String(document.id), type: 'embed_search_documents', priority: 50, payload: { documentIds: [document.id] } }, database);
  return document;
}

async function embedDocuments(documentIds) {
  const db = getDatabase();
  for (const documentId of documentIds) {
    const document = db.prepare('SELECT * FROM search_documents WHERE id=?').get(documentId);
    if (!document) continue;
    const vector = await embeddingService.embed([document.title, document.body].filter(Boolean).join('\n'), 'passage');
    const modelRevision = embeddingModelRevision();
    db.transaction(() => {
      db.prepare(`INSERT INTO search_embeddings (document_id,user_id,model_revision,dimensions,embedding,text_hash)
        VALUES (?,?,?,?,?,?) ON CONFLICT(document_id) DO UPDATE SET model_revision=excluded.model_revision,dimensions=excluded.dimensions,
        embedding=excluded.embedding,text_hash=excluded.text_hash,embedded_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`)
        .run(document.id, document.user_id, modelRevision, vector.length, Buffer.from(vector.buffer), document.text_hash);
      if (isVectorReady()) {
        const vectorDocumentId = BigInt(document.id);
        db.prepare('DELETE FROM vec_search WHERE document_id=?').run(vectorDocumentId);
        db.prepare('INSERT INTO vec_search (document_id,embedding,user_id,kind) VALUES (?,?,?,?)').run(vectorDocumentId, vector, document.user_id, document.kind);
      }
    })();
  }
}

module.exports = { upsertDocument, embedDocuments, embeddingModelRevision, removeBySources, removeForUser };
