'use strict';

// Stands in for whistle_worker.py: same protocol, scripted behaviour. The request's
// `language` selects the behaviour so one process can show every case.
const readline = require('node:readline');

const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
if (process.env.FAKE_FATAL) { send({ event: 'fatal', error: 'model file is corrupt' }); process.exit(1); }
setTimeout(() => send({ event: 'ready' }), Number(process.env.FAKE_READY_DELAY_MS || 10));

let busy = false;
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const request = JSON.parse(line);
  if (request.op === 'shutdown') { send({ id: request.id, ok: true, result: {} }); process.exit(0); }
  if (request.op === 'ping') { if (request.hang) return; send({ id: request.id, ok: true, result: { pong: true } }); return; }
  if (request.language === 'hang') return;
  if (request.language === 'crash') process.exit(3);
  if (busy) { send({ id: request.id, ok: false, error: 'overlapping requests' }); return; }
  busy = true;
  setTimeout(() => {
    busy = false;
    send({ id: request.id, ok: true, result: { text: 'hello world.', language: 'en', words: [
      { word: 'hello', start: 0, end: 0.4, probability: 0.9 }, { word: 'world.', start: 0.4, end: 0.8, probability: 0.8 }] } });
  }, 25);
});
process.stdin.on('end', () => process.exit(0));
