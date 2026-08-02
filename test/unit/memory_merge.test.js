'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { deterministicMergeProse } = require('../../server/services/memories/memory_service');
const { memoryMergeSchema, memoryMergeJsonSchema } = require('../../server/ai/schemas/memory_merge_schema');

test('deterministic merge prose joins titles and summaries without inventing facts', () => {
  const prose = deterministicMergeProse([
    {
      type: 'meeting',
      title_en: 'Standup',
      summary_en: 'Covered blockers.',
      emoji: '🤝',
    },
    {
      type: 'meeting',
      title_en: 'Planning',
      summary_en: 'Agreed on the launch date.',
      emoji: null,
    },
  ]);
  assert.equal(prose.type, 'meeting');
  assert.match(prose.titleEn, /Standup/);
  assert.match(prose.titleEn, /Planning/);
  assert.match(prose.summaryEn, /blockers/);
  assert.match(prose.summaryEn, /launch date/);
  assert.equal(prose.emoji, '🤝');
});

test('memory merge schema accepts a rewritten card', () => {
  const parsed = memoryMergeSchema.parse({
    type: 'project_discussion',
    titleEn: 'Launch planning',
    summaryEn: 'The team aligned on blockers and a launch date.',
    emoji: '🚀',
  });
  assert.equal(parsed.emoji, '🚀');
  assert.deepEqual(memoryMergeJsonSchema.required, ['type', 'titleEn', 'summaryEn', 'emoji']);
});
