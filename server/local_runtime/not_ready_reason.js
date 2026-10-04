'use strict';

// What to tell an operator when a local model cannot serve yet, from its install
// status. Shared so both local providers explain themselves the same way.
function notReadyReason(status) {
  switch (status.phase) {
    case 'unsupported': return status.reason;
    case 'installing': return `${status.label} is still being downloaded (${status.progress?.percent ?? 0}%). It is ready once that finishes.`;
    case 'failed': return `${status.label} could not be installed: ${status.error?.message || 'unknown error'}. It is retried automatically.`;
    case 'not_installed': return `${status.label} is not installed yet. Installation starts automatically once it is selected.`;
    default: return null;
  }
}

module.exports = { notReadyReason };
