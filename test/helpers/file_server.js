'use strict';

const http = require('node:http');

// A real HTTP server on loopback serving fixed bodies, with the behaviours a
// download has to survive: range requests, a connection dropped part-way, a
// connection that goes silent, and a hard failure status. `routes` maps a path to
// { body, ... }; `hits` records every request made so tests can assert how many.
async function fileServer(routes) {
  const hits = [];
  const server = http.createServer((request, response) => {
    const route = routes[request.url];
    hits.push({ url: request.url, range: request.headers.range || null });
    if (!route) { response.statusCode = 404; response.end(); return; }
    if (route.status) { response.statusCode = route.status; response.end(); return; }
    const body = route.body;
    const match = /^bytes=(\d+)-$/.exec(request.headers.range || '');
    const start = match ? Number(match[1]) : 0;
    const ignoreRange = route.ignoreRange && match;
    const from = ignoreRange ? 0 : start;
    response.statusCode = match && !ignoreRange ? 206 : 200;
    if (match && !ignoreRange) response.setHeader('Content-Range', `bytes ${start}-${body.length - 1}/${body.length}`);
    response.setHeader('Content-Length', body.length - from);
    // `dropAfter`: send this many bytes then cut the connection, once.
    if (route.dropAfter && !route.dropped) {
      route.dropped = true;
      response.write(body.subarray(from, from + route.dropAfter));
      setTimeout(() => response.destroy(), 20);
      return;
    }
    // `stallAfter`: send this many bytes then say nothing, once.
    if (route.stallAfter && !route.stalled) {
      route.stalled = true;
      response.write(body.subarray(from, from + route.stallAfter));
      return;
    }
    response.end(body.subarray(from));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: (path) => `http://127.0.0.1:${server.address().port}${path}`,
    hits,
    close: () => { server.closeAllConnections?.(); return new Promise((resolve) => server.close(resolve)); },
  };
}

module.exports = { fileServer };
