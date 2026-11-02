'use strict';

const ui = require('./ui');

function printWordmark(tagline) {
  ui.blank();
  ui.print(`  ${ui.paint.command('NeoRecall')}  ${ui.paint.faint(tagline)}`);
}

// The first few problems in a column; the rest are one status away.
const PROBLEMS_SHOWN = 3;

function printProblems(problems) {
  const shown = problems.slice(0, PROBLEMS_SHOWN);
  const width = Math.max(0, ...shown.map((problem) => ui.visibleLength(problem.label))) + 2;
  for (const problem of shown) ui.item(problem.tone, problem.label, problem.detail, width);
  if (problems.length > shown.length) {
    ui.print(`    ${ui.paint.faint(`and ${problems.length - shown.length} more —`)} ${ui.paint.command('neorecall status')}`);
  }
}

// The wordmark, one line of state with the address, then only the checks
// that need attention: the menu below covers everything else.
function printHomeHeader(facts, problems) {
  printWordmark('your day, remembered privately');
  ui.blank();
  if (facts.running) ui.item('ok', ui.paint.bold('Running'), ui.paint.accent(facts.url));
  else ui.item('error', ui.paint.bold("Not running"), `${ui.paint.faint('run')} ${ui.paint.command('neorecall start')}`);
  printProblems(problems);
}

// The last install screen: where NeoRecall is, and anything left to do.
function printInstallFinished({ url, startsItself, notes }) {
  printWordmark(startsItself ? 'starts by itself with your computer' : 'is running');
  ui.blank();
  ui.item('ok', ui.paint.bold("You're all set"));
  ui.print(`    Open ${ui.paint.accent(url)} ${ui.paint.muted('and create your account.')}`);
  ui.print(`    ${ui.paint.muted('The first account becomes the admin.')}`);
  if (notes.length > 0) {
    ui.blank();
    for (const text of notes) ui.item('info', text);
  }
  ui.blank();
}

module.exports = {
  printHomeHeader,
  printInstallFinished,
};
