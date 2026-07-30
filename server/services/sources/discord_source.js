'use strict';

const { Client } = require('discord.js-selfbot-v13');
const { joinVoiceChannel, EndBehaviorType, createAudioPlayer, createAudioResource, StreamType, VoiceConnectionStatus } = require('@discordjs/voice');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const prism = require('prism-media');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const ingest = require('../ingest/ingest_service');

// Upper bound for how long a single speaking burst may hold the per-user
// capture guard before it is force-released. Derived from the configured
// maximum chunk length plus headroom for decode/transcode drain.
const CAPTURE_WATCHDOG_MS = getConfig().chunkMaxMs + 30_000;

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

    try {
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
    } catch (e) {
      console.error('[DiscordSource] Error in voiceStateUpdate:', e);
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
      selfMute: false,
      // Selfbots cannot complete Discord's DAVE (E2EE/MLS) key exchange. With DAVE
      // enabled, incoming voice packets are E2EE-decrypted to null and silently
      // dropped by @discordjs/voice, so no audio ever reaches the pipeline. Disabling
      // it advertises max_dave_protocol_version: 0 and falls back to transport-only
      // decryption, which works with the negotiated secret_key.
      daveEncryption: false,
    });
    // Play silence to satisfy Discord's UDP receive requirements
    const player = createAudioPlayer();
    const { Readable } = require('stream');
    class Silence extends Readable {
      _read() {
        this.push(Buffer.alloc(960 * 2 * 2));
      }
    }
    const resource = createAudioResource(new Silence(), { inputType: StreamType.Raw });
    player.play(resource);
    connection.subscribe(player);
  

    instance.connection = connection;
    console.log(`[DiscordSource] Joined voice channel ${voiceState.channelId}`);

    // Diagnostic: surface the voice connection lifecycle so we can tell whether the
    // UDP/encryption handshake actually reaches Ready (required before any audio flows).
    connection.on('stateChange', (oldS, newS) => {
      console.log(`[DiscordSource] Connection state: ${oldS.status} -> ${newS.status}`);
    });
    connection.on('error', (err) => {
      console.error(`[DiscordSource] Connection error:`, err.message);
    });
    connection.on(VoiceConnectionStatus.Ready, () => {
      console.log(`[DiscordSource] Voice connection READY (handshake complete, audio can flow).`);
    });

    const deviceId = ensureDevice(source);
    const sessionId = crypto.randomUUID();
    instance.sessionId = sessionId;
    
    ingest.createSession(source.user_id, {
      deviceId,
      clientUuid: sessionId,
      startedAt: new Date().toISOString(),
      timezone: 'UTC',
      consentAttestedAt: new Date().toISOString(),
      sources: []
    });

    const activeSources = new Map();
    const activeStreams = new Map();
    const receiver = connection.receiver;
    
    receiver.speaking.on('start', (userId) => {
      try {
        if (targetUsers.includes(userId)) {
          if (activeStreams.has(userId)) return; // Already capturing for this user!

          // Watchdog: if the pipeline never invokes its callback (e.g. a hung
          // ffmpeg/decoder), the capture guard would otherwise stay set forever
          // and this speaker would never be recorded again for the session.
          // Clearing it after a bounded ceiling fails safe toward re-capture.
          const guardTimeout = setTimeout(() => {
            if (activeStreams.has(userId)) {
              console.warn(`[DiscordSource] Capture watchdog fired for user ${userId}; releasing guard.`);
              activeStreams.delete(userId);
            }
          }, CAPTURE_WATCHDOG_MS);
          if (typeof guardTimeout.unref === 'function') guardTimeout.unref();
          activeStreams.set(userId, guardTimeout);

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

          // Diagnostic: count opus packets actually delivered to us. If DAVE were still
          // dropping them this stays at 0; a non-zero count proves audio is flowing.
          let packetCount = 0;
          audioStream.on('data', () => { packetCount++; });
          audioStream.on('end', () => {
            console.log(`[DiscordSource] Receive stream ended for ${userId} after ${packetCount} opus packet(s).`);
          });
          audioStream.on('error', (err) => {
            console.error(`[DiscordSource] Receive stream error for ${userId}:`, err.message);
          });

          const sequence = userSource.sequence++;
          const tempPath = path.join(os.tmpdir(), `discord-${crypto.randomUUID()}.wav`);
          const fileStream = fs.createWriteStream(tempPath);
          
                    try {
            const decoder = new prism.opus.Decoder({ frameSize: 960, channels: 2, rate: 48000 });
            // NOTE: prism.FFmpeg auto-appends 'pipe:1' as the output (see
            // prism-media core/FFmpeg.js create()). Do NOT add 'pipe:1' here or the
            // command gets two outputs ('-f wav pipe:1 pipe:1'); the second has no
            // format, ffmpeg exits, and every chunk dies with `write EPIPE`.
            const encoder = new prism.FFmpeg({
              args: [
                '-f', 's16le', '-ar', '48000', '-ac', '2',
                '-i', 'pipe:0',
                '-f', 'wav'
              ]
            });
            
            const startTime = Date.now();
            const { pipeline } = require('stream');

            pipeline(audioStream, decoder, encoder, fileStream, async (err) => {
              try {
               if (err) {
                 console.error(`[DiscordSource] Pipeline error for ${userId}:`, err.message);
                 if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
                 return;
               }
               
               const durationMs = Date.now() - startTime;
               if (!fs.existsSync(tempPath)) return;
               const stat = fs.statSync(tempPath);
               if (stat.size === 0) {
                 console.log(`[DiscordSource] Audio file size was 0 for user ${userId}. Discarding.`);
                 fs.unlinkSync(tempPath);
                 return;
               }
               
               const hash = crypto.createHash('sha256');
               const fileBuffer = fs.readFileSync(tempPath);
               hash.update(fileBuffer);
               const sha256Hex = hash.digest('hex');
               
               try {
                 await ingest.acceptChunk(source.user_id, sessionId, userSource.id, sequence, {
                   idempotencyKey: `${sessionId}-${userSource.id}-${sequence}`,
                   container: 'wav',
                   codec: 'pcm_s16le',
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
              } finally {
                clearTimeout(guardTimeout);
                activeStreams.delete(userId);
              }
            });
          } catch (err) {
            console.error(`[DiscordSource] Error creating pipeline:`, err);
            clearTimeout(guardTimeout);
            activeStreams.delete(userId);
          }
        }
      } catch (err) {
        console.error(`[DiscordSource] Uncaught error in speaking listener:`, err);
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
