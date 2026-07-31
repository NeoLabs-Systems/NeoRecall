'use strict';

const GoogleMeetBot = require('./meeting_bot/GoogleMeetBot');
const ZoomBot = require('./meeting_bot/ZoomBot');
const TeamsBot = require('./meeting_bot/TeamsBot');

const activeBots = new Map();

function getBotClassForUrl(urlStr) {
  try {
    const url = new URL(urlStr);
    if (url.hostname.includes('meet.google.com')) {
      return GoogleMeetBot;
    } else if (url.hostname.includes('zoom.us')) {
      return ZoomBot;
    } else if (url.hostname.includes('teams.microsoft.com') || url.hostname.includes('teams.live.com')) {
      return TeamsBot;
    }
  } catch (e) {}
  return null;
}

// The source row is the only place a failure is visible to the user, and these
// writes run from event handlers — a throw here (typically "Source not found"
// after the row was already removed) must not escape into the emitter.
function recordFailure(source, code, message) {
  try {
    require('./index').update(source.user_id, source.id, {
      enabled: false,
      config: { ...source.config, error: message, errorCode: code, erroredAt: new Date().toISOString() },
    });
  } catch (error) {
    console.error(`[MeetingSource] Could not record the failure for ${source.id}:`, error.message);
  }
}

function recordJoined(source) {
  try {
    // update() merges config, so a previous failure has to be cleared by name.
    require('./index').update(source.user_id, source.id, {
      config: { error: null, errorCode: null, erroredAt: null, joinedAt: new Date().toISOString() },
    });
  } catch (error) {
    console.error(`[MeetingSource] Could not record the join for ${source.id}:`, error.message);
  }
}

// A meeting link is a one-shot job: once the call is over the link is spent, so
// the source is retired and the user can add the next one.
function retireSource(source) {
  try {
    require('./index').delete(source.user_id, source.id);
  } catch (error) {
    console.error(`[MeetingSource] Could not retire ${source.id}:`, error.message);
  }
}

const PLATFORM_LABELS = new Map([
  [GoogleMeetBot, 'Google Meet'],
  [ZoomBot, 'Zoom'],
  [TeamsBot, 'Microsoft Teams'],
]);

const meetingSourceService = {
  // Called before the source is stored, so an unusable link is rejected in the
  // setup dialog rather than failing silently in the background minutes later.
  async verifyAccess(config) {
    const url = String((config && config.url) || '').trim();
    if (!url) throw new Error('A meeting link is required.');
    const BotClass = getBotClassForUrl(url);
    if (!BotClass) throw new Error('That link is not a Google Meet, Zoom or Microsoft Teams meeting URL.');
    return { platform: PLATFORM_LABELS.get(BotClass) };
  },

  async startSource(source) {
    if (activeBots.has(source.id)) {
      return; // Already running
    }

    if (!source.enabled || !source.config.url) return;

    const url = source.config.url;
    const BotClass = getBotClassForUrl(url);

    if (!BotClass) {
      console.error(`[MeetingSource] Unsupported meeting URL: ${url}`);
      recordFailure(source, 'unsupported_url', 'That link is not a Google Meet, Zoom or Microsoft Teams meeting URL.');
      return;
    }

    const botName = source.name || 'NeoRecall Notetaker';
    const bot = new BotClass(source.user_id, source.id, botName, url);
    activeBots.set(source.id, bot);

    // 'ended' fires exactly once per bot, from stop(). It only means "the call
    // is over" when the bot got in; a bot that never joined reports its reason
    // through the catch below instead.
    bot.once('ended', () => {
      activeBots.delete(source.id);
      console.log(`[MeetingSource] Bot finished for source ${source.id}`);
      if (bot.hasJoined) retireSource(source);
    });

    try {
      await bot.start();
      console.log(`[MeetingSource] Bot started for source ${source.id}`);
      recordJoined(source);
    } catch (error) {
      console.error(`[MeetingSource] Failed to start bot for ${source.id}:`, error && error.stack ? error.stack : error);
      activeBots.delete(source.id);
      recordFailure(source, error.code || 'join_failed', error.message);
    }
  },

  async stopSource(sourceId) {
    const bot = activeBots.get(sourceId);
    if (!bot) return;
    // Drop the reference first: stop() emits 'ended', and a bot still in the map
    // at that point would be stopped a second time from its own handler.
    activeBots.delete(sourceId);
    await bot.stop();
    console.log(`[MeetingSource] Stopped bot for source ${sourceId}`);
  },
};

module.exports = meetingSourceService;
