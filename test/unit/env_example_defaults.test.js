'use strict';

// `.env.example` is the file an operator reads to find out what a knob does and
// what it is set to if they leave it alone. Two of its values had drifted from
// the code — a speaker-preview floor that moved from 5s to 1s, and a
// consolidation ceiling documented as 1 when the code says 12 — because a
// default can be changed in config.js without anything noticing.
//
// This compares the two directly, so the next such change fails here instead of
// misleading someone setting up a server.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.join(__dirname, '..', '..');
const example = fs.readFileSync(path.join(repoRoot, '.env.example'), 'utf8');
const configSource = fs.readFileSync(path.join(repoRoot, 'server', 'config.js'), 'utf8');

// Values whose default is an expression rather than a literal, and why the
// documented value is still the right thing for an operator to read.
const CONDITIONAL_DEFAULTS = new Set([
  // `NODE_ENV === 'production'`: .env.example describes a production install.
  'NEORECALL_REQUIRE_VECTOR',
]);

function documentedDefaults() {
  const entries = new Map();
  for (const line of example.split('\n')) {
    const match = line.match(/^# ([A-Z][A-Z0-9_]+)=(.+)$/);
    if (match) entries.set(match[1], match[2].trim());
  }
  return entries;
}

// config.js writes defaults as literals (`0.5`, `true`) or as arithmetic that
// shows the unit — `30 * 24 * 60 * 60 * 1000` reads as "thirty days" in a way
// `2592000000` does not. Both are compared; anything else is a computed
// default and has to be listed above with its reason.
const ARITHMETIC = /^[\d_\s*+\-/.()]+$/;

function codeDefault(name) {
  const match = configSource.match(new RegExp(`(?:integer|number|boolean)\\('${name}',\\s*([^,)]+)`));
  if (!match) return null;
  const literal = match[1].trim();
  if (literal === 'true' || literal === 'false') return { value: literal };
  if (!ARITHMETIC.test(literal)) return { conditional: true };
  return { value: String(Function(`return (${literal.replace(/_/g, '')})`)()) };
}

test('.env.example documents the defaults config.js actually uses', () => {
  const mismatched = [];
  let compared = 0;
  for (const [name, documented] of documentedDefaults()) {
    const actual = codeDefault(name);
    if (!actual) continue;
    if (actual.conditional) {
      assert.ok(
        CONDITIONAL_DEFAULTS.has(name),
        `${name} has a computed default in config.js; document why and list it in CONDITIONAL_DEFAULTS.`,
      );
      continue;
    }
    compared += 1;
    // Compare numerically so 0.50 and 0.5 agree; booleans compare as text.
    const same = Number.isNaN(Number(actual.value))
      ? actual.value === documented
      : Number(actual.value) === Number(documented);
    if (!same) mismatched.push(`${name}: .env.example says ${documented}, config.js says ${actual.value}`);
  }
  assert.ok(compared > 100, `expected to compare most of the configuration, compared ${compared}`);
  assert.deepEqual(mismatched, [], `\n${mismatched.join('\n')}\n`);
});

test('every configurable value in config.js appears in .env.example', () => {
  const documented = new Set(documentedDefaults().keys());
  // Names that are read but carry no default worth publishing, e.g. secrets.
  for (const line of example.split('\n')) {
    const blank = line.match(/^# ([A-Z][A-Z0-9_]+)=$/);
    if (blank) documented.add(blank[1]);
  }
  const undocumented = [...configSource.matchAll(/(?:integer|number|boolean|enumeration|jsonObject)\('([A-Z][A-Z0-9_]+)'/g)]
    .map((match) => match[1])
    .filter((name) => !documented.has(name));
  assert.deepEqual([...new Set(undocumented)], [], 'these are configurable but absent from .env.example');
});
