'use strict';

const { compactInput } = require('./consolidate_memories');
const { TITLE_GUIDANCE } = require('./title_guidance');

// The live counterpart to consolidation. A device may record for a whole day, so
// the user has to be able to look into a conversation that has not ended yet.
// This asks for the same insight consolidation would produce for a finished
// conversation — title, summary, topics, memory-worthiness — over the transcript
// captured so far. It deliberately produces no memories and no evidence
// references: the conversation is still growing, and anchoring durable memories
// to a moving transcript would create duplicates the final pass has to undo.
//
// A preview comes in two shapes. A conversation small enough to re-read is sent
// whole, which is exact. Past that size the caller sends the previous summary
// plus only the speech recorded since, so refreshing a conversation that never
// ends costs the same every time instead of re-paying for its whole history.

const FULL_INSTRUCTIONS = `You describe a conversation that is still being recorded. Return one JSON object matching the supplied contract.
The transcript is a prefix: recording continues and later speech may change what the conversation turns out to be. Describe only what the supplied transcript supports, never speculate about how it will continue, and never state that the transcript is incomplete.`;

const CONTINUATION_INSTRUCTIONS = `You maintain the description of a conversation that is still being recorded. Return one JSON object matching the supplied contract.
You are given the description written earlier and only the speech recorded since. Produce the description of the conversation as a whole: carry forward everything from the earlier summary that still holds, and fold in what the new speech adds or corrects. Never describe only the new part, never refer to an earlier summary or to earlier updates, and never state that the transcript is partial or continuing.
Revise the title when the new speech or user-supplied context shows the conversation is really about something else; otherwise keep it stable so it does not change under the reader on every update.`;

const SHARED_INSTRUCTIONS = `titleEn, summaryEn and topics MUST be in the output language even when the transcript is in another language. Preserve proper names accurately.
The title is a concise specific name for this conversation, the kind a person would use to find it again.
${TITLE_GUIDANCE}
The summary is a faithful standalone account of what has been said so far. Do not invent facts, decisions or participants.
User-supplied contextItems are evidence captured during the conversation. Use ready notes and analyzed files to clarify names, facts and emphasis, while never presenting a document's plans as spoken decisions or completed events. A highlight adds emphasis but no new facts.
Set memoryWorthy true only when the transcript so far is clearly becoming a substantial occasion a person would open later as its own memory card (a meeting, lesson, multi-turn discussion, decision session, or similar). Set it false for brief exchanges, hellos, logistics, ambient chatter, or anything whose whole value is a single small fact — those are not full memories. An accurate title and summary are required either way.
Return no prose outside JSON.`;

function conversationPreviewMessages({ conversation, previousInsight = null, timezone }) {
  const references = compactInput([conversation], timezone);
  const [compact] = references.compactConversations;
  const continuation = Boolean(previousInsight);
  return [
    {
      role: 'system',
      content: `${continuation ? CONTINUATION_INSTRUCTIONS : FULL_INSTRUCTIONS}\n${SHARED_INSTRUCTIONS}`,
    },
    {
      role: 'user',
      content: JSON.stringify({
        timezone,
        ...(continuation ? {
          describedSoFar: {
            titleEn: previousInsight.titleEn,
            summaryEn: previousInsight.summaryEn,
            topics: previousInsight.topics,
          },
        } : {}),
        conversation: {
          ...compact,
          // Segment identifiers only exist so consolidation can address evidence.
          // A preview cites nothing, so dropping them keeps a long conversation's
          // repeated previews from paying for identifiers no one reads.
          segments: compact.segments.map(({ id, ...segment }) => segment),
        },
        outputContract: {
          titleEn: 'Concise specific title, in the output language',
          summaryEn: continuation
            ? 'Faithful summary of the whole conversation, earlier description included, in the output language'
            : 'Faithful summary of the transcript so far, in the output language',
          memoryWorthy: true,
          topics: ['topic, in the output language'],
        },
      }),
    },
  ];
}

module.exports = { conversationPreviewMessages };
