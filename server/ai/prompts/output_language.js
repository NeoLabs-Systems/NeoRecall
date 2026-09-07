'use strict';

// The language the product writes back in.
//
// Transcription and retrieval stay multilingual whatever this says: a German
// conversation is transcribed as German speech and searched as German text.
// This is only about the language of what the model *writes* — titles,
// summaries, the day's description, an answer in Ask — which until now was
// English for everyone because every prompt said so in its own words.
//
// Saying it in one place instead means the prompts no longer name a language at
// all; they describe their fields as being "in the output language" and this
// module supplies which one. Adding a third language is then a row here and a
// row in the client's catalogue, not an edit to nine prompts.
//
// The endonym is carried alongside the English name because a model asked to
// write German follows "German (Deutsch)" more reliably than either name on its
// own, and because it is what the client shows in its own picker.

const LANGUAGES = Object.freeze({
  en: Object.freeze({ code: 'en', name: 'English', endonym: 'English' }),
  de: Object.freeze({ code: 'de', name: 'German', endonym: 'Deutsch' }),
});

const DEFAULT_LANGUAGE = 'en';

/** Every supported code, in the order a picker should offer them. */
const LANGUAGE_CODES = Object.freeze(Object.keys(LANGUAGES));

/**
 * The language record for a stored setting.
 *
 * Anything unrecognised falls back to the default rather than throwing: this is
 * read on the path of every AI request, and an account that somehow holds a
 * code this build does not know should still get its memories written.
 */
function resolveLanguage(code) {
  return LANGUAGES[String(code || '').toLowerCase()] || LANGUAGES[DEFAULT_LANGUAGE];
}

/**
 * The instruction that fixes the language of everything human-readable.
 *
 * It has to be explicit that this is not translation of the evidence: the
 * transcript stays whatever was spoken, proper names stay spelled as they are,
 * and only the model's own prose moves. Without that, a German setting over an
 * English meeting came back with the participants' names Germanised.
 */
function languageDirective(language) {
  return [
    `Write every human-readable field of your output in ${language.name} (${language.endonym}).`,
    'This applies to titles, summaries, descriptions, topics, canonical names and any prose you write, whatever language the supplied material is in.',
    'It does not apply to the material itself: never translate a quoted transcript, and preserve proper names, product names and identifiers exactly as they appear.',
    'It never changes the output format, the field names, or the schema you must match.',
    'Field names ending in "En" — titleEn, summaryEn, textEn, canonicalNameEn, descriptionEn — are fixed identifiers from an earlier version of this contract and no longer mean English: fill them in the output language named above.',
  ].join(' ');
}

/**
 * Inserts the language directive into a built message list.
 *
 * Placed after the task's own system messages and before the owner's standing
 * instructions, so an instruction that says something more specific about
 * language is read last and wins.
 */
function withOutputLanguage(messages, code) {
  const language = resolveLanguage(code);
  const leadingSystem = messages.findIndex((message) => message.role !== 'system');
  const cut = leadingSystem === -1 ? messages.length : leadingSystem;
  return [
    ...messages.slice(0, cut),
    { role: 'system', content: languageDirective(language) },
    ...messages.slice(cut),
  ];
}

module.exports = { LANGUAGES, LANGUAGE_CODES, DEFAULT_LANGUAGE, resolveLanguage, languageDirective, withOutputLanguage };
