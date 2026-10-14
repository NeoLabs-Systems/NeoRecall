'use strict';

const ui = require('./ui');

// What a failed command means to the person who ran it, by error code. The
// error's own message says what happened; this adds the headline and the
// next thing to try.
const GUIDANCE = Object.freeze({
  SERVER_NOT_READY: { title: "NeoRecall started but isn't answering", next: 'neorecall logs' },
  PORT_IN_USE: { title: "NeoRecall couldn't start", next: 'neorecall start' },
  UPDATE_ROLLED_BACK: { title: "The update didn't work, so NeoRecall went back", next: 'neorecall logs' },
  UPDATE_ROLLBACK_FAILED: { title: "The update didn't work and NeoRecall couldn't go back", next: 'neorecall repair' },
});

function printError(error, { details = false } = {}) {
  const write = (line = '') => process.stderr.write(`${line}\n`);
  if (error?.code === 'CLI_CANCELLED') {
    write(`\n  ${ui.paint.muted('Cancelled.')}`);
    return;
  }
  const guidance = GUIDANCE[error?.code] || { title: 'Something went wrong', next: 'neorecall doctor' };
  // Without a terminal (the desktop installer reads the last line) the whole
  // error is one line.
  if (!process.stderr.isTTY) {
    write(`✕ ${guidance.title}: ${error?.message || error}`);
    return;
  }
  write('');
  write(`  ${ui.paint.error('✕')} ${ui.paint.bold(guidance.title)}`);
  if (error?.message) write(`    ${error.message}`);
  write('');
  write(`  ${ui.paint.muted('Try')} ${ui.paint.command(guidance.next)}${ui.paint.muted(
    guidance.next === 'neorecall repair' ? '' : '  ·  still stuck? neorecall repair tries the usual fixes',
  )}`);
  if (details) {
    write('');
    write(`  ${ui.paint.muted(`Technical details${error?.code ? ` (${error.code})` : ''}:`)}`);
    write(ui.paint.muted(String(error?.stack || error).split('\n').map((line) => `    ${line}`).join('\n')));
  } else {
    write(`  ${ui.paint.muted('Technical details: add --details')}`);
  }
  write('');
}

module.exports = {
  printError,
};
