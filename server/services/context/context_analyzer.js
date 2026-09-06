'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { getConfig } = require('../../config');

const TEXT_TYPES = new Set([
  'text/plain', 'text/markdown', 'text/csv', 'application/json',
]);
const IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const PDF = 'application/pdf';
const DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

function normalizeType(value) {
  return String(value || '').split(';', 1)[0].trim().toLowerCase();
}

function fileKind(contentType) {
  const type = normalizeType(contentType);
  if (IMAGE_TYPES.has(type)) return 'image';
  if (TEXT_TYPES.has(type) || type === PDF || type === DOCX) return 'document';
  return 'file';
}

function bounded(value) {
  const text = String(value || '').replace(/\u0000/g, '').trim();
  const maximum = getConfig().contextExtractionMaxCharacters;
  return text.length <= maximum ? text : text.slice(0, maximum);
}

async function extract(row) {
  const type = normalizeType(row.content_type);
  if (IMAGE_TYPES.has(type)) return { mode: 'vision', extractedText: null };
  if (TEXT_TYPES.has(type)) {
    return { mode: 'text', extractedText: bounded(await fs.promises.readFile(row.original_path, 'utf8')) };
  }
  if (type === PDF) {
    const pdf = require('pdf-parse');
    const result = await pdf(await fs.promises.readFile(row.original_path));
    const text = bounded(result.text);
    if (!text) return { mode: 'skipped', code: 'NO_EXTRACTABLE_TEXT', message: 'This PDF has no extractable text.' };
    return { mode: 'text', extractedText: text };
  }
  if (type === DOCX) {
    const mammoth = require('mammoth');
    const result = await mammoth.extractRawText({ path: path.resolve(row.original_path) });
    const text = bounded(result.value);
    if (!text) return { mode: 'skipped', code: 'NO_EXTRACTABLE_TEXT', message: 'This document has no extractable text.' };
    return { mode: 'text', extractedText: text };
  }
  return { mode: 'skipped', code: 'UNSUPPORTED_FILE_TYPE', message: 'Saved, but this file type is not supported for analysis.' };
}

module.exports = { extract, fileKind, normalizeType, IMAGE_TYPES };
