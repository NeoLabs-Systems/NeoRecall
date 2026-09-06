'use strict';

const DiscordVoiceBot = require('./discord_bot/discord_voice_bot');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('sources.discord');

// One running bot per source id.
const activeBots = new Map();

const discordSourceService = {
  async startSource(source) {
    // Restart cleanly if the source is reconfigured while running.
    if (activeBots.has(source.id)) {
      await this.stopSource(source.id);
    }

    if (!source.enabled || !source.config.token) return;

    const bot = new DiscordVoiceBot(source);
    activeBots.set(source.id, bot);

    try {
      await bot.start();
      logger.info('Started source', { sourceId: source.id });
    } catch (error) {
      logger.error('Failed to start source', { sourceId: source.id, error });
      activeBots.delete(source.id);
      try {
        await bot.stop();
      } catch (stopError) {
        /* best-effort cleanup */
      }
      // Disable the source and surface the reason so the UI can show it.
      const sourcesService = require('./index');
      sourcesService.update(source.user_id, source.id, {
        enabled: false,
        config: { ...source.config, error: `Login failed: ${error.message}` },
      });
    }
  },

  async stopSource(sourceId) {
    const bot = activeBots.get(sourceId);
    if (bot) {
      await bot.stop();
      activeBots.delete(sourceId);
      logger.info('Stopped source', { sourceId });
    }
  },
};

module.exports = discordSourceService;
