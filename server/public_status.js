'use strict';

const { getDatabase, isVectorReady } = require('./db/database');
const { createStatusHistory } = require('./status_history');
const history = createStatusHistory();

function buildPublicStatus() {
  let storage = false;
  let worker = false;
  let vector = false;
  let language = false;
  try {
    const db = getDatabase();
    db.prepare('SELECT 1').get();
    storage = true;
    const row = db.prepare('SELECT model_state, heartbeat_at FROM worker_heartbeats ORDER BY heartbeat_at DESC LIMIT 1').get();
    worker = Boolean(row && row.model_state === 'ready' && Date.now() - Date.parse(row.heartbeat_at) < 20_000);
    vector = isVectorReady();
    language = require('./ai/provider_registry').ready();
  } catch { /* A failed check is shown as unavailable or degraded. */ }
  const components = [
    { group: 'Core', name: 'Web App & API', status: 'operational', description: 'The web server is responding to requests.' },
    { group: 'Data', name: 'Storage', status: storage ? 'operational' : 'unavailable', description: storage ? 'The database is responding.' : 'The database could not be reached.' },
    { group: 'Processing', name: 'Transcription Worker', status: worker ? 'operational' : 'degraded', description: worker ? 'A ready worker has reported recently.' : 'A ready worker has not reported recently.' },
    { group: 'AI', name: 'Language Model', status: language ? 'operational' : 'degraded', description: language ? 'A language model is configured for use.' : 'The language model is not ready to accept work.' },
    { group: 'Data', name: 'Semantic Search', status: vector ? 'operational' : 'degraded', description: vector ? 'The vector extension is available.' : 'The vector extension is unavailable.' },
  ];
  const status = components.some((item) => item.status === 'unavailable') ? 'unavailable' : components.some((item) => item.status === 'degraded') ? 'degraded' : 'operational';
  return { product: 'NeoRecall', status, updatedAt: new Date().toISOString(), refreshAfterSeconds: 60, note: status === 'operational' ? 'All monitored services are operational.' : 'One or more monitored services need attention.', components };
}
module.exports = { buildPublicStatus, history };
