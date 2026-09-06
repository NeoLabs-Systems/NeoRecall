'use strict';

const crypto = require('crypto');
const fs = require('fs');
const {
  Client,
  GatewayIntentBits,
  Events,
} = require('discord.js');
const {
  joinVoiceChannel,
  createAudioPlayer,
  EndBehaviorType,
  VoiceConnectionStatus,
  entersState,
} = require('@discordjs/voice');

const { getDatabase } = require('../../../db/database');
const ingest = require('../../ingest/ingest_service');
const { createLogger } = require('../../../utils/logger');
const {
  SAMPLE_RATE,
  WAV_HEADER_BYTES,
  opusStreamToWav,
  createSilenceResource,
  hashFile,
} = require('./audio_pipeline');

const logger = createLogger('sources.discord-bot');

// Discord treats a speaker as "stopped" after a gap; capture ends this long
// after the last packet, closing out one utterance into one chunk.
const SILENCE_END_MS = 1000;
// How long to wait for the voice handshake before giving up on a join.
const READY_TIMEOUT_MS = 20000;

/**
 * Drives a single Discord "source": logs in a bot, follows the configured
 * trigger user(s) into voice channels, and records EVERY speaker in the channel
 * through the ingest pipeline as WAV chunks. One instance owns one source.
 *
 * "Trigger" users are matched by username (not id): when one joins a voice
 * channel the bot joins too, and it leaves once the last trigger user is gone.
 */
class DiscordVoiceBot {
  /**
   * @param {object} source Source row: `{ id, user_id, name, config: { token, triggerUsernames } }`.
   *   `config.targetUsers` is accepted as a legacy alias for `triggerUsernames`.
   */
  constructor(source) {
    this.source = source;
    this.ownerUserId = source.user_id;
    this.triggerUsernames = parseUsernames(source.config.triggerUsernames ?? source.config.targetUsers);

    this.client = null;
    this.connection = null;
    this.silencePlayer = null;

    // Ingest session state, established on first join and torn down on leave.
    this.deviceId = null;
    this.sessionId = null;
    /** @type {Map<string, { id: string, sequence: number }>} discordUserId -> ingest source */
    this.ingestSources = new Map();
    /** @type {Set<string>} discordUserIds with an in-flight capture */
    this.capturing = new Set();
  }

  /**
   * Log the bot in and wire up voice tracking. Rejects if the token is invalid
   * so the caller can surface the failure; resolves once logged in.
   */
  async start() {
    if (!this.source.config.token) throw new Error('Missing bot token');
    if (this.triggerUsernames.length === 0) throw new Error('No trigger usernames configured');

    const client = new Client({
      intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates],
    });
    this.client = client;

    client.once(Events.ClientReady, (readyClient) => {
      logger.info('Logged in', { botTag: readyClient.user.tag, sourceId: this.source.id });
      this._followExistingTriggers();
    });
    client.on(Events.VoiceStateUpdate, (oldState, newState) => this._onVoiceStateUpdate(oldState, newState));
    client.on(Events.Error, (error) => logger.error('Client error', { sourceId: this.source.id, error }));

    await client.login(this.source.config.token);
  }

  /**
   * Tear everything down: close any open ingest session, leave voice, and
   * destroy the gateway client. Safe to call multiple times.
   */
  async stop() {
    this._endSession();
    this._leaveVoice();
    if (this.client) {
      try {
        this.client.destroy();
      } catch (error) {
        logger.error('Error destroying client', { sourceId: this.source.id, error });
      }
      this.client = null;
    }
  }

  // --- Voice channel following ------------------------------------------------

  /**
   * True if a guild member is one of the configured trigger users, matched
   * case-insensitively against username, global (display) name, or nickname.
   */
  _memberIsTrigger(member) {
    if (!member) return false;
    const candidates = [member.user && member.user.username, member.user && member.user.globalName, member.nickname]
      .filter(Boolean)
      .map((value) => value.toLowerCase());
    return candidates.some((candidate) => this.triggerUsernames.includes(candidate));
  }

  /**
   * On startup a trigger user may already be sitting in a voice channel (no
   * voiceStateUpdate will fire for them), so join the first one we find.
   */
  _followExistingTriggers() {
    for (const guild of this.client.guilds.cache.values()) {
      for (const voiceState of guild.voiceStates.cache.values()) {
        if (voiceState.channelId && this._memberIsTrigger(voiceState.member)) {
          this._joinAndRecord(voiceState.channel);
          return;
        }
      }
    }
  }

  _onVoiceStateUpdate(oldState, newState) {
    if (this.client && newState.id === this.client.user.id) return; // Ignore ourselves.

    try {
      const joinedOrMoved = newState.channelId && newState.channelId !== oldState.channelId;
      const left = oldState.channelId && !newState.channelId;

      if (joinedOrMoved && this._memberIsTrigger(newState.member)) {
        this._joinAndRecord(newState.channel);
      } else if (left && this._memberIsTrigger(oldState.member)) {
        const channel = oldState.channel || this.client.channels.cache.get(oldState.channelId);
        this._onTriggerLeft(channel);
      }
    } catch (error) {
      logger.error('voiceStateUpdate handling failed', { sourceId: this.source.id, error });
    }
  }

  async _joinAndRecord(channel) {
    if (!channel) return;
    // Already connected to this exact channel: nothing to do.
    if (this.connection && this.connection.joinConfig.channelId === channel.id) return;
    // Following a trigger user who moved channels: drop the old connection first.
    if (this.connection) this._leaveVoice();

    const connection = joinVoiceChannel({
      channelId: channel.id,
      guildId: channel.guild.id,
      adapterCreator: channel.guild.voiceAdapterCreator,
      selfDeaf: false, // Must be able to hear to receive audio.
      selfMute: false, // Must transmit (silence) for Discord to send us packets.
      // This bot only listens and transcribes. Disabling DAVE (E2EE) keeps
      // inbound packets on transport-only decryption; with DAVE enabled they
      // would decrypt to null and be silently dropped.
      daveEncryption: false,
    });
    this.connection = connection;

    connection.on('error', (error) => logger.error('Voice connection error', { sourceId: this.source.id, error }));
    connection.on(VoiceConnectionStatus.Disconnected, () => this._handleDisconnect(connection));

    try {
      await entersState(connection, VoiceConnectionStatus.Ready, READY_TIMEOUT_MS);
    } catch (error) {
      logger.error('Voice connection never became ready', { channelId: channel.id, error });
      if (this.connection === connection) this._leaveVoice();
      return;
    }

    // Discord only delivers inbound audio while we are transmitting.
    this.silencePlayer = createAudioPlayer();
    this.silencePlayer.play(createSilenceResource());
    connection.subscribe(this.silencePlayer);

    logger.info('Recording voice channel', { channelId: channel.id, channelName: channel.name });
    this._startSession();
    this._attachReceiver(connection);
  }

  _onTriggerLeft(channel) {
    if (!this.connection || !channel) return;
    if (channel.id !== this.connection.joinConfig.channelId) return;

    const triggerRemaining = channel.members.some((member) => this._memberIsTrigger(member));
    if (triggerRemaining) return;

    logger.info('All trigger users left; disconnecting', { channelId: channel.id });
    this._leaveVoice();
    this._endSession();
  }

  async _handleDisconnect(connection) {
    // A disconnect may be a transient move; give it a moment to recover before
    // tearing down, matching @discordjs/voice's recommended pattern.
    try {
      await Promise.race([
        entersState(connection, VoiceConnectionStatus.Signalling, 5000),
        entersState(connection, VoiceConnectionStatus.Connecting, 5000),
      ]);
    } catch (error) {
      if (this.connection === connection) {
        this._leaveVoice();
        this._endSession();
      }
    }
  }

  _leaveVoice() {
    if (this.silencePlayer) {
      try {
        this.silencePlayer.stop();
      } catch (error) {
        /* ignore */
      }
      this.silencePlayer = null;
    }
    if (this.connection) {
      try {
        this.connection.destroy();
      } catch (error) {
        /* connection may already be destroyed */
      }
      this.connection = null;
    }
  }

  // --- Per-speaker capture (everyone in the channel) --------------------------

  _attachReceiver(connection) {
    const receiver = connection.receiver;
    receiver.speaking.on('start', (discordUserId) => {
      if (this.client && discordUserId === this.client.user.id) return; // Never record ourselves.
      this._captureSpeaker(receiver, discordUserId);
    });
  }

  async _captureSpeaker(receiver, discordUserId) {
    // One capture per speaker at a time; the receiver re-fires 'start' for the
    // same user, and re-subscribing would fork the same audio.
    if (this.capturing.has(discordUserId)) return;
    if (!this.sessionId) return; // Session was torn down; drop late events.
    this.capturing.add(discordUserId);

    const ingestSource = this._ensureIngestSource(discordUserId);
    const sequence = ingestSource.sequence++;
    const startedAt = Date.now();

    const opusStream = receiver.subscribe(discordUserId, {
      end: { behavior: EndBehaviorType.AfterSilence, duration: SILENCE_END_MS },
    });

    try {
      const { path: wavPath, size } = await opusStreamToWav(opusStream);

      if (size <= WAV_HEADER_BYTES) {
        await fs.promises.unlink(wavPath).catch(() => {});
        return;
      }

      const durationMs = Date.now() - startedAt;
      const sha256 = await hashFile(wavPath);

      // ingest.acceptChunk takes ownership of the file (moves it into place).
      await ingest.acceptChunk(
        this.ownerUserId,
        this.sessionId,
        ingestSource.id,
        sequence,
        {
          idempotencyKey: `${this.sessionId}-${ingestSource.id}-${sequence}`,
          container: 'wav',
          codec: 'pcm_s16le',
          channelLayout: 'stereo',
          deviceStartedAt: new Date(startedAt).toISOString(),
          monotonicOffsetMs: 0,
          durationMs,
          overlapMs: 0,
          sha256,
        },
        { path: wavPath, size },
      );
      logger.debug('Ingested chunk', { sequence, speaker: this._describeUser(discordUserId), durationMs });
    } catch (error) {
      logger.error('Capture failed', { discordUserId, error });
    } finally {
      this.capturing.delete(discordUserId);
    }
  }

  _ensureIngestSource(discordUserId) {
    let ingestSource = this.ingestSources.get(discordUserId);
    if (!ingestSource) {
      const id = crypto.randomUUID();
      ingest.addSource(this.ownerUserId, this.sessionId, {
        id,
        clientUuid: id,
        kind: 'microphone',
        channelLayout: 'stereo',
        sampleRate: SAMPLE_RATE,
        sampleFormat: 's16le',
        metadata: { discordUserId, discordUsername: this._resolveUsername(discordUserId) },
      });
      ingestSource = { id, sequence: 0 };
      this.ingestSources.set(discordUserId, ingestSource);
    }
    return ingestSource;
  }

  /** Best-effort username for a speaker from the gateway cache (may be null). */
  _resolveUsername(discordUserId) {
    const user = this.client && this.client.users.cache.get(discordUserId);
    return user ? user.username : null;
  }

  _describeUser(discordUserId) {
    const username = this._resolveUsername(discordUserId);
    return username ? `${username} (${discordUserId})` : discordUserId;
  }

  // --- Ingest session lifecycle ----------------------------------------------

  _startSession() {
    if (this.sessionId) return; // Already recording.
    this.deviceId = ensureDevice(this.source);
    this.sessionId = crypto.randomUUID();
    this.ingestSources.clear();
    ingest.createSession(this.ownerUserId, {
      deviceId: this.deviceId,
      clientUuid: this.sessionId,
      startedAt: new Date().toISOString(),
      timezone: 'UTC',
      consentAttestedAt: new Date().toISOString(),
      sources: [],
    });
  }

  _endSession() {
    if (!this.sessionId) return;
    try {
      ingest.closeSession(this.ownerUserId, this.sessionId, { endedAt: new Date().toISOString() });
    } catch (error) {
      logger.error('Failed to close session', { sourceId: this.source.id, error });
    }
    this.sessionId = null;
    this.ingestSources.clear();
    this.capturing.clear();
  }
}

/**
 * Ensure a `devices` row exists for this source and return its id. The device
 * anchors every ingest session created for the source.
 */
function ensureDevice(source) {
  const db = getDatabase();
  const deviceId = `discord-${source.id}`;
  const existing = db.prepare('SELECT id FROM devices WHERE id = ?').get(deviceId);
  if (!existing) {
    db.prepare(
      `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(deviceId, source.user_id, deviceId, `Discord: ${source.name}`, 'discord', 'import');
  }
  return deviceId;
}

/** Parse a comma-separated username list into a lowercased, '@'-stripped array. */
function parseUsernames(raw) {
  return (raw || '')
    .split(',')
    .map((value) => value.trim().replace(/^@/, '').toLowerCase())
    .filter(Boolean);
}

module.exports = DiscordVoiceBot;
