'use strict';

const { createCloudSource } = require('./cloud/cloud_import_base');
const zoom = require('./platforms/zoom');

module.exports = createCloudSource(zoom);
