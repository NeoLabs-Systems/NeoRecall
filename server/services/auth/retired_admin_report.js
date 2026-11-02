'use strict';

const { retireDashboardCredentials } = require('./retired_admin_credentials');

/// Retires the old dashboard credentials and says what happened. Shared by the
/// supervisor and a standalone HTTP process so both word it the same way.
function reportRetiredCredentials(logger) {
  const { removed, ignored, error } = retireDashboardCredentials();
  if (removed.length) {
    logger.warn('Removed retired admin dashboard credentials from the env file; admin is an account role now, managed with `neorecall admin`', { keys: removed });
  }
  if (error) {
    logger.warn('Could not remove retired admin dashboard credentials from the env file; they grant nothing, remove them by hand', { keys: ignored, reason: error });
  } else if (ignored.length) {
    logger.warn('Ignoring retired admin dashboard credentials set in the environment; remove them from the deployment', { keys: ignored });
  }
}

module.exports = { reportRetiredCredentials };
