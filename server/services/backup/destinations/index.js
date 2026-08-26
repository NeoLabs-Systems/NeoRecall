'use strict';

const { createLocalDestination } = require('./local_destination');

// Destination registry.
//
// To add a remote target: implement the BackupDestination contract in a sibling
// file, register the factory here, and document the new
// `NEORECALL_BACKUP_DESTINATION` value. Nothing else needs to change — the
// service, scheduler, admin dashboard and restore command all address
// destinations only through this map.
const FACTORIES = Object.freeze({
  local: createLocalDestination,
});

function createDestination(name) {
  const factory = FACTORIES[name];
  if (!factory) {
    throw Object.assign(new Error(`Unknown backup destination "${name}". Available: ${Object.keys(FACTORIES).join(', ')}.`),
      { code: 'UNKNOWN_BACKUP_DESTINATION', retryable: false });
  }
  return factory();
}

module.exports = { createDestination, destinationNames: Object.keys(FACTORIES) };
