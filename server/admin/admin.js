'use strict';

const token = sessionStorage.getItem('neorecall_admin_token');
if (!token) location.replace('/admin/login.html');

const escapeHtml = (value) => String(value ?? '').replace(
  /[&<>"']/g,
  (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' })[character],
);
const dateLabel = (value) => value ? new Date(value).toLocaleString() : '—';
const pages = {
  overview: ['Overview', 'System health, queue state and retained data.'],
  users: ['Users', 'Accounts and their isolated recording activity.'],
  jobs: ['Jobs', 'Background processing, retries and terminal failures.'],
  ai: ['AI requests', 'Remote analysis usage and cost.'],
  audit: ['Audit log', 'Security-sensitive administrative changes.'],
  processing: ['Processing', 'Live diarization, deduplication and consolidation thresholds.'],
};
let toastTimer;

async function api(path, options = {}) {
  const response = await fetch(`/admin/api/v1${path}`, {
    ...options,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  if (response.status === 401) {
    sessionStorage.removeItem('neorecall_admin_token');
    location.replace('/admin/login.html');
    throw new Error('Signed out');
  }
  const value = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(value?.error?.message || 'Request failed');
  return value;
}

function badge(value) {
  const normalized = String(value || '').toLowerCase();
  const kind = ['active', 'complete', 'completed', 'succeeded', 'ready'].includes(normalized)
    ? 'ok'
    : ['failed', 'disabled', 'cancelled'].includes(normalized)
      ? 'err'
      : ['queued', 'pending', 'reserved'].includes(normalized) ? 'warn' : normalized === 'running' ? 'running' : 'idle';
  return `<span class="badge badge-${kind}">${escapeHtml(value || 'Unknown')}</span>`;
}

function showToast(message) {
  const element = document.querySelector('#toast');
  element.textContent = message;
  element.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => element.classList.remove('visible'), 2600);
}

function showError(error) {
  const element = document.querySelector('#global-error');
  element.textContent = error.message || 'Request failed';
  element.classList.add('visible');
}

function showPage(name, updateHash = true) {
  const page = pages[name] ? name : 'overview';
  document.querySelectorAll('[data-page]').forEach((item) => item.classList.toggle('active', item.dataset.page === page));
  document.querySelectorAll('[data-page-content]').forEach((item) => item.classList.toggle('active', item.dataset.pageContent === page));
  document.querySelector('#page-title').textContent = pages[page][0];
  document.querySelector('#page-subtitle').textContent = pages[page][1];
  if (updateHash && location.hash !== `#${page}`) history.replaceState(null, '', `#${page}`);
}

const settingLabels = {
  voiceMatchThreshold: 'Voice match threshold',
  voiceMatchMargin: 'Voice runner-up margin',
  speakerClusterThreshold: 'Speaker cluster threshold',
  dedupeTokenSimilarity: 'Token dedupe similarity',
  dedupeTimeToleranceMs: 'Dedupe time tolerance (ms)',
  conversationHardGapMs: 'Conversation hard gap (ms)',
  conversationSoftGapMs: 'Conversation soft gap (ms)',
  conversationMinimumMs: 'Minimum conversation (ms)',
  conversationQuietCloseMs: 'Quiet close delay (ms)',
  conversationValleyQuantile: 'Embedding valley quantile',
  conversationSemanticSimilarityThreshold: 'Semantic similarity threshold',
  conversationSemanticValleyProminence: 'Semantic valley prominence',
  conversationSemanticContextSegments: 'Semantic context segments',
  conversationMaximumMs: 'Maximum conversation duration (ms)',
  conversationMaximumCharacters: 'Maximum conversation characters',
  minNewMaterialChars: 'Minimum new characters',
  maxConsolidationInputChars: 'Maximum consolidation characters',
};

function renderSettings(settings) {
  document.querySelector('#processing-settings').innerHTML = Object.entries(settings)
    .map(([key, value]) => `<label>${escapeHtml(settingLabels[key] || key)}<input type="number" step="any" data-setting="${escapeHtml(key)}" value="${escapeHtml(value)}"></label>`)
    .join('');
}

function renderEmpty(columns, message) {
  return `<tr><td colspan="${columns}"><div class="empty">${escapeHtml(message)}</div></td></tr>`;
}

async function load({ announce = false } = {}) {
  document.querySelector('#global-error').classList.remove('visible');
  const [stats, userData, jobData, aiData, auditData, settingsData] = await Promise.all([
    api('/stats'),
    api('/users'),
    api('/jobs?limit=50'),
    api('/ai-requests?limit=50'),
    api('/audit?limit=50'),
    api('/processing-settings'),
  ]);
  const queued = stats.queue.filter((row) => row.status === 'queued').reduce((sum, row) => sum + row.count, 0);
  const failed = jobData.jobs.filter((job) => job.status === 'failed').length;
  const aiCost = stats.ai.reduce((sum, row) => sum + Number(row.cost_usd || 0), 0);
  const tiles = [
    ['Users', stats.users, 'ok'],
    ['Recordings', stats.recordings, 'ok'],
    ['Queued work', queued, queued ? 'warn' : 'ok'],
    ['Oldest queued', stats.oldestQueuedAt ? dateLabel(stats.oldestQueuedAt) : 'None', stats.oldestQueuedAt ? 'warn' : 'ok'],
    ['Temporary audio', `${(stats.temporaryAudioBytes / 1048576).toFixed(1)} MB`, stats.temporaryAudioBytes ? 'warn' : 'ok'],
    ['Cleanup pending', stats.cleanupPending, stats.cleanupPending ? 'warn' : 'ok'],
    ['Vector index', stats.vector.ready ? `Ready · ${stats.vector.version}` : 'Unavailable', stats.vector.ready ? 'ok' : 'fail'],
    ['AI cost', `$${aiCost.toFixed(4)}`, 'ok'],
  ];
  document.querySelector('#status').innerHTML = tiles.map(([label, value, state]) => `<article class="status-tile"><span class="status-dot ${state}"></span><div><div class="status-label">${escapeHtml(label)}</div><div class="status-detail">${escapeHtml(value)}</div></div></article>`).join('');
  document.querySelector('#workers').textContent = stats.workers.length
    ? stats.workers.map((worker) => `${worker.host} · ${worker.model_state} · ${dateLabel(worker.heartbeat_at)}`).join('\n')
    : 'No current worker heartbeat.';
  document.querySelector('#processing').innerHTML = stats.processing.length
    ? stats.processing.map((metric) => `<span>${escapeHtml(metric.metric)} · ${Number(metric.average).toFixed(3)} ${escapeHtml(metric.unit)} avg</span>`).join('')
    : '<span>No processing samples yet</span>';
  document.querySelector('#users').innerHTML = userData.users.length ? userData.users.map((user) => `<tr><td>${escapeHtml(user.username)}<small>${escapeHtml(user.email || '')}</small></td><td>${escapeHtml(user.role)}</td><td>${user.device_count}</td><td>${user.recording_count}</td><td>${badge(user.disabled_at ? 'Disabled' : 'Active')}</td><td><button data-user="${user.id}" data-disabled="${!user.disabled_at}" class="${user.disabled_at ? 'btn btn-ghost' : 'btn btn-danger'} btn-sm">${user.disabled_at ? 'Enable' : 'Disable'}</button></td></tr>`).join('') : renderEmpty(6, 'No accounts found.');
  document.querySelector('#jobs').innerHTML = jobData.jobs.length ? jobData.jobs.map((job) => `<tr><td>${escapeHtml(job.type)}</td><td>${badge(job.status)}</td><td>${job.attempts}/${job.max_attempts}</td><td>${dateLabel(job.created_at)}</td><td>${job.status === 'failed' ? `<button data-retry="${job.id}" class="btn btn-primary btn-sm">Retry</button>` : ''}${['queued', 'failed'].includes(job.status) ? `<button data-cancel="${job.id}" class="btn btn-ghost btn-sm">Cancel</button>` : ''}</td></tr>`).join('') : renderEmpty(5, 'No jobs found.');
  document.querySelector('#ai').innerHTML = aiData.requests.length ? aiData.requests.map((entry) => `<tr><td>${escapeHtml(entry.purpose)}</td><td>${badge(entry.state)}</td><td>${escapeHtml(entry.model)}</td><td>${Number(entry.prompt_tokens || 0) + Number(entry.completion_tokens || 0)}</td><td>$${Number(entry.cost_usd || 0).toFixed(5)}</td><td>${entry.sent_at ? dateLabel(entry.sent_at) : 'Reserved'}</td></tr>`).join('') : renderEmpty(6, 'No AI requests found.');
  document.querySelector('#audit').innerHTML = auditData.entries.length ? auditData.entries.map((entry) => `<tr><td>${escapeHtml(entry.actor_type)}${entry.actor_id ? `<small>${escapeHtml(entry.actor_id.slice(0, 8))}</small>` : ''}</td><td>${escapeHtml(entry.action)}</td><td>${escapeHtml([entry.resource_type, entry.resource_id].filter(Boolean).join(' · '))}</td><td>${dateLabel(entry.created_at)}</td></tr>`).join('') : renderEmpty(4, 'No audit entries found.');
  const jobBadge = document.querySelector('#job-badge');
  jobBadge.hidden = failed === 0;
  jobBadge.textContent = String(failed);
  renderSettings(settingsData.settings);
  document.querySelector('#last-refresh').textContent = `Updated ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
  if (announce) showToast('Admin data refreshed');
}

document.addEventListener('click', async (event) => {
  const pageButton = event.target.closest('[data-page]');
  if (pageButton) return showPage(pageButton.dataset.page);
  const button = event.target.closest('button');
  try {
    if (button?.dataset.user) {
      await api(`/users/${button.dataset.user}`, { method: 'PATCH', body: JSON.stringify({ disabled: button.dataset.disabled === 'true' }) });
      await load();
      showToast('Account updated');
    } else if (button?.dataset.retry) {
      await api(`/jobs/${button.dataset.retry}/retry`, { method: 'POST' });
      await load();
      showToast('Job queued for retry');
    } else if (button?.dataset.cancel) {
      await api(`/jobs/${button.dataset.cancel}/cancel`, { method: 'POST' });
      await load();
      showToast('Job cancelled');
    }
  } catch (error) {
    showError(error);
  }
});

document.querySelector('#save-settings').addEventListener('click', async () => {
  try {
    const settings = Object.fromEntries([...document.querySelectorAll('[data-setting]')].map((input) => [input.dataset.setting, Number(input.value)]));
    await api('/processing-settings', { method: 'PUT', body: JSON.stringify(settings) });
    await load();
    showToast('Processing settings saved');
  } catch (error) {
    showError(error);
  }
});
document.querySelector('#refresh').addEventListener('click', () => load({ announce: true }).catch(showError));
document.querySelector('#logout').addEventListener('click', async () => {
  try { await api('/logout', { method: 'POST' }); } finally {
    sessionStorage.removeItem('neorecall_admin_token');
    location.replace('/admin/login.html');
  }
});
window.addEventListener('hashchange', () => showPage(location.hash.slice(1), false));
showPage(location.hash.slice(1), false);
load().catch(showError);
