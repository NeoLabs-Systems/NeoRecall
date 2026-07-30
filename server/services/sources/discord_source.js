'use strict';

const { Client } = require('discord.js-selfbot-v13');
const { joinVoiceChannel, EndBehaviorType } = require('@discordjs/voice');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const prism = require('prism-media');
const { getDatabase } = require('../../db/database');
const ingest = require('../ingest/ingest_service');


function ensureDevice(source) {
  const db = getDatabase();
  const deviceId = 'discord-' + source.id;
  const existing = db.prepare('SELECT id FROM devices WHERE id=?').get(deviceId);
  if (!existing) {
    db.prepare(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind)
      VALUES (?, ?, ?, ?, ?, ?)`).run(deviceId, source.user_id, deviceId, 'Discord: ' + source.name, 'discord', 'import');
  }
  return deviceId;
}

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

    
    // User left voice channel
    if (oldState.channelId && !newState.channelId) {
      if (targetUsers.includes(newState.id)) {
        const channel = client.channels.cache.get(oldState.channelId);
        if (channel) {
          const targetsRemaining = channel.members.some(m => targetUsers.includes(m.id) && m.id !== client.user.id);
          if (!targetsRemaining) {
             console.log(`[DiscordSource] All targets left channel ${oldState.channelId}. Disconnecting...`);
             const instance = activeClients.get(source.id);
             if (instance && instance.connection && instance.connection.joinConfig.channelId === oldState.channelId) {
               instance.connection.destroy();
               instance.connection = null;
               if (instance.sessionId) {
                 ingest.closeSession(source.user_id, instance.sessionId, { endedAt: new Date().toISOString() });
                 instance.sessionId = null;
               }
             }
          }
        }
      }
    }

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

    const deviceId = ensureDevice(source);
    const sessionId = crypto.randomUUID();
    instance.sessionId = sessionId;
    
    ingest.createSession(source.user_id, {
      deviceId,
      clientUuid: sessionId,
      startedAt: new Date().toISOString(),
      timezone: 'UTC',
      sources: []
    });

    const activeSources = new Map();
    const receiver = connection.receiver;
    
    receiver.speaking.on('start', (userId) => {
      if (targetUsers.includes(userId)) {
        console.log(`[DiscordSource] Target user ${userId} started speaking. Capturing...`);
        
        let userSource = activeSources.get(userId);
        if (!userSource) {
           const sourceId = crypto.randomUUID();
           ingest.addSource(source.user_id, sessionId, {
             id: sourceId,
             clientUuid: sourceId,
             kind: 'microphone',
             channelLayout: 'stereo',
             sampleRate: 48000,
             sampleFormat: 'f32le',
             metadata: { discordUserId: userId }
           });
           userSource = { id: sourceId, sequence: 0 };
           activeSources.set(userId, userSource);
        }
        
        const audioStream = receiver.subscribe(userId, {
          end: {
            behavior: EndBehaviorType.AfterSilence,
            duration: 1000,
          },
        });
        
        const sequence = userSource.sequence++;
        const tempPath = path.join(os.tmpdir(), `discord-${crypto.randomUUID()}.ogg`);
        const fileStream = fs.createWriteStream(tempPath);
        
        const oggStream = new prism.opus.OggLogicalBitstream({
          opusHead: new prism.opus.OpusHead({ channelCount: 2, sampleRate: 48000 })
        });
        
        const startTime = Date.now();
        audioStream.pipe(oggStream).pipe(fileStream);
        
        fileStream.on('finish', async () => {
           const durationMs = Date.now() - startTime;
           const stat = fs.statSync(tempPath);
           if (stat.size === 0) return;
           
           const hash = crypto.createHash('sha256');
           const fileBuffer = fs.readFileSync(tempPath);
           hash.update(fileBuffer);
           const sha256Hex = hash.digest('hex');
           
           try {
             await ingest.acceptChunk(source.user_id, sessionId, userSource.id, sequence, {
               idempotencyKey: `${sessionId}-${userSource.id}-${sequence}`,
               container: 'ogg',
               codec: 'opus',
               channelLayout: 'stereo',
               deviceStartedAt: new Date(startTime).toISOString(),
               monotonicOffsetMs: 0,
               durationMs,
               overlapMs: 0,
               sha256: sha256Hex
             }, { path: tempPath, size: stat.size });
             console.log(`[DiscordSource] Ingested chunk sequence ${sequence} for user ${userId}`);
           } catch (e) {
             console.error(`[DiscordSource] Failed to ingest chunk for ${userId}:`, e.message);
           }
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
