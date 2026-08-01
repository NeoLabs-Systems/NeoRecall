'use strict';

// Zoom cloud recording import via the official Zoom REST API.
//
// Lists the authenticated user's cloud recordings and downloads the best
// available file (preferring audio-only M4A when present). See:
// https://developers.zoom.us/docs/api/rest/reference/zoom-api/methods/#operation/recordingsList

const oauth = require('../oauth/outbound_oauth');
const { resolveProvider } = require('./catalog');
const { downloadToFile } = require('../cloud/cloud_import_base');

const API_BASE = 'https://api.zoom.us/v2';

function provider() {
  const resolved = resolveProvider('zoom');
  if (!resolved?.available) {
    const error = new Error(resolved?.unavailableReason || 'Zoom OAuth is not configured.');
    error.status = 503;
    throw error;
  }
  return resolved;
}

async function zoomFetch(source, path, { updateConfig } = {}) {
  const response = await oauth.authorizedFetch(provider(), source, `${API_BASE}${path}`, {}, { updateConfig });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = new Error(`Zoom API ${response.status}: ${body.slice(0, 200)}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

async function verifyIdentity(source, { updateConfig } = {}) {
  const me = await zoomFetch(source, '/users/me', { updateConfig });
  return {
    accountEmail: me.email || me.user_email || null,
    accountId: me.id || me.account_id || null,
    displayName: me.display_name || me.first_name || null,
  };
}

function pickRecordingFile(files) {
  if (!Array.isArray(files) || files.length === 0) return null;
  const rank = (file) => {
    const type = String(file.file_type || file.recording_type || '').toUpperCase();
    if (type === 'M4A' || type.includes('AUDIO')) return 0;
    if (type === 'MP4' || type.includes('SHARED_SCREEN_WITH_SPEAKER_VIEW')) return 1;
    if (type === 'MP4') return 2;
    return 9;
  };
  return [...files].sort((a, b) => rank(a) - rank(b))[0];
}

function contentTypeFor(file) {
  const type = String(file?.file_type || '').toUpperCase();
  if (type === 'M4A') return 'audio/mp4';
  if (type === 'MP3') return 'audio/mpeg';
  if (type === 'MP4') return 'video/mp4';
  return 'application/octet-stream';
}

function extensionFor(file) {
  const type = String(file?.file_type || '').toLowerCase();
  if (type === 'm4a') return 'm4a';
  if (type === 'mp3') return 'mp3';
  if (type === 'mp4') return 'mp4';
  return 'bin';
}

async function listRecordings(source, { updateConfig } = {}) {
  // Zoom pages by month range; ask for the last 30 days of meetings.
  const to = new Date();
  const from = new Date(to.getTime() - 30 * 24 * 60 * 60_000);
  const fromStr = from.toISOString().slice(0, 10);
  const toStr = to.toISOString().slice(0, 10);

  const items = [];
  let nextPageToken = '';
  do {
    const query = new URLSearchParams({
      from: fromStr,
      to: toStr,
      page_size: '30',
    });
    if (nextPageToken) query.set('next_page_token', nextPageToken);
    const page = await zoomFetch(source, `/users/me/recordings?${query}`, { updateConfig });
    for (const meeting of page.meetings || []) {
      const file = pickRecordingFile(meeting.recording_files || []);
      if (!file?.download_url && !file?.play_url) continue;
      const externalId = String(file.id || file.file_id || `${meeting.uuid}:${file.file_type}`);
      const downloadUrl = file.download_url || file.play_url;
      items.push({
        externalId,
        title: meeting.topic || meeting.id || 'Zoom recording',
        startedAt: meeting.start_time || file.recording_start || null,
        contentType: contentTypeFor(file),
        extension: extensionFor(file),
        download: async (destPath, opts) => {
          // Zoom download URLs need the access token as a query param or header.
          const token = await oauth.ensureAccessToken(provider(), source, {
            updateConfig: opts?.updateConfig || updateConfig,
          });
          const url = new URL(downloadUrl);
          url.searchParams.set('access_token', token);
          await downloadToFile(url.toString(), destPath);
        },
      });
    }
    nextPageToken = page.next_page_token || '';
  } while (nextPageToken);

  return items;
}

async function verifyAccess(config) {
  // OAuth-created sources always have tokens; paste-style verify is not used.
  if (!config?.accessToken && !config?.refreshToken) {
    throw new Error('Connect Zoom with OAuth from the Sources screen.');
  }
  return { accountEmail: config.accountEmail || null };
}

module.exports = {
  id: 'zoom',
  label: 'Zoom',
  type: 'zoom',
  verifyIdentity,
  listRecordings,
  verifyAccess,
};
