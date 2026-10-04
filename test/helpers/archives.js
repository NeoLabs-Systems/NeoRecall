'use strict';

const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function crc32(buffer) {
  let crc = ~0;
  for (const byte of buffer) { crc ^= byte; for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
  return ~crc >>> 0;
}

// A zip archive holding `entries` ({ name: Buffer }), each stored or deflated.
function makeZip(entries, { deflate = true } = {}) {
  const locals = [];
  const central = [];
  let offset = 0;
  for (const [name, data] of Object.entries(entries)) {
    const method = deflate ? 8 : 0;
    const packed = deflate ? zlib.deflateRawSync(data) : data;
    const nameBytes = Buffer.from(name);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); header.writeUInt16LE(20, 4); header.writeUInt16LE(method, 8);
    header.writeUInt32LE(crc32(data), 14); header.writeUInt32LE(packed.length, 18); header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(nameBytes.length, 26);
    const entry = Buffer.alloc(46);
    entry.writeUInt32LE(0x02014b50, 0); entry.writeUInt16LE(20, 4); entry.writeUInt16LE(20, 6); entry.writeUInt16LE(method, 10);
    entry.writeUInt32LE(crc32(data), 16); entry.writeUInt32LE(packed.length, 20); entry.writeUInt32LE(data.length, 24);
    entry.writeUInt16LE(nameBytes.length, 28); entry.writeUInt32LE(offset, 42);
    locals.push(header, nameBytes, packed);
    central.push(entry, nameBytes);
    offset += header.length + nameBytes.length + packed.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(Object.keys(entries).length, 8); end.writeUInt16LE(Object.keys(entries).length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

// A .tar.gz whose single top-level directory is `top`, holding `files`
// ({ relativePath: Buffer }), built with the system tar the installer also uses.
function makeTarGz(top, files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-tar-'));
  try {
    for (const [relative, data] of Object.entries(files)) {
      const target = path.join(root, top, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, data, { mode: 0o755 });
    }
    const archive = path.join(root, 'out.tar.gz');
    execFileSync('tar', ['-czf', archive, '-C', root, top]);
    return fs.readFileSync(archive);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

const sha256 = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex');

module.exports = { makeZip, makeTarGz, sha256 };
