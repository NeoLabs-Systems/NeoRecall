'use strict';

const { createCloudSource } = require('./cloud/cloud_import_base');
const microsoftTeams = require('./platforms/microsoft_teams');

module.exports = createCloudSource(microsoftTeams);
