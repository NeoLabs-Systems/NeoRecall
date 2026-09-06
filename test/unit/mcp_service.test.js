'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const mcp = require('../../server/services/mcp/mcp_service');

test('MCP exposes the seven read-only tools and never Ask', () => {
  const names = mcp.listTools().tools.map((tool) => tool.name);
  assert.deepEqual(names, [
    'search', 'list_memories', 'get_memory', 'list_mini_memories',
    'list_daily_summaries', 'list_conversations', 'get_conversation',
  ]);
  assert.equal(mcp.TOOLS.every((tool) => ['search:read', 'memories:read', 'recordings:read'].includes(tool.scope)), true);
  assert.equal(mcp.initialize().protocolVersion, '2025-03-26');
});
