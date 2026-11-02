'use strict';

const ui = require('./ui');

const CLI = 'neorecall';

// Everyday commands, grouped by what someone is trying to do.
const GROUPS = Object.freeze([
  ['Getting started', [
    ['install', 'Set up NeoRecall and start it with your computer'],
    ['setup', 'Download the speech and search models'],
    ['reset-password <user>', 'Get back into an account'],
  ]],
  ['Everyday', [
    ['status', 'Is everything working?'],
    ['update', 'Get the latest version — your memories stay'],
    ['restart', 'Turn it off and on again'],
  ]],
  ['Your memories', [
    ['backup', 'Save an encrypted copy now'],
    ['backup list', 'See saved copies and the schedule'],
    ['restore <key>', 'Bring a saved copy back'],
  ]],
  ["When something's wrong", [
    ['doctor', 'Find problems and explain them'],
    ['repair', 'Fix common problems for you'],
    ['logs', 'See what NeoRecall has been doing'],
  ]],
]);

// Every command and flag, for developers and admins.
const REFERENCE = Object.freeze([
  ['Setup', [
    ['install [--skip-models]', 'Dependencies, database, models and the background service'],
    ['setup [--skip-models]', 'Database, models and web client, without the service'],
    ['setup --channel stable|beta', 'Set the release channel while setting up'],
  ]],
  ['Running', [
    ['start · stop · restart', 'Control the background service'],
    ['status --details', 'Health plus install folder, data folder, versions and port'],
    ['doctor', 'Read-only diagnostics'],
    ['logs', 'Print the server log'],
    ['repair', 'Reinstall dependencies, web client, models and service'],
    ['uninstall', 'Remove the background service (keeps your data)'],
  ]],
  ['Updates', [
    ['update [stable|beta]', 'Update, optionally switching channel; rolls back if it fails'],
    ['update --notes', "Show what's new without updating"],
    ['channel [stable|beta]', 'Show or switch the release channel'],
    ['version', 'Print the installed version'],
    ['rebuild-web', 'Rebuild the bundled Flutter web client'],
  ]],
  ['Accounts', [
    ['admin [grant|revoke <user>] [--json]', 'List or change admins'],
    ['reset-password <user> [--password-file P]', 'Set a new password and sign out everywhere'],
  ]],
  ['Data', [
    ['backup · backup list', 'Encrypted database snapshots'],
    ['restore <key> [--output <path>]', 'Restore beside the live database (stop first)'],
    ['env list|get|set|unset', 'Read or change settings (secrets masked)'],
  ]],
]);

function printGroupColumns(groups) {
  const columns = groups.map(([name, commands]) => [
    ui.paint.accent(ui.paint.bold(name)),
    ...commands.flatMap(([command, description]) => [
      ui.paint.bold(`${CLI} ${command}`),
      ui.paint.muted(description),
    ]),
  ]);
  const columnWidth = Math.max(...columns.flat().map(ui.visibleLength)) + 4;
  const perRow = ui.width() > 2 + columnWidth * 2 ? 2 : 1;
  for (let index = 0; index < columns.length; index += perRow) {
    const [left, right = []] = columns.slice(index, index + perRow);
    ui.blank();
    for (let row = 0; row < Math.max(left.length, right.length); row += 1) {
      ui.print(`  ${ui.padEnd(left[row] || '', columnWidth)}${right[row] || ''}`.trimEnd());
    }
  }
}

function printHelp({ all = false } = {}) {
  if (all) {
    ui.title('Every neorecall command');
    const commandWidth = Math.min(52, ui.width() - 30);
    for (const [name, commands] of REFERENCE) {
      ui.section(ui.paint.accent(name));
      for (const [command, description] of commands) {
        ui.print(`  ${ui.padEnd(`neorecall ${command}`, commandWidth)}  ${ui.paint.muted(description)}`);
      }
    }
    ui.blank();
    return;
  }
  ui.title("Here's what you can do", 'Not sure? Just type neorecall and pick from a menu.');
  printGroupColumns(GROUPS);
  ui.blank();
  ui.print(`  ${ui.paint.muted('More for developers and admins:')} ${ui.paint.command('neorecall help --all')}`);
  ui.blank();
}

module.exports = {
  printHelp,
};
