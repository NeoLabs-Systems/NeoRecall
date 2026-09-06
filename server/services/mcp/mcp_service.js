'use strict';

const search = require('../search/search_service');
const memories = require('../memories/memory_service');
const conversations = require('../conversations/conversation_service');
const { HttpError } = require('../../middleware/error_handler');

const PROTOCOL_VERSION = '2025-03-26';
const SERVER_INFO = Object.freeze({
  name: 'neorecall',
  version: require('../../../package.json').version,
});

const TOOLS = Object.freeze([
  {
    name: 'search',
    description: 'Hybrid keyword and semantic search over memories and transcript evidence. Does not invoke NeoRecall Ask.',
    scope: 'search:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['query'],
      properties: {
        query: { type: 'string', minLength: 1 },
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        kinds: { type: 'array', items: { type: 'string' } },
      },
    },
    run: (userId, args) => search.search(userId, String(args.query || '').trim(), {
      limit: args.limit, kinds: Array.isArray(args.kinds) ? args.kinds.map(String) : [],
    }),
  },
  {
    name: 'list_memories',
    description: 'List episodic memories for this account.',
    scope: 'memories:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        q: { type: 'string' },
        from: { type: 'string' },
        to: { type: 'string' },
        type: { type: 'string' },
      },
    },
    run: (userId, args) => memories.list(userId, args),
  },
  {
    name: 'get_memory',
    description: 'Read one memory, including mini-memories, entities, and transcript sources. Audio is never included.',
    scope: 'memories:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['id'],
      properties: { id: { type: 'string', minLength: 1 } },
    },
    run: (userId, args) => memories.memoryDetail(userId, String(args.id || '').trim()),
  },
  {
    name: 'list_mini_memories',
    description: 'List atomic mini-memories.',
    scope: 'memories:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        q: { type: 'string' },
        memoryId: { type: 'string' },
        kind: { type: 'string' },
        status: { type: 'string' },
      },
    },
    run: (userId, args) => memories.listMini(userId, args),
  },
  {
    name: 'list_daily_summaries',
    description: 'List incremental daily summaries.',
    scope: 'memories:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        from: { type: 'string' },
        to: { type: 'string' },
      },
    },
    run: (userId, args) => memories.dailySummaries(userId, args),
  },
  {
    name: 'list_conversations',
    description: 'List conversations (moments) with titles and summaries. Does not include full transcripts.',
    scope: 'recordings:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        state: { type: 'string' },
        from: { type: 'string' },
        to: { type: 'string' },
      },
    },
    run: (userId, args) => conversations.list(userId, args),
  },
  {
    name: 'get_conversation',
    description: 'Read one conversation and its transcript segments. Audio is never available.',
    scope: 'recordings:read',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['id'],
      properties: { id: { type: 'string', minLength: 1 } },
    },
    run: (userId, args) => conversations.get(userId, String(args.id || '').trim()),
  },
]);

function initialize() {
  return {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: { tools: {} },
    serverInfo: SERVER_INFO,
  };
}

function listTools() {
  return {
    tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
  };
}

function requireScope(auth, scope) {
  if (auth?.scopes?.includes('*') || auth?.scopes?.includes(scope)) return;
  throw new HttpError(403, 'INSUFFICIENT_SCOPE', `The ${scope} scope is required.`);
}

function requiredString(args, key) {
  const value = String(args?.[key] || '').trim();
  if (!value) throw new HttpError(400, 'INVALID_PARAMS', `${key} is required.`);
  return value;
}

async function callTool(auth, name, args = {}) {
  const tool = TOOLS.find((entry) => entry.name === name);
  if (!tool) throw new HttpError(404, 'UNKNOWN_TOOL', `Unknown tool: ${name}`);
  requireScope(auth, tool.scope);
  if (tool.inputSchema.required) {
    for (const key of tool.inputSchema.required) requiredString(args, key);
  }
  return tool.run(auth.userId, args && typeof args === 'object' ? args : {});
}

module.exports = { PROTOCOL_VERSION, TOOLS, initialize, listTools, callTool };
