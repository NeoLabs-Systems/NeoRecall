'use strict';

const { Client } = require('discord.js-selfbot-v13');
const { joinVoiceChannel, EndBehaviorType } = require('@discordjs/voice');
const crypto = require('crypto');

const activeClients = new Map(); // id -> { client, connection }

async function startSource(source) {
  if (activeClients.has(source.id)) {
    await stopSource(source.id);
  }

  if (!source.enabled || !source.config.token) return;

  const client = new Client({ checkUpdate: false, patchVoice: true });
  const targetUsers = (source.config.targetUsers || '').split(',').map(s => s.trim()).filter(Boolean);
  
  if (targetUsers.length === 0) return;

  client.on('ready', () => {
    console.log(`[DiscordSource] Selfbot started for source ${source.id} as ${client.user.tag}`);
  });

  client.on('voiceStateUpdate', (oldState, newState) => {
    if (newState.id === client.user.id) return; // Ignore self
    if (!targetUsers.includes(newState.id)) return; // Only target users

    // User joined or moved to a voice channel
    if (newState.channelId && oldState.channelId !== newState.channelId) {
      console.log(`[DiscordSource] Target user ${newState.id} joined channel ${newState.channelId}. Joining in 2 seconds...`);
      setTimeout(() => {
        joinAndRecord(client, newState, source, targetUsers);
      }, 2000);
    }
  });

  client.on('callCreate', async (call) => {
    try {
      const channel = call.channel || await client.channels.fetch(call.channelId);
      if (!channel) return;
      
      let isTarget = false;
      if (channel.type === 'DM' && channel.recipientId) {
        isTarget = targetUsers.includes(channel.recipientId);
      } else if (channel.type === 'GROUP_DM' && channel.recipients) {
        isTarget = channel.recipients.some(id => targetUsers.includes(id));
      }
      
      if (isTarget) {
         console.log(`[DiscordSource] Incoming call from target in channel ${channel.id}. Answering...`);
         setTimeout(() => {
           const mockVoiceState = {
             channelId: channel.id,
             guild: {
               id: channel.id, // @discordjs/voice expects a guildId, use channel id for DMs
               voiceAdapterCreator: channel.voiceAdapterCreator
             }
           };
           joinAndRecord(client, mockVoiceState, source, targetUsers);
         }, 1000);
      }
    } catch (error) {
      console.error(`[DiscordSource] Error handling callCreate:`, error.message);
    }
  });

  try {
    await client.login(source.config.token);
    activeClients.set(source.id, { client, connection: null });
  } catch (error) {
    console.error(`[DiscordSource] Failed to login Discord bot for source ${source.id}:`, error.message);
    const sourcesService = require('./index');
    sourcesService.update(source.user_id, source.id, {
      enabled: false,
      config: { ...source.config, error: 'Login failed: ' + error.message }
    });
  }
}

async function stopSource(sourceId) {
  const instance = activeClients.get(sourceId);
  if (instance) {
    if (instance.connection) {
      instance.connection.destroy();
    }
    instance.client.destroy();
    activeClients.delete(sourceId);
    console.log(`[DiscordSource] Stopped source ${sourceId}`);
  }
}

async function joinAndRecord(client, voiceState, source, targetUsers) {
  const instance = activeClients.get(source.id);
  if (!instance) return;

  try {
    const connection = joinVoiceChannel({
      channelId: voiceState.channelId,
      guildId: voiceState.guild.id,
      adapterCreator: voiceState.guild.voiceAdapterCreator,
      selfDeaf: false,
      selfMute: true,
    });

    instance.connection = connection;
    console.log(`[DiscordSource] Joined voice channel ${voiceState.channelId}`);

    const receiver = connection.receiver;
    
    receiver.speaking.on('start', (userId) => {
      if (targetUsers.includes(userId)) {
        console.log(`[DiscordSource] Target user ${userId} started speaking. Capturing...`);
        const audioStream = receiver.subscribe(userId, {
          end: {
            behavior: EndBehaviorType.AfterSilence,
            duration: 1000,
          },
        });
        
        // TODO: Pipe audioStream to NeoRecall's internal ingest_service
        // For now, we simulate the hook since the full ingest device mock is complex
        let byteCount = 0;
        audioStream.on('data', chunk => { byteCount += chunk.length; });
        audioStream.on('end', () => {
           console.log(`[DiscordSource] Captured ${byteCount} bytes from user ${userId}.`);
        });
      }
    });

  } catch (error) {
    console.error(`[DiscordSource] Failed to join voice channel:`, error.message);
  }
}

module.exports = {
  startSource,
  stopSource
};
