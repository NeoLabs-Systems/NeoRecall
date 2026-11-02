'use strict';

const ui = require('./ui');

const LABEL_WIDTH = 24;

// Plain-language health checks from the facts `neorecall status` gathers.
// Each check is { id?, tone, label, detail, fix?, advice? }: fix is a command
// to run, advice a sentence when no command fixes it.
function statusChecks(facts) {
  const checks = [];
  checks.push(facts.running
    ? { id: 'server', tone: 'ok', label: 'NeoRecall', detail: `Running at ${facts.url}` }
    : { id: 'server', tone: 'error', label: 'NeoRecall', detail: 'Not running', fix: 'neorecall start' });

  if (facts.runningVersion && facts.runningVersion !== facts.version) {
    checks.push({
      tone: 'warn',
      label: 'Restart needed',
      detail: `${facts.version} is installed, but ${facts.runningVersion} is still running`,
      fix: 'neorecall restart',
    });
  }

  // What the running server says about its own work (/ready).
  if (facts.ready) {
    checks.push(facts.ready.worker
      ? { tone: 'ok', label: 'Recordings', detail: 'Being processed as they arrive' }
      : { tone: 'warn', label: 'Recordings', detail: 'The processing worker is not running', fix: 'neorecall restart' });
    checks.push(facts.ready.models
      ? { tone: 'ok', label: 'Transcription', detail: 'Ready' }
      : { tone: 'warn', label: 'Transcription', detail: 'The speech model is not ready', fix: 'neorecall setup' });
    checks.push(facts.ready.languageModel
      ? { tone: 'ok', label: 'Memories', detail: 'An AI is set up to write them' }
      : { tone: 'warn', label: 'Memories', detail: 'No AI is set up to write them', advice: 'Choose one in the app under Admin › AI providers.' });
    checks.push(facts.ready.vector
      ? { tone: 'ok', label: 'Search', detail: 'Ready' }
      : { tone: 'warn', label: 'Search', detail: 'The search index is not ready', fix: 'neorecall repair' });
  } else {
    checks.push(facts.modelsPresent
      ? { tone: 'ok', label: 'Speech and search models', detail: 'Downloaded' }
      : { tone: 'warn', label: 'Speech and search models', detail: 'Not downloaded yet', fix: 'neorecall setup' });
  }

  checks.push(facts.serviceActive
    ? { tone: 'ok', label: 'Starts automatically', detail: 'Turns on when your computer does' }
    : { tone: 'warn', label: 'Starts automatically', detail: 'Not set up on this computer', fix: 'neorecall install' });

  checks.push(facts.configPresent
    ? { tone: 'ok', label: 'Settings', detail: 'Saved' }
    : { tone: 'error', label: 'Settings', detail: 'Not set up yet', fix: 'neorecall setup' });

  checks.push(facts.webClientPresent
    ? { tone: 'ok', label: 'App in your browser', detail: 'Installed' }
    : { tone: 'error', label: 'App in your browser', detail: 'Missing', fix: 'neorecall rebuild-web' });

  if (facts.admins?.error) {
    checks.push({ tone: 'warn', label: 'Accounts', detail: `Couldn't read them: ${facts.admins.error}`, fix: 'neorecall doctor' });
  } else if (facts.admins) {
    checks.push(facts.admins.missing
      ? { tone: 'warn', label: 'Admin account', detail: 'No account is an admin', fix: 'neorecall admin grant <username>' }
      : {
        tone: 'ok',
        label: 'Accounts',
        detail: facts.admins.names.length > 0
          ? `Admin: ${facts.admins.names.join(', ')}`
          : 'The first account you create becomes the admin',
      });
  }

  checks.push(facts.update
    ? {
      id: 'version',
      tone: 'warn',
      label: `Version ${facts.version}`,
      detail: `A newer version${facts.update.version ? ` (${facts.update.version})` : ''} is ready`,
      fix: 'neorecall update',
    }
    : { id: 'version', tone: 'ok', label: `Version ${facts.version}`, detail: facts.updateChecked ? 'Up to date' : '' });
  return checks;
}

function needsAttention(check) {
  return check.tone === 'warn' || check.tone === 'error';
}

function headline(facts, checks) {
  if (!facts.running) return { tone: 'error', text: "NeoRecall isn't running" };
  if (checks.some((check) => check.tone === 'error')) return { tone: 'error', text: 'NeoRecall needs attention' };
  const suggestions = checks.filter((check) => check.tone === 'warn').length;
  if (suggestions > 0) {
    return { tone: 'warn', text: `Running — ${suggestions === 1 ? '1 thing needs' : `${suggestions} things need`} a look` };
  }
  return { tone: 'ok', text: "Everything's working" };
}

// Label and detail side by side, or the detail under its label when the
// window is narrow. A check that needs attention says how to fix it.
function printChecks(checks) {
  const narrow = ui.isNarrow();
  const indent = narrow ? 4 : LABEL_WIDTH + 6;
  ui.blank();
  for (const check of checks) {
    if (narrow) {
      ui.item(check.tone, ui.paint.bold(check.label));
      if (check.detail) ui.paragraph(check.detail, { indent, style: ui.paint.muted });
    } else {
      ui.item(check.tone, ui.paint.bold(check.label), check.detail, LABEL_WIDTH);
    }
    if (check.fix) ui.print(`${' '.repeat(indent)}${ui.paint.faint('run')} ${ui.paint.command(check.fix)}`);
    if (check.advice) ui.paragraph(check.advice, { indent, style: ui.paint.faint });
  }
}

function printStatus(facts, { details = false } = {}) {
  const checks = statusChecks(facts);
  const top = headline(facts, checks);
  ui.blank();
  ui.print(`  ${ui.paint.tone(top.tone, ui.TONES[top.tone].mark)} ${ui.paint.bold(top.text)}`);
  // The headline already says whether NeoRecall runs.
  if (facts.running) ui.print(`    ${ui.paint.accent(facts.url)}`);
  else ui.print(`    ${ui.paint.faint('run')} ${ui.paint.command('neorecall start')}`);
  const shown = details ? checks : checks.filter((check) => check.id !== 'server' && needsAttention(check));
  if (shown.length > 0) printChecks(shown);
  if (details) {
    ui.section('Details');
    const rows = [
      ['Installed in', facts.appDir],
      ['Data folder', facts.runtimeHome],
      ['Version', facts.versionLabel],
      ['Running version', facts.runningVersion || 'not running'],
      ['Release channel', facts.channelSummary],
      ['Settings file', facts.envFile],
      ['Port', String(facts.port)],
    ];
    for (const [label, value] of rows) ui.print(`  ${ui.padEnd(ui.paint.faint(label), 18)}${value}`);
  }
  ui.blank();
}

module.exports = {
  needsAttention,
  printChecks,
  printStatus,
  statusChecks,
};
