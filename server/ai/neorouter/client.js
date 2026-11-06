'use strict';

const { getConfig } = require('../../config');

// Calls to a NeoRouter's OpenAI-style API with the stored connection.
async function call(connection, path, { method = 'GET', body, headers: extra = {}, timeoutMs = getConfig().neorouterRequestTimeoutMs } = {}) {
  let response;
  try {
    response = await fetch(`${connection.apiBase}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${connection.apiKey}`,
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...extra,
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (cause) {
    throw Object.assign(new Error(`Could not reach NeoRouter at ${connection.origin}.`), { code: 'NEOROUTER_UNREACHABLE', cause });
  }
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw Object.assign(new Error(`NeoRouter: ${data?.error?.message || `HTTP ${response.status}`}`), {
      code: response.status === 401 || response.status === 403 ? 'NEOROUTER_KEY_REJECTED' : 'NEOROUTER_HTTP_ERROR',
      status: response.status,
    });
  }
  return { data, headers: response.headers };
}

// The models of one kind the key may use, and how many more the router has
// that the key's free/plan/paid choice leaves out.
async function modelList(connection, type) {
  const { data } = await call(connection, `/models?type=${encodeURIComponent(type)}`);
  return { models: Array.isArray(data?.data) ? data.data : [], notAllowed: data?.neorouter?.not_allowed_for_key || {} };
}

// Unit-length vectors of exactly `dimensions`, as the search index needs. The
// router pins an `auto` key to one model and size on first use, so asking for
// the same size every time keeps every vector comparable; the pin header names
// the model, the body only the host that happened to serve this request.
async function embed(connection, text, { inputType, dimensions }) {
  const { data, headers } = await call(connection, '/embeddings', {
    method: 'POST',
    body: { model: 'auto', input: text, dimensions, input_type: inputType === 'passage' ? 'document' : 'query' },
  });
  const vector = data?.data?.[0]?.embedding;
  if (!Array.isArray(vector) || vector.length !== dimensions) {
    throw Object.assign(new Error(`NeoRouter returned ${Array.isArray(vector) ? vector.length : 'no'} embedding dimensions; ${dimensions} are required.`), { code: 'NEOROUTER_BAD_EMBEDDING' });
  }
  const norm = Math.hypot(...vector) || 1;
  const space = String(headers.get('x-neorouter-embedding-pin') || '').trim();
  return { vector: Float32Array.from(vector, (value) => value / norm), space: space || String(data.model || 'auto') };
}

module.exports = { call, embed, modelList };
