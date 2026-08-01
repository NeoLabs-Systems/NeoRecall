'use strict';

// Microsoft Teams cloud recording import via Microsoft Graph.
//
// Uses getAllRecordings for meetings the signed-in user organizes, then
// downloads recording content. Delegated OnlineMeetingRecording.Read.All is
// typically organizer-scoped.

const oauth = require('../oauth/outbound_oauth');
const { resolveProvider } = require('./catalog');
const { downloadToFile } = require('../cloud/cloud_import_base');

const GRAPH = 'https://graph.microsoft.com/v1.0';

function provider() {
  const resolved = resolveProvider('microsoft_teams');
  if (!resolved?.available) {
    const error = new Error(resolved?.unavailableReason || 'Microsoft Teams OAuth is not configured.');
    error.status = 503;
    throw error;
  }
  return resolved;
}

async function graphJson(source, path, { updateConfig } = {}) {
  const response = await oauth.authorizedFetch(provider(), source, `${GRAPH}${path}`, {}, { updateConfig });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = new Error(`Microsoft Graph ${response.status}: ${body.slice(0, 200)}`);
    error.status = response.status;
    throw error;
  }
  if (response.status === 204) return null;
  return response.json();
}

async function verifyIdentity(source, { updateConfig } = {}) {
  const me = await graphJson(source, '/me', { updateConfig });
  return {
    accountEmail: me?.mail || me?.userPrincipalName || null,
    accountId: me?.id || null,
    displayName: me?.displayName || null,
  };
}

async function listRecordings(source, { updateConfig } = {}) {
  const identity = source.config?.accountId
    ? { accountId: source.config.accountId }
    : await verifyIdentity(source, { updateConfig });

  const end = new Date();
  const start = new Date(end.getTime() - 30 * 24 * 60 * 60_000);
  const items = [];

  // Primary path: getAllRecordings for the organizer.
  const organizerId = identity.accountId;
  if (organizerId) {
    const filter = [
      `meetingOrganizerUserId='${organizerId}'`,
      `startDateTime=${start.toISOString()}`,
      `endDateTime=${end.toISOString()}`,
    ].join(',');
    try {
      let url = `/me/onlineMeetings/getAllRecordings(${filter})`;
      // Graph returns @odata.nextLink for pagination.
      while (url) {
        const page = url.startsWith('http')
          ? await (async () => {
            const response = await oauth.authorizedFetch(provider(), source, url, {}, { updateConfig });
            if (!response.ok) {
              const body = await response.text().catch(() => '');
              const error = new Error(`Microsoft Graph ${response.status}: ${body.slice(0, 200)}`);
              error.status = response.status;
              throw error;
            }
            return response.json();
          })()
          : await graphJson(source, url, { updateConfig });

        for (const recording of page?.value || []) {
          const externalId = recording.id || recording.recordingContentUrl;
          if (!externalId) continue;
          const contentUrl = recording.recordingContentUrl;
          if (!contentUrl) continue;
          items.push({
            externalId: String(externalId),
            title: recording.meetingId || 'Teams recording',
            startedAt: recording.createdDateTime || null,
            contentType: 'video/mp4',
            extension: 'mp4',
            download: async (destPath, opts) => {
              const token = await oauth.ensureAccessToken(provider(), source, {
                updateConfig: opts?.updateConfig || updateConfig,
              });
              await downloadToFile(contentUrl, destPath, {
                headers: { Authorization: `Bearer ${token}` },
              });
            },
          });
        }
        url = page?.['@odata.nextLink'] || null;
      }
      return items;
    } catch (error) {
      // Fall through to a quieter empty result when the tenant lacks the API.
      if (error.status === 403 || error.status === 404 || error.status === 400) {
        console.warn('[microsoft_teams] getAllRecordings unavailable:', error.message);
      } else {
        throw error;
      }
    }
  }

  return items;
}

async function verifyAccess(config) {
  if (!config?.accessToken && !config?.refreshToken) {
    throw new Error('Connect Microsoft Teams with OAuth from the Sources screen.');
  }
  return { accountEmail: config.accountEmail || null };
}

module.exports = {
  id: 'microsoft_teams',
  label: 'Microsoft Teams',
  type: 'microsoft_teams',
  verifyIdentity,
  listRecordings,
  verifyAccess,
};
