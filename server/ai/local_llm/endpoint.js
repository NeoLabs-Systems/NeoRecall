'use strict';

const crypto = require('node:crypto');
const { masterKey } = require('../../utils/crypto');

// Where the local language model listens and how to authenticate to it.
//
// Both server processes talk to one model server, so they have to agree on the
// key without it being stored anywhere or passed between them. It is derived from
// the installation secret, which both already hold.
function baseUrl(config) {
  return `http://127.0.0.1:${config.localLlmPort}/v1`;
}

function apiKey() {
  return crypto.createHmac('sha256', masterKey()).update('neorecall:local-llm').digest('base64url');
}

module.exports = { baseUrl, apiKey };
