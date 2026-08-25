'use strict';

// One protocol contract shared by route validation and capability discovery.
// Clients use the advertised value to split arbitrarily large durable ledgers.
const CHUNK_RECEIPT_BATCH_LIMIT = 500;

module.exports = { CHUNK_RECEIPT_BATCH_LIMIT };
