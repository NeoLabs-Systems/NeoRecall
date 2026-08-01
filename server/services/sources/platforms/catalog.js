'use strict';

// Per-platform metadata and OAuth credentials for meeting cloud sources.
//
// Each platform is a separate source type so a user can connect Google Meet,
// Zoom, and Teams independently. Client IDs/secrets are server-wide (admin
// env); per-user tokens live on the source row after OAuth.

const { getConfig } = require('../../../config');

const PLATFORM_DEFS = {
  google_meet: {
    type: 'google_meet',
    label: 'Google Meet',
    description: 'Import cloud recordings from Google Meet into NeoRecall after each call.',
    auth: 'oauth',
    prerequisites: [
      'Google Workspace account that can record Meet calls',
      'Recordings saved to Google Drive',
      'Server admin has configured Google OAuth client credentials',
    ],
    defaultName: 'Google Meet',
    authorizationUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    // meet.recordings.readonly lists conference recordings; drive.meet.readonly
    // downloads the Meet-produced files without broad Drive access.
    scopes: [
      'openid',
      'email',
      'https://www.googleapis.com/auth/meetings.space.readonly',
      'https://www.googleapis.com/auth/drive.meet.readonly',
    ],
    extraAuthorizeParams: {
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'true',
    },
    usePkce: true,
    envClientId: 'googleMeetOauthClientId',
    envClientSecret: 'googleMeetOauthClientSecret',
  },
  zoom: {
    type: 'zoom',
    label: 'Zoom',
    description: 'Import cloud recordings from your Zoom account after each meeting.',
    auth: 'oauth',
    prerequisites: [
      'Zoom account with cloud recording enabled',
      'Server admin has configured a Zoom OAuth app',
    ],
    defaultName: 'Zoom',
    authorizationUrl: 'https://zoom.us/oauth/authorize',
    tokenUrl: 'https://zoom.us/oauth/token',
    scopes: ['recording:read', 'user:read'],
    extraAuthorizeParams: {},
    usePkce: false,
    envClientId: 'zoomOauthClientId',
    envClientSecret: 'zoomOauthClientSecret',
  },
  microsoft_teams: {
    type: 'microsoft_teams',
    label: 'Microsoft Teams',
    description: 'Import cloud recordings from Microsoft Teams meetings you organize.',
    auth: 'oauth',
    prerequisites: [
      'Microsoft work or school account that can record Teams meetings',
      'Access to meetings you organize (organizer recording permissions)',
      'Server admin has configured a Microsoft Entra OAuth app',
    ],
    defaultName: 'Microsoft Teams',
    // Tenant is filled at runtime from config (common or specific).
    authorizationUrlTemplate: 'https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize',
    tokenUrlTemplate: 'https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token',
    scopes: [
      'offline_access',
      'openid',
      'email',
      'User.Read',
      'OnlineMeetings.Read',
      'OnlineMeetingRecording.Read.All',
    ],
    extraAuthorizeParams: {
      response_mode: 'query',
    },
    usePkce: true,
    envClientId: 'microsoftTeamsOauthClientId',
    envClientSecret: 'microsoftTeamsOauthClientSecret',
    envTenant: 'microsoftTeamsOauthTenant',
  },
};

function resolveProvider(type) {
  const def = PLATFORM_DEFS[type];
  if (!def) return null;
  const config = getConfig();
  const clientId = config[def.envClientId] || null;
  const clientSecret = config[def.envClientSecret] || null;
  const tenant = def.envTenant ? (config[def.envTenant] || 'common') : null;
  const available = Boolean(clientId && clientSecret);

  let authorizationUrl = def.authorizationUrl || null;
  let tokenUrl = def.tokenUrl || null;
  if (def.authorizationUrlTemplate) {
    authorizationUrl = def.authorizationUrlTemplate.replace('{tenant}', encodeURIComponent(tenant || 'common'));
  }
  if (def.tokenUrlTemplate) {
    tokenUrl = def.tokenUrlTemplate.replace('{tenant}', encodeURIComponent(tenant || 'common'));
  }

  return {
    ...def,
    clientId,
    clientSecret,
    tenant,
    authorizationUrl,
    tokenUrl,
    available,
    unavailableReason: available
      ? null
      : 'This platform is not configured on this NeoRecall server. An administrator must set the OAuth client credentials.',
  };
}

function listPlatformDefs() {
  return Object.keys(PLATFORM_DEFS).map((type) => resolveProvider(type));
}

function isMeetingPlatform(type) {
  return Object.prototype.hasOwnProperty.call(PLATFORM_DEFS, type);
}

module.exports = {
  PLATFORM_DEFS,
  resolveProvider,
  listPlatformDefs,
  isMeetingPlatform,
};
