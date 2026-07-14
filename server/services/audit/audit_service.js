'use strict';

const { getDatabase } = require('../../db/database');

function record({ actorType, actorId = null, affectedUserId = null, action, resourceType = null, resourceId = null, ipAddress = null, metadata = null }) {
  getDatabase().prepare(`INSERT INTO audit_log
    (actor_type, actor_id, affected_user_id, action, resource_type, resource_id, ip_address, metadata_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(actorType, actorId, affectedUserId, action, resourceType, resourceId, ipAddress, metadata ? JSON.stringify(metadata) : null);
}

module.exports = { record };
