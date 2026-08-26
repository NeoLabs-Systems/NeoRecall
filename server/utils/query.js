'use strict';

// Reads a boolean the way a query string carries one: absent, "1"/"true", or a
// real boolean from a JSON body. Written out by hand at every filter that
// needed it, with the same three-way comparison each time.
function queryBoolean(value) {
  return value === true || value === '1' || value === 'true';
}

// Collects `WHERE` fragments and their bound parameters together, so a filter
// is one line instead of a push into two parallel arrays that must stay in step.
class Conditions {
  constructor(...initial) {
    this.clauses = [];
    this.parameters = [];
    for (const clause of initial) this.clauses.push(clause);
  }

  // Adds `clause` only when `value` is set, binding whatever `parameters` it needs.
  when(value, clause, ...parameters) {
    if (value === undefined || value === null || value === '') return this;
    this.clauses.push(clause);
    this.parameters.push(...parameters);
    return this;
  }

  // Adds `clause` unconditionally.
  always(clause, ...parameters) {
    this.clauses.push(clause);
    this.parameters.push(...parameters);
    return this;
  }

  get sql() { return this.clauses.join(' AND '); }
}

module.exports = { queryBoolean, Conditions };
