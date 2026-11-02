'use strict';

const zlib = require('node:zlib');

const END_OF_CENTRAL_DIRECTORY = 0x06054b50;
const CENTRAL_ENTRY = 0x02014b50;
const LOCAL_HEADER = 0x04034b50;
const ZIP64_MARKER = 0xffffffff;

function fail(message) {
  return Object.assign(new Error(message), { code: 'LOCAL_ARCHIVE_INVALID' });
}

// Reads one member out of a zip archive held in memory.
//
// The runtime library is published inside a Python wheel, which is a zip. The
// wheels are about a megabyte, so a small reader of exactly the two layouts they
// use (stored, deflated; no ZIP64) is less to maintain and to trust than a
// dependency or a platform `unzip`, which Debian's slim images do not ship.
function readZipMember(archive, memberName) {
  let end = -1;
  for (let index = archive.length - 22; index >= Math.max(0, archive.length - 22 - 0xffff); index -= 1) {
    if (archive.readUInt32LE(index) === END_OF_CENTRAL_DIRECTORY) { end = index; break; }
  }
  if (end < 0) throw fail('The archive has no central directory.');
  const entries = archive.readUInt16LE(end + 10);
  let cursor = archive.readUInt32LE(end + 16);
  for (let entry = 0; entry < entries; entry += 1) {
    if (archive.readUInt32LE(cursor) !== CENTRAL_ENTRY) throw fail('The archive directory is corrupt.');
    const method = archive.readUInt16LE(cursor + 10);
    const compressedSize = archive.readUInt32LE(cursor + 20);
    const size = archive.readUInt32LE(cursor + 24);
    const nameLength = archive.readUInt16LE(cursor + 28);
    const extraLength = archive.readUInt16LE(cursor + 30);
    const commentLength = archive.readUInt16LE(cursor + 32);
    const headerOffset = archive.readUInt32LE(cursor + 42);
    const name = archive.toString('utf8', cursor + 46, cursor + 46 + nameLength);
    cursor += 46 + nameLength + extraLength + commentLength;
    if (name !== memberName) continue;
    if ([compressedSize, size, headerOffset].includes(ZIP64_MARKER)) throw fail('ZIP64 archives are not supported.');
    if (archive.readUInt32LE(headerOffset) !== LOCAL_HEADER) throw fail('The archive member header is corrupt.');
    const start = headerOffset + 30 + archive.readUInt16LE(headerOffset + 26) + archive.readUInt16LE(headerOffset + 28);
    const raw = archive.subarray(start, start + compressedSize);
    let data;
    if (method === 0) data = Buffer.from(raw);
    else if (method === 8) data = zlib.inflateRawSync(raw);
    else throw fail(`Unsupported compression method ${method}.`);
    if (data.length !== size) throw fail(`${memberName} has the wrong size after extraction.`);
    return data;
  }
  throw fail(`${memberName} is not in the archive.`);
}

module.exports = { readZipMember };
