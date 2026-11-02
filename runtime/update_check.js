'use strict';

// Is a newer version waiting on the release channel? One answer for the
// command line (`neorecall update`, `neorecall status`) and the admin UI.

const { choosePreferredBranchForChannel } = require('./release_channel');
const { createGitHelpers } = require('./git_helpers');
const { createUpdateGit } = require('../lib/cli/updates');

// The branch a channel follows. Stable falls back to beta only while no stable
// branch exists, so nobody is moved to older code by accident.
function resolvePreferredBranch(channel, run, { onFallback = () => {} } = {}) {
  const git = createGitHelpers(run);
  // Read from the refs the last fetch brought: no second round trip, and a
  // server never waits on the network here.
  const hasBranch = (branch) => run('git', ['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}`]).status === 0;
  const hasMain = hasBranch('main');
  const hasBeta = hasBranch('beta');
  if (channel === 'stable') {
    if (hasMain) return 'main';
    if (hasBeta) {
      onFallback('Stable channel selected, but origin/main is missing; using origin/beta until a stable branch exists.');
      return 'beta';
    }
    throw new Error('No origin/main or origin/beta branch was found for updates.');
  }
  const preferred = choosePreferredBranchForChannel(channel, {
    stable: git.latestStableGitTagVersion(),
    beta: git.latestBetaGitTagVersion(),
  });
  if (preferred === 'beta') {
    if (hasBeta) return 'beta';
    if (hasMain) return 'main';
  } else if (hasMain) {
    return 'main';
  } else if (hasBeta) {
    return 'beta';
  }
  throw new Error(`Release channel branch "${preferred}" was not found on origin.`);
}

// `run(cmd, args, options)` is a spawnSync-shaped runner. `fetchRemote` may be
// replaced by an async one so a server never blocks on the network.
async function checkForUpdate({ run, channel, fetchRemote, onFallback }) {
  const updateGit = createUpdateGit(run);
  const fetched = await (fetchRemote || updateGit.fetchRemote)();
  if (!fetched) return { checked: false, update: null, reason: 'offline' };
  try {
    const branch = resolvePreferredBranch(channel, run, { onFallback });
    const pending = updateGit.pendingUpdate(branch);
    if (!pending) return { checked: true, update: null, branch };
    return {
      checked: true,
      branch,
      update: {
        version: pending.version,
        branch,
        changes: updateGit.changesBetween(updateGit.head().sha, pending.remoteRef),
      },
    };
  } catch (error) {
    return { checked: false, update: null, reason: 'failed', error: error.message };
  }
}

module.exports = { checkForUpdate, resolvePreferredBranch };
