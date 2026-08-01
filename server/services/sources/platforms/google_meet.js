'use strict';

// Google Meet cloud recording import via the Meet REST API + Drive.
//
// Conference recordings are listed through meet.googleapis.com; the actual
// media lives in Drive (driveDestination). The drive.meet.readonly scope
// limits access to Meet-produced files only.

const oauth = require('../oauth/outbound_oauth');
const { resolveProvider } = require('./catalog');
const { downloadToFile } = require('../cloud/cloud_import_base');

const MEET_API = 'https://meet.googleapis.com/v2';
const DRIVE_API = 'https://www.googleapis.com/drive/v3';
const OAUTH_USERINFO = 'https://www.googleapis.com/oauth2/v2/userinfo';

function provider() {
  const resolved = resolveProvider('google_meet');
  if (!resolved?.available) {
    const error = new Error(resolved?.unavailableReason || 'Google Meet OAuth is not configured.');
    error.status = 503;
    throw error;
  }
  return resolved;
}

async function googleJson(source, url, { updateConfig } = {}) {
  const response = await oauth.authorizedFetch(provider(), source, url, {}, { updateConfig });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = new Error(`Google API ${response.status}: ${body.slice(0, 200)}`);
    error.status = response.status;
    throw error;
  }
  if (response.status === 204) return null;
  return response.json();
}

async function verifyIdentity(source, { updateConfig } = {}) {
  const me = await googleJson(source, OAUTH_USERINFO, { updateConfig });
  return {
    accountEmail: me?.email || null,
    accountId: me?.id || null,
    displayName: me?.name || null,
  };
}

async function listConferenceRecords(source, { updateConfig } = {}) {
  const records = [];
  let pageToken = '';
  do {
    const query = new URLSearchParams({ pageSize: '25' });
    if (pageToken) query.set('pageToken', pageToken);
    // Filter to recent conferences so we do not walk an unbounded history.
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60_000).toISOString();
    query.set('filter', `start_time>="${thirtyDaysAgo}"`);
    const page = await googleJson(source, `${MEET_API}/conferenceRecords?${query}`, { updateConfig });
    for (const record of page?.conferenceRecords || []) {
      records.push(record);
    }
    pageToken = page?.nextPageToken || '';
  } while (pageToken);
  return records;
}

async function listRecordingsForConference(source, conferenceName, { updateConfig } = {}) {
  const query = new URLSearchParams({ pageSize: '25' });
  const page = await googleJson(
    source,
    `${MEET_API}/${conferenceName}/recordings?${query}`,
    { updateConfig },
  );
  return page?.recordings || [];
}

async function listRecordings(source, { updateConfig } = {}) {
  const items = [];
  let conferences;
  try {
    conferences = await listConferenceRecords(source, { updateConfig });
  } catch (error) {
    // Some Workspace orgs disable conferenceRecords listing; surface cleanly.
    if (error.status === 403 || error.status === 404) {
      console.warn('[google_meet] conferenceRecords unavailable:', error.message);
      return items;
    }
    throw error;
  }

  for (const conference of conferences) {
    const name = conference.name;
    if (!name) continue;
    let recordings;
    try {
      recordings = await listRecordingsForConference(source, name, { updateConfig });
    } catch (error) {
      console.warn(`[google_meet] Could not list recordings for ${name}:`, error.message);
      continue;
    }
    for (const recording of recordings) {
      const driveFileId = recording.driveDestination?.file || recording.driveDestination?.exportUri;
      // driveDestination.file is the Drive file id; exportUri is a full URL.
      let fileId = null;
      if (recording.driveDestination?.file) {
        fileId = recording.driveDestination.file;
      } else if (typeof driveFileId === 'string' && driveFileId.includes('id=')) {
        fileId = new URL(driveFileId).searchParams.get('id');
      } else if (typeof recording.driveDestination?.exportUri === 'string') {
        const match = recording.driveDestination.exportUri.match(/[-\w]{25,}/);
        fileId = match ? match[0] : null;
      }
      if (!fileId && !recording.driveDestination?.exportUri) continue;

      const externalId = recording.name || fileId || `${name}:${recording.startTime}`;
      items.push({
        externalId: String(externalId),
        title: conference.space?.displayName || conference.name || 'Google Meet recording',
        startedAt: recording.startTime || conference.startTime || null,
        contentType: 'video/mp4',
        extension: 'mp4',
        download: async (destPath, opts) => {
          const token = await oauth.ensureAccessToken(provider(), source, {
            updateConfig: opts?.updateConfig || updateConfig,
          });
          if (fileId) {
            await downloadToFile(
              `${DRIVE_API}/files/${encodeURIComponent(fileId)}?alt=media`,
              destPath,
              { headers: { Authorization: `Bearer ${token}` } },
            );
          } else {
            await downloadToFile(recording.driveDestination.exportUri, destPath, {
              headers: { Authorization: `Bearer ${token}` },
            });
          }
        },
      });
    }
  }
  return items;
}

async function verifyAccess(config) {
  if (!config?.accessToken && !config?.refreshToken) {
    throw new Error('Connect Google Meet with OAuth from the Sources screen.');
  }
  return { accountEmail: config.accountEmail || null };
}

module.exports = {
  id: 'google_meet',
  label: 'Google Meet',
  type: 'google_meet',
  verifyIdentity,
  listRecordings,
  verifyAccess,
};
