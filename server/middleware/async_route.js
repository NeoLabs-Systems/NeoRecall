'use strict';

// Forwards a handler's rejection to the error middleware.
//
// Express 4 catches a synchronous throw but not a rejected promise, so an async
// handler without this leaves the request hanging until the client gives up.
function asyncRoute(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

module.exports = { asyncRoute };
