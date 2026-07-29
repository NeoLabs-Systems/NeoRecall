'use strict';

const fs = require('node:fs');
require('../runtime/env').loadEnvironment();
const { ensureRuntimeDirs } = require('../runtime/paths');
const { getDatabase } = require('../server/db/database');

function main() {
  const runtime = ensureRuntimeDirs();
  const db = getDatabase();
  const invalidTerminal = db.prepare(`SELECT id,state,temporary_path FROM audio_chunks
    WHERE state IN ('transcribed','silent') AND (temporary_path IS NOT NULL OR persisted_at IS NULL OR server_deleted_at IS NULL)`).all();
  if (invalidTerminal.length) throw new Error(`${invalidTerminal.length} terminal chunks violate the deletion receipt invariant.`);
  const referenced = new Set(db.prepare('SELECT temporary_path FROM audio_chunks WHERE temporary_path IS NOT NULL').all().map((row) => row.temporary_path));
  const files = fs.readdirSync(runtime.audioTmp, { withFileTypes: true }).filter((entry) => entry.isFile()).map((entry) => require('node:path').join(runtime.audioTmp, entry.name));
  const unreferenced = files.filter((file) => !referenced.has(file));
  if (unreferenced.length) throw new Error(`Unreferenced temporary audio remains: ${unreferenced.join(', ')}`);
  const audioBlobs = db.prepare(`SELECT COUNT(*) count FROM audio_chunks
    WHERE typeof(temporary_path)='blob' OR typeof(transcript_sha256)='blob'`).get().count;
  if (audioBlobs) throw new Error('Audio chunk metadata contains an unexpected BLOB.');
  const invalidImports = db.prepare("SELECT id FROM imports WHERE state='completed' AND temporary_path IS NOT NULL").all();
  if (invalidImports.length) throw new Error(`${invalidImports.length} completed imports still reference source audio.`);
  const importReferences = new Set([
    ...db.prepare('SELECT temporary_path FROM imports WHERE temporary_path IS NOT NULL').all(),
    ...db.prepare('SELECT temporary_path FROM import_parts WHERE temporary_path IS NOT NULL').all(),
  ].map((row) => row.temporary_path));
  const importFiles = fs.readdirSync(runtime.importTmp, { withFileTypes: true }).filter((entry) => entry.isFile()).map((entry) => require('node:path').join(runtime.importTmp, entry.name));
  const orphanImports = importFiles.filter((file) => !importReferences.has(file));
  if (orphanImports.length) throw new Error(`Unreferenced import audio remains: ${orphanImports.join(', ')}`);
  process.stdout.write(`Verified ${db.prepare("SELECT COUNT(*) count FROM audio_chunks WHERE state IN ('transcribed','silent')").get().count} terminal chunks; no original recording chunks or unreferenced temporary audio were found.\n`);
}

try { main(); } catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
