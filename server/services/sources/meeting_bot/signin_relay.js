'use strict';

// Attaches the live account sign-in relay to the HTTP server.
//
// This is the piece that makes the sign-in "isolated and directly from the
// browser": the WebSocket carries screen frames one way and input events the
// other, so the user is looking at and typing into the isolated per-account
// browser session through their own device's browser the entire time — the
// server never displays anything on its own screen and the user never needs
// access to the machine NeoRecall runs on. See signin_session.js for the
// browser side and signin_tickets.js for how the connection is authorized.
//
// A plain http.Server `upgrade` listener is used instead of an Express
// middleware because WebSocket upgrades happen outside the normal
// request/response cycle Express models; this only intercepts the one path it
// owns and lets every other upgrade request fall through untouched.

const RELAY_PATH = '/api/v1/sources/meeting/account/live';

function launcher() {
  try {
    return { ws: require('ws') };
  } catch (error) {
    return null;
  }
}

function send(socket, message) {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
}

function attach(httpServer) {
  const loaded = launcher();
  if (!loaded) {
    console.error('[MeetingAccount] The "ws" package is unavailable; live sign-in will not work.');
    return;
  }
  const { WebSocketServer } = loaded.ws;
  const wss = new WebSocketServer({ noServer: true });
  const tickets = require('./signin_tickets');
  const { registry } = require('./signin_session');
  const accountMetadata = require('./account_metadata');

  httpServer.on('upgrade', (request, socket, head) => {
    let url;
    try {
      url = new URL(request.url, 'http://internal');
    } catch (error) {
      socket.destroy();
      return;
    }
    if (url.pathname !== RELAY_PATH) return; // not ours — leave it for anyone else listening

    const ticket = url.searchParams.get('ticket') || '';
    const redeemed = tickets.redeem(ticket);
    if (!redeemed) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
      handleConnection(ws, redeemed, { registry, accountMetadata }).catch((error) => {
        console.error('[MeetingAccount] Live sign-in session failed:', error.message);
        send(ws, { type: 'error', message: 'Something went wrong starting the sign-in session.' });
        ws.close();
      });
    });
  });
}

async function handleConnection(ws, { userId, providerId }, { registry, accountMetadata }) {
  const provider = accountMetadata.requireProvider(providerId);

  let session;
  try {
    session = await registry.begin(userId, provider);
  } catch (error) {
    send(ws, { type: 'error', message: error.message });
    ws.close();
    return;
  }

  const onFrame = ({ data }) => send(ws, { type: 'frame', data });
  const onLog = (message) => send(ws, { type: 'log', message });
  session.on('frame', onFrame);
  session.on('log', onLog);

  let finished = false;
  const finishAndReport = async (message) => {
    if (finished) return;
    finished = true;
    const status = await registry.end(userId);
    send(ws, { type: 'result', status, message });
    ws.close();
  };
  // A session left idle too long ends on its own; tell the client why instead
  // of just going silent.
  session.once('timeout', () => {
    finishAndReport("This didn't finish in time, so the session was closed. Try connecting again.")
      .catch((error) => console.error('[MeetingAccount] Timeout cleanup failed:', error.message));
  });

  ws.on('message', (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch (error) {
      return; // malformed frame from a misbehaving client — ignore, not fatal
    }
    if (message && message.type === 'input') {
      session.handleInput(message).catch(() => {});
    } else if (message && message.type === 'finish') {
      finishAndReport().catch((error) => console.error('[MeetingAccount] Finish failed:', error.message));
    }
  });

  // A dropped connection (closed tab, lost network) must still flush the
  // session — the user may already have finished signing in and the cookies
  // deserve to be saved even though nobody clicked "Done".
  ws.on('close', () => {
    session.off('frame', onFrame);
    session.off('log', onLog);
    finishAndReport().catch((error) => console.error('[MeetingAccount] Cleanup after disconnect failed:', error.message));
  });
}

module.exports = { attach, RELAY_PATH };
