'use strict';

const DiscordVoiceBot = require('./discord_bot/discord_voice_bot');

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
      console.log(`[DiscordSource] Started source ${source.id}`);
    } catch (error) {
      console.error(`[DiscordSource] Failed to start source ${source.id}:`, error.message);
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
      console.log(`[DiscordSource] Stopped source ${sourceId}`);
    }
  },
};

module.exports = discordSourceService;
