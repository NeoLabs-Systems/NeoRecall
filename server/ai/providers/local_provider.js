'use strict';

const openai = require('./openai_compatible_provider');
const localLlm = require('../local_llm');
const { notReadyReason } = require('../../local_runtime/not_ready_reason');

// Gemma has no system role: its chat template rejects one, so a request that
// carries a system message would fail on the server. The instructions are the
// same either way; this moves them to the front of the first user message.
// Images are not part of this model, so a message's content stays text.
function foldSystemIntoUser(messages) {
  const system = messages.filter((message) => message.role === 'system').map((message) => message.content).join('\n\n');
  const rest = messages.filter((message) => message.role !== 'system');
  if (!system) return rest;
  const index = rest.findIndex((message) => message.role === 'user');
  if (index < 0) return [{ role: 'user', content: system }, ...rest];
  const first = rest[index];
  const folded = typeof first.content === 'string'
    ? `${system}\n\n${first.content}`
    : [{ type: 'text', text: system }, ...first.content];
  return rest.map((message, position) => (position === index ? { ...first, content: folded } : message));
}

// Generation by the local model. The wire protocol, retries, schema fallbacks and
// bookkeeping are the OpenAI-compatible provider's, unchanged — the local server
// speaks that protocol on loopback and the settings resolve its address and key —
// so this adds only what is particular to running here: waiting for the server to
// be up (it may be loading, or waking from idle) and the system-role fold.
function ready() {
  const installer = localLlm.getInstaller();
  return installer.supported && installer.isInstalled();
}

async function chatJSON(request) {
  await localLlm.ensureServing();
  return openai.chatJSON({ ...request, messages: foldSystemIntoUser(request.messages) });
}

// Said to an operator when `ready()` is false.
function describeNotReady() {
  return notReadyReason(localLlm.getInstaller().status()) || 'The local language model is not available.';
}

module.exports = { chatJSON, ready, foldSystemIntoUser, describeNotReady };
