'use strict';

require('../runtime/env').loadEnvironment();
const { migrate } = require('../server/db/migrate');

migrate();
process.stdout.write('NeoRecall database is up to date.\n');
