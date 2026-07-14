'use strict';

const token = sessionStorage.getItem('neorecall_admin_token');
if (!token) location.href = '/admin/login.html';
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' })[character]);
async function api(path, options = {}) {
  const response = await fetch(`/admin/api/v1${path}`, { ...options, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(options.headers || {}) } });
  if (response.status === 401) { sessionStorage.removeItem('neorecall_admin_token'); location.href = '/admin/login.html'; throw new Error('Signed out'); }
  const value = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(value?.error?.message || 'Request failed');
  return value;
}
const settingLabels = {
  voiceMatchThreshold: 'Voice match threshold', voiceMatchMargin: 'Voice runner-up margin', speakerClusterThreshold: 'Speaker cluster threshold',
  dedupeTokenSimilarity: 'Token dedupe similarity', dedupeTimeToleranceMs: 'Dedupe time tolerance (ms)', conversationHardGapMs: 'Conversation hard gap (ms)',
  conversationMinimumMs: 'Minimum conversation (ms)', conversationQuietCloseMs: 'Quiet close delay (ms)', conversationValleyQuantile: 'Embedding valley quantile',
  minNewMaterialChars: 'Minimum new characters', maxConsolidationInputChars: 'Maximum consolidation characters',
};
function renderSettings(settings) {
  document.querySelector('#processing-settings').innerHTML = Object.entries(settings).map(([key, value]) => `<label>${escapeHtml(settingLabels[key] || key)}<input type="number" step="any" data-setting="${escapeHtml(key)}" value="${escapeHtml(value)}"></label>`).join('');
}
async function load() {
  const [stats, userData, jobData, aiData, auditData, settingsData] = await Promise.all([
    api('/stats'), api('/users'), api('/jobs?limit=50'), api('/ai-requests?limit=50'), api('/audit?limit=50'), api('/processing-settings'),
  ]);
  const aiCost = stats.ai.reduce((sum, row) => sum + Number(row.cost_usd || 0), 0);
  document.querySelector('#status').innerHTML = [
    ['Users', stats.users], ['Recordings', stats.recordings], ['Queue', stats.queue.filter((row) => row.status === 'queued').reduce((sum, row) => sum + row.count, 0)],
    ['Oldest queued', stats.oldestQueuedAt ? new Date(stats.oldestQueuedAt).toLocaleString() : 'None'], ['Temporary audio', `${(stats.temporaryAudioBytes / 1048576).toFixed(1)} MB`],
    ['Cleanup pending', stats.cleanupPending], ['Vector index', stats.vector.ready ? `Ready · ${stats.vector.version}` : 'Unavailable'], ['AI cost', `$${aiCost.toFixed(4)}`],
  ].map(([label, value]) => `<article><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`).join('');
  document.querySelector('#workers').textContent = stats.workers.length ? stats.workers.map((worker) => `${worker.host} · ${worker.model_state} · ${new Date(worker.heartbeat_at).toLocaleString()}`).join('\n') : 'No current worker heartbeat.';
  document.querySelector('#processing').innerHTML = stats.processing.map((metric) => `<span>${escapeHtml(metric.metric)}: ${Number(metric.average).toFixed(3)} ${escapeHtml(metric.unit)} average</span>`).join('');
  document.querySelector('#users').innerHTML = userData.users.map((user) => `<tr><td>${escapeHtml(user.username)}<small>${escapeHtml(user.email || '')}</small></td><td>${escapeHtml(user.role)}</td><td>${user.device_count}</td><td>${user.recording_count}</td><td>${user.disabled_at ? 'Disabled' : 'Active'}</td><td><button data-user="${user.id}" data-disabled="${!user.disabled_at}" class="secondary">${user.disabled_at ? 'Enable' : 'Disable'}</button></td></tr>`).join('');
  document.querySelector('#jobs').innerHTML = jobData.jobs.map((job) => `<tr><td>${escapeHtml(job.type)}</td><td>${escapeHtml(job.status)}</td><td>${job.attempts}/${job.max_attempts}</td><td>${new Date(job.created_at).toLocaleString()}</td><td>${job.status === 'failed' ? `<button data-retry="${job.id}">Retry</button>` : ''}${['queued', 'failed'].includes(job.status) ? `<button data-cancel="${job.id}" class="secondary">Cancel</button>` : ''}</td></tr>`).join('');
  document.querySelector('#ai').innerHTML = aiData.requests.map((entry) => `<tr><td>${escapeHtml(entry.purpose)}</td><td>${escapeHtml(entry.state)}</td><td>${escapeHtml(entry.model)}</td><td>${Number(entry.prompt_tokens || 0) + Number(entry.completion_tokens || 0)}</td><td>$${Number(entry.cost_usd || 0).toFixed(5)}</td><td>${entry.sent_at ? new Date(entry.sent_at).toLocaleString() : 'Reserved'}</td></tr>`).join('');
  document.querySelector('#audit').innerHTML = auditData.entries.map((entry) => `<tr><td>${escapeHtml(entry.actor_type)}${entry.actor_id ? ` · ${escapeHtml(entry.actor_id.slice(0, 8))}` : ''}</td><td>${escapeHtml(entry.action)}</td><td>${escapeHtml([entry.resource_type, entry.resource_id].filter(Boolean).join(' · '))}</td><td>${new Date(entry.created_at).toLocaleString()}</td></tr>`).join('');
  renderSettings(settingsData.settings);
}
document.addEventListener('click', async (event) => {
  const button = event.target.closest('button');
  if (button?.dataset.user) await api(`/users/${button.dataset.user}`, { method: 'PATCH', body: JSON.stringify({ disabled: button.dataset.disabled === 'true' }) });
  if (button?.dataset.retry) await api(`/jobs/${button.dataset.retry}/retry`, { method: 'POST' });
  if (button?.dataset.cancel) await api(`/jobs/${button.dataset.cancel}/cancel`, { method: 'POST' });
  if (button?.dataset.user || button?.dataset.retry || button?.dataset.cancel) await load();
});
document.querySelector('#save-settings').onclick = async () => {
  const settings = Object.fromEntries([...document.querySelectorAll('[data-setting]')].map((input) => [input.dataset.setting, Number(input.value)]));
  await api('/processing-settings', { method: 'PUT', body: JSON.stringify(settings) });
  await load();
};
document.querySelector('#refresh').onclick = () => load().catch((error) => alert(error.message));
document.querySelector('#logout').onclick = async () => { await api('/logout', { method: 'POST' }); sessionStorage.removeItem('neorecall_admin_token'); location.href = '/admin/login.html'; };
load().catch((error) => alert(error.message));
