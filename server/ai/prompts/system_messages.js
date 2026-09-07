'use strict';

// One system message, always, and always first.
//
// Several chat templates in local-model runtimes enforce that: Qwen's raises
// "System message must be at the beginning" and returns HTTP 500 for a request
// carrying a second system turn, whatever its position. Measured against a live
// Qwen3.5-4B, every Ask failed this way the moment a second system message was
// added — so anything this layer wants to say to the model has to be folded
// into the one the task already wrote, not appended beside it.
//
// Folding also keeps the message list the shape callers expect: the evidence
// stays the turn right after the system message, however many preferences were
// layered on top of it.

/**
 * Appends `content` to the leading system message, creating one if there is none.
 *
 * Later calls append after earlier ones, so a caller that adds the output
 * language before the owner's standing instructions still has the instructions
 * read last.
 */
function appendSystem(messages, content) {
  const text = String(content || '').trim();
  if (!text) return messages;
  const firstOther = messages.findIndex((message) => message.role !== 'system');
  const systemCount = firstOther === -1 ? messages.length : firstOther;
  if (systemCount === 0) return [{ role: 'system', content: text }, ...messages];
  // Any leading system messages collapse together, so a prompt that wrote two
  // of its own cannot reintroduce the failure this module exists to prevent.
  const merged = messages.slice(0, systemCount)
    .map((message) => String(message.content || '').trim())
    .filter(Boolean)
    .concat(text)
    .join('\n\n');
  return [{ role: 'system', content: merged }, ...messages.slice(systemCount)];
}

module.exports = { appendSystem };
