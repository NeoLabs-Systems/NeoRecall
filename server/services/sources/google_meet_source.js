'use strict';

const { createCloudSource } = require('./cloud/cloud_import_base');
const googleMeet = require('./platforms/google_meet');

module.exports = createCloudSource(googleMeet);
