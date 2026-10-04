#!/usr/bin/env node
'use strict';

// Stands in for llama.cpp's `llama-server`: the same flags, /health and
// chat-completions endpoint, scripted behaviour. GET /_args reports how it was
// started; POST /_stop-answering makes /health fail from then on (a wedged server).
const http = require('node:http');

const args = process.argv.slice(2);
const option = (name) => { const index = args.indexOf(name); return index < 0 ? null : args[index + 1]; };
const port = Number(option('--port'));
const key = option('--api-key');
const startedAt = Date.now();
let answering = true;

http.createServer((request, response) => {
  const send = (status, body) => { response.statusCode = status; response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(body)); };
  if (request.url === '/_args') return send(200, { args });
  if (request.url === '/_stop-answering') { answering = false; return send(200, {}); }
  if (request.url === '/health') {
    if (!answering) return request.socket.destroy();
    return Date.now() - startedAt < 250 ? send(503, { error: { message: 'Loading model' } }) : send(200, { status: 'ok' });
  }
  if (request.url === '/v1/chat/completions' && request.method === 'POST') {
    if (request.headers.authorization !== `Bearer ${key}`) return send(401, { error: { message: 'Invalid API key' } });
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    return request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      return send(200, {
        id: 'chatcmpl-fake',
        choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify({ answer: 'ready', received: body }) } }],
        usage: { prompt_tokens: 12, completion_tokens: 3 },
      });
    });
  }
  return send(404, {});
}).listen(port, '127.0.0.1');
