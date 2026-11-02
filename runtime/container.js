'use strict';

// Whether this process runs inside a container (Docker, Podman, Kubernetes).
// The CLI behaves differently there: there is no launchd/systemd user service
// to install, no git checkout to pull and no Flutter SDK in a global npm
// prefix — the image is the unit of deployment.
const fs = require('node:fs');

function detectContainer(env = process.env) {
  if (['1', 'true', 'yes', 'on'].includes(String(env.NEORECALL_CONTAINER || '').toLowerCase())) return true;
  if (env.KUBERNETES_SERVICE_HOST) return true;
  if (env.container) return env.container !== 'host';
  try {
    if (fs.existsSync('/.dockerenv')) return true;
  } catch { /* not there */ }
  try {
    return /docker|podman|kubepods|lxc/i.test(fs.readFileSync('/proc/1/cgroup', 'utf8'));
  } catch {
    return false;
  }
}

module.exports = { detectContainer };
