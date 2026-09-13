'use strict';

const { appendSystem } = require('./system_messages');

// Language of model-written prose only. Transcripts and retrieval stay multilingual.
const LANGUAGES = Object.freeze({
  en: Object.freeze({ code: 'en', name: 'English', endonym: 'English' }),
  de: Object.freeze({ code: 'de', name: 'German', endonym: 'Deutsch' }),
});

const DEFAULT_LANGUAGE = 'en';

/** Every supported code, in the order a picker should offer them. */
const LANGUAGE_CODES = Object.freeze(Object.keys(LANGUAGES));

function resolveLanguage(code) {
  return LANGUAGES[String(code || '').toLowerCase()] || LANGUAGES[DEFAULT_LANGUAGE];
}

function languageDirective(language) {
  return [
    `Write every human-readable field of your output in ${language.name} (${language.endonym}).`,
    'This applies to titles, summaries, descriptions, topics, canonical names and any prose you write, whatever language the supplied material is in.',
    'It does not apply to the material itself: never translate a quoted transcript, and preserve proper names, product names and identifiers exactly as they appear.',
    'It never changes the output format, the field names, or the schema you must match.',
    'Field names ending in "En" — titleEn, summaryEn, textEn, canonicalNameEn, descriptionEn — are fixed identifiers from an earlier version of this contract and no longer mean English: fill them in the output language named above.',
  ].join(' ');
}

function withOutputLanguage(messages, code) {
  return appendSystem(messages, languageDirective(resolveLanguage(code)));
}

module.exports = { LANGUAGES, LANGUAGE_CODES, DEFAULT_LANGUAGE, resolveLanguage, languageDirective, withOutputLanguage };
