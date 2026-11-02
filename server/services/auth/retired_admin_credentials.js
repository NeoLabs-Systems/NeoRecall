'use strict';

// The standalone admin dashboard's login and API key. Admin is an account role
// now, so these grant nothing. They are dropped from the env file when found
// and reported when the deployment sets them itself.
//
// No database here on purpose: the supervisor runs this before it starts the
// HTTP and worker processes, so neither inherits keys the file no longer has.

const fs = require('node:fs');
const { ENV_FILE } = require('../../../runtime/paths');
const { parseEnv, readEnvFileRaw, removeEnvValue } = require('../../../runtime/env');

const RETIRED_ADMIN_ENV_KEYS = ['ADMIN_USERNAME', 'ADMIN_PASSWORD', 'ADMIN_API_KEY'];

function isSymlink(file) {
  try {
    return fs.lstatSync(file).isSymbolicLink();
  } catch {
    return false;
  }
}

/**
 * Removes the retired keys from the env file and from `env`. Never throws: a
 * read-only or linked env file is a reason to report, not to refuse to start.
 * `ignored` names keys that stay because the environment or an uneditable file
 * sets them; `error` says why the file could not be edited, when it could not.
 */
function retireDashboardCredentials(envFile = ENV_FILE, env = process.env) {
  const stored = parseEnv(readEnvFileRaw(envFile));
  const inFile = RETIRED_ADMIN_ENV_KEYS.filter((key) => stored.has(key));
  const inEnvironment = RETIRED_ADMIN_ENV_KEYS.filter((key) => String(env[key] ?? '').trim());
  const removed = [];
  let error = null;
  if (inFile.length && isSymlink(envFile)) {
    // Rewriting would replace the link with a plain file.
    error = `${envFile} is a symbolic link`;
  } else {
    for (const key of inFile) {
      try {
        removeEnvValue(envFile, key);
        removed.push(key);
      } catch (cause) {
        error = cause.message;
        break;
      }
    }
  }
  // Dropped from this process either way; nothing reads them any more.
  for (const key of RETIRED_ADMIN_ENV_KEYS) delete env[key];
  const ignored = RETIRED_ADMIN_ENV_KEYS.filter((key) => !removed.includes(key)
    && (inFile.includes(key) || inEnvironment.includes(key)));
  return { removed, ignored, error };
}

/// A copy of `env` without the retired keys, for child processes.
function withoutRetiredCredentials(env) {
  const copy = { ...env };
  for (const key of RETIRED_ADMIN_ENV_KEYS) delete copy[key];
  return copy;
}

module.exports = { RETIRED_ADMIN_ENV_KEYS, retireDashboardCredentials, withoutRetiredCredentials };
