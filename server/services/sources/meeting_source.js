'use strict';

const crypto = require('crypto');
const { getDatabase } = require('../../db/database');
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

const meetingSourceService = {
  async startSource(source) {
    if (activeBots.has(source.id)) {
      return; // Already running
    }

    if (!source.enabled || !source.config.url) return;

    const url = source.config.url;
    const BotClass = getBotClassForUrl(url);

    if (!BotClass) {
      console.error(`[MeetingSource] Unsupported meeting URL: ${url}`);
      return;
    }

    const botName = source.name || 'NeoRecall Notetaker';
    const bot = new BotClass(source.user_id, source.id, botName, url);
    activeBots.set(source.id, bot);

    try {
      await bot.start();
      console.log(`[MeetingSource] Bot started for source ${source.id}`);
      
      bot.on('ended', () => {
         console.log(`[MeetingSource] Bot finished for source ${source.id}`);
         meetingSourceService.stopSource(source.id);
         const sourcesService = require('./index');
         sourcesService.delete(source.user_id, source.id);
      });

    } catch (error) {
      console.error(`[MeetingSource] Failed to start bot for ${source.id}:`, error.message);
      activeBots.delete(source.id);
      const sourcesService = require('./index');
      sourcesService.update(source.user_id, source.id, {
        enabled: false,
        config: { ...source.config, error: 'Failed to join: ' + error.message }
      });
    }
  },

  async stopSource(sourceId) {
    const bot = activeBots.get(sourceId);
    if (bot) {
      await bot.stop();
      activeBots.delete(sourceId);
      console.log(`[MeetingSource] Stopped bot for source ${sourceId}`);
    }
  }
};

module.exports = meetingSourceService;
