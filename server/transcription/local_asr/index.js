'use strict';

const path = require('node:path');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { getConfig } = require('../../config');
const manifestModule = require('../../local_runtime/manifest');
const { ComponentInstaller } = require('../../local_runtime/component_installer');
const { WhistleRuntime, smokeTest } = require('./runtime');

const COMPONENT_ID = 'whistle';
const WORKER_SCRIPT = path.join(__dirname, 'whistle_worker.py');

// One installer and one runtime per process, built on first use. Both depend on
// the runtime home and the configuration, so they are created lazily rather than
// when this module is required, and `reset` lets tests start over.
let installer;
let runtime;

// What the worker is started with: the interpreter, the engine library and the
// model, all from the installed component.
function filesOf(component) {
  return { python: component.pathOf('python'), library: component.pathOf('engine'), weights: component.pathOf('weights'), worker: WORKER_SCRIPT };
}

function getInstaller() {
  if (!installer) {
    const config = getConfig();
    installer = new ComponentInstaller({
      manifest: manifestModule.load(),
      componentId: COMPONENT_ID,
      directory: path.join(ensureRuntimeDirs().models, 'local', COMPONENT_ID),
      config,
      smoke: (component) => smokeTest(filesOf(component), config),
    });
  }
  return installer;
}

function getRuntime() {
  if (!runtime) runtime = new WhistleRuntime({ files: filesOf(getInstaller()), config: getConfig() });
  return runtime;
}

async function reset() {
  await runtime?.stop();
  runtime = undefined;
  installer = undefined;
}

module.exports = { getInstaller, getRuntime, reset, COMPONENT_ID };
