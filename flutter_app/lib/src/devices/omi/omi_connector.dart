import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import 'base_connector.dart';
import 'device_models.dart';
import 'offline_audio.dart';
import 'offline_sync.dart';
import 'ring_protocol.dart';

class OmiConnector extends WearableConnector with WearableOfflineSync {
  OmiConnector({required super.device, required super.transport});

  // Null until the device reports its codec on connect; reads fall back to
  // the hardware-accurate default rather than a stale PCM8 guess.
  WearableAudioCodec? _codec;

  // Last observed ring-buffer facts, reported through [syncDiagnostics] so a
  // drain that yields nothing can be told apart from one that never ran.
  bool _storageReadable = false;
  int _lastUnreadPackets = -1;
  int _lastFrameCount = 0;
  int _lastDoneStatus = -1;
  bool _decoderAvailable = true;

  /// Completer of the drain currently awaiting NOTIFY_DONE, so an abort or a
  /// teardown can end the wait locally instead of hanging on its timeout.
  Completer<DoneNotification?>? _activeDrain;

  // A full ring can take minutes to transfer, so progress is published rather
  // than left to an indeterminate spinner.
  final StreamController<WearableSyncProgress> _progress =
      StreamController<WearableSyncProgress>.broadcast();
  int _packetsTransferred = 0;
  int _packetsExpected = 0;
  int _lastPendingBytes = 0;

  /// Seconds of audio a single 444-byte ring packet represents.
  ///
  /// Measured on real hardware rather than derived: a full drain of a live Omi
  /// delivered 30 249 packets that decoded to 131 012 opus frames, i.e. 2 620 s
  /// of audio at 20 ms per frame -> 0.0866 s per packet. (Computing it from the
  /// 440-byte payload and the ~90-byte mean frame would give 0.097 and overstate
  /// the estimate, because it ignores the zero padding at the end of a record.)
  static const double _secondsPerPacket = 0.0866;

  @override
  Stream<WearableSyncProgress> get syncProgress => _progress.stream;

  @override
  Future<WearableSyncProgress?> peekPending() async {
    try {
      final raw = await transport.readCharacteristic(
        WearableDeviceUuids.omiStorageService,
        WearableDeviceUuids.omiStorageControl,
      );
      final status = RingProtocol.parseStatus(raw);
      if (status == null) return null;
      return WearableSyncProgress(
        pendingSeconds: (status.unreadPackets * _secondsPerPacket).round(),
      );
    } catch (_) {
      return null; // no on-board storage on this model
    }
  }

  void _publishProgress() {
    if (_progress.isClosed) return;
    _progress.add(
      WearableSyncProgress(
        transferred: _packetsTransferred,
        total: _packetsExpected,
        pendingSeconds:
            ((_packetsExpected - _packetsTransferred).clamp(0, 1 << 31) *
                    _secondsPerPacket)
                .round(),
      ),
    );
  }

  /// Codec assumed when the device's codec characteristic cannot be read.
  ///
  /// Opus FS320, not PCM8: Omi ships Opus by default since fw 1.0.3 and every
  /// real unit measured against this code reported id 21. Assuming PCM8 would
  /// decode an Opus stream as raw samples — audible noise instead of speech.
  WearableAudioCodec get fallbackCodec => WearableAudioCodec.opusFs320;

  @override
  WearableAudioCodec get codec => _codec ?? fallbackCodec;

  @override
  Future<void> onConnected() async {
    await _syncTime();
    _codec = await _readCodec();
    try {
      final level = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (level.isNotEmpty) batteryLevels.add(level.first);
    } catch (error) {
      _noteOptionalCharacteristic('battery_read', error);
    }
    try {
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.batteryService,
          WearableDeviceUuids.batteryLevel,
        )).listen((value) {
          if (value.isNotEmpty) batteryLevels.add(value.first);
        }),
      );
    } catch (error) {
      _noteOptionalCharacteristic('battery_subscribe', error);
    }
    try {
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.buttonService,
          WearableDeviceUuids.buttonTrigger,
        )).listen((value) {
          if (value.isNotEmpty) buttonEvents.add(value);
        }),
      );
    } catch (error) {
      _noteOptionalCharacteristic('button_subscribe', error);
    }
  }

  Future<void> _syncTime() async {
    // Only some Omi models/firmware expose the time-sync service; skip the write
    // entirely when it is absent instead of issuing a doomed request.
    if (!transport.hasCharacteristic(
      WearableDeviceUuids.timeSyncService,
      WearableDeviceUuids.timeSyncWrite,
    )) {
      return;
    }
    try {
      final epochSeconds =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final bytes = ByteData(4)..setUint32(0, epochSeconds, Endian.little);
      await transport.writeCharacteristic(
        WearableDeviceUuids.timeSyncService,
        WearableDeviceUuids.timeSyncWrite,
        bytes.buffer.asUint8List(),
      );
    } catch (error) {
      _noteOptionalCharacteristic('time_sync_write', error);
    }
  }

  /// Reads the device's audio codec.
  ///
  /// Guessing wrong here does not fail loudly — it decodes the stream with the
  /// wrong codec and yields noise — so an unreadable or unrecognised value is
  /// logged rather than silently swallowed, and [fallbackCodec] deliberately
  /// matches what real hardware reports (Omi has shipped Opus by default since
  /// fw 1.0.3; every unit measured here reported id 21 / opusFS320).
  Future<WearableAudioCodec> _readCodec() async {
    Object? failure;
    int? codecId;
    try {
      final value = await transport.readCharacteristic(
        WearableDeviceUuids.omiService,
        WearableDeviceUuids.omiAudioCodec,
      );
      if (value.isNotEmpty) {
        codecId = value.first;
        switch (codecId) {
          case 1:
            return WearableAudioCodec.pcm8;
          case 20:
            return WearableAudioCodec.opus;
          case 21:
            return WearableAudioCodec.opusFs320;
        }
      }
    } catch (error) {
      failure = error;
    }
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      'omi_codec_unresolved',
      level: 'warning',
      details: <String, Object?>{
        'codecId': codecId,
        'error': failure?.toString(),
        'assumed': fallbackCodec.name,
      },
    );
    return fallbackCodec;
  }

  @override
  Future<int> readBatteryLevel() async {
    try {
      final value = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      return value.isNotEmpty ? value.first : -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    trackRecording(
      (await transport.characteristicStream(
        WearableDeviceUuids.omiService,
        WearableDeviceUuids.omiAudioData,
      )).listen((value) {
        if (value.isNotEmpty) audioBytes.add(value);
      }),
    );
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    await cancelRecordingSubscriptions();
    recording = false;
  }

  // --- Offline ring-buffer drain (WearableOfflineSync) ---

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    // Omi keeps live audio on its audio characteristic and the ring on a
    // separate storage characteristic, so a drain may run *during* live capture:
    // an always-on pendant should not have to choose between streaming now and
    // recovering what it recorded while the phone was away. The two paths never
    // share a buffer, so there is nothing to cross-feed.
    // Probe on-board storage by READING the ring status characteristic
    // (30295782), exactly as the official Omi app does. This is more reliable
    // than hasCharacteristic (some BLE stacks don't enumerate the storage
    // service until it is accessed — the reason earlier builds silently synced
    // nothing), detects models without storage (read throws), AND tells us up
    // front whether there is anything to drain, so we skip the whole transfer
    // and its notify timeout when the ring is empty.
    RingStatus? status;
    try {
      final rawStatus = await transport.readCharacteristic(
        WearableDeviceUuids.omiStorageService,
        WearableDeviceUuids.omiStorageControl,
      );
      status = RingProtocol.parseStatus(rawStatus);
      _storageReadable = true;
    } catch (_) {
      _storageReadable = false;
      _lastUnreadPackets = -1;
      return 0; // no on-board storage on this device
    }
    _lastUnreadPackets = status?.unreadPackets ?? -1;
    _lastFrameCount = 0;
    _packetsTransferred = 0;
    _packetsExpected = 0;
    if (status == null || status.unreadPackets == 0) return 0;
    final assembler = OfflineWavAssembler(codec: codec, stripBleHeader: false);
    if (!await assembler.ensureSupported()) {
      // The ring holds audio we cannot decode on this platform. Record it so the
      // sweep is not reported as "nothing to sync", and leave the cursor alone so
      // the data survives until a build that can decode it.
      _decoderAvailable = false;
      assembler.dispose();
      return 0;
    }
    _decoderAvailable = true;
    final reassembler = RingRecordReassembler();
    final infoCompleter = Completer<RingInfo?>();
    final doneCompleter = Completer<DoneNotification?>();
    // Published so cancelStoredSync() can unwind the wait locally. Without it an
    // abort only tells the device to stop; no DONE ever arrives and the drain
    // sits on its 8-minute timeout, blocking the capture it was cancelled for.
    _activeDrain = doneCompleter;
    var frameCount = 0;

    final subscription =
        (await transport.characteristicStream(
          WearableDeviceUuids.omiStorageService,
          WearableDeviceUuids.omiStorageData,
        )).listen((value) {
          if (value.isEmpty) return;
          switch (value[0]) {
            case RingProtocol.notifyReadBegin:
              // The device announces how many packets this transfer covers;
              // that is what makes real progress (not a spinner) possible.
              final begin = RingProtocol.parseReadBeginNotification(value);
              if (begin != null) {
                _packetsExpected = begin.packetCount;
                _publishProgress();
              }
            case RingProtocol.notifyInfo:
              final info = RingProtocol.parseInfoNotification(value);
              if (info != null && !infoCompleter.isCompleted) {
                infoCompleter.complete(info);
              }
            case RingProtocol.notifyData:
              reassembler.append(value.sublist(1));
              for (final record in reassembler.drainRecords()) {
                _packetsTransferred += 1;
                // ~30k packets per sweep: publishing each one would flood the
                // UI, so report every 25.
                if (_packetsTransferred % 25 == 0) _publishProgress();
                final audio = record.sublist(RingProtocol.timestampBytes);
                for (final frame in RingProtocol.parseAudioPayload(audio)) {
                  assembler.addFrame(frame);
                  frameCount += 1;
                }
              }
            case RingProtocol.notifyDone:
              final done = RingProtocol.parseDoneNotification(value);
              if (done != null && !doneCompleter.isCompleted) {
                doneCompleter.complete(done);
              }
          }
        });

    RingInfo? info;
    DoneNotification? done;
    try {
      await _writeStorage(<int>[RingProtocol.cmdInfo]);
      info = await infoCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (info == null || info.writeSeq <= info.readSeq) return 0;
      await _writeStorage(RingProtocol.encodeReadCommand(info.readSeq));
      done = await doneCompleter.future.timeout(
        const Duration(minutes: 8),
        onTimeout: () => null,
      );
    } finally {
      await subscription.cancel();
      if (identical(_activeDrain, doneCompleter)) _activeDrain = null;
    }

    _lastFrameCount = frameCount;
    // The range counts as transferred only when the device said so AND reported
    // success. A timeout, an abort, or a non-zero status means we hold an
    // incomplete prefix of the range.
    //
    // DONE alone is not enough: it reports what the *device* sent, and a host
    // stack that drops a notification under the burst (documented on Web
    // Bluetooth) leaves us short without the device ever knowing. Because the
    // ring is one unframed byte stream, a single lost notification shifts every
    // following 444-byte boundary — the audio decodes into garbage rather than
    // failing. So the packet count the device announced in READ_BEGIN must
    // match what we reassembled, with no partial record left over; otherwise
    // the range is retried instead of being ingested and advanced past.
    final packetsAccountedFor =
        _packetsExpected > 0 &&
        _packetsTransferred == _packetsExpected &&
        reassembler.pendingBytes == 0;
    _lastPendingBytes = reassembler.pendingBytes;
    final transferComplete = done != null && done.isOk && packetsAccountedFor;
    if (done != null && done.isOk && !packetsAccountedFor) {
      // The device finished successfully but we hold less than it sent. Saying
      // "no new recordings" here would be a lie about a device that is holding
      // 45 minutes of audio, so this surfaces as the failure it is; the cursor
      // is untouched, so the next sweep re-reads the range intact.
      throw StateError(
        'Transfer incomplete: received $_packetsTransferred of '
        '$_packetsExpected packets. The recording stays on the device and is '
        'retried.',
      );
    }
    _lastDoneStatus = done?.status ?? -1;
    final pcmBytes = assembler.pcmByteLength;
    final wav = assembler.toWav();
    assembler.dispose();
    // Never ingest a partial range. The cursor is not advanced without DONE, so
    // the same range is re-read next sync — ingesting the prefix now would
    // import audio that the fuller re-read then imports again under a different
    // content hash (the hash covers the whole file), i.e. a duplicate.
    final hasRecording =
        transferComplete && frameCount > 0 && pcmBytes >= minBytes;
    if (hasRecording) {
      // Durability invariant: ingest the recording BEFORE advancing the ring
      // cursor. If the ingest throws (or the app dies) the records stay on the
      // device and are re-drained next sync — the import is idempotent by
      // content hash, so a re-drain de-duplicates rather than losing audio.
      await onRecording(
        WearableRecording(
          id: 'omi-ring-${info.readSeq}-${info.writeSeq}',
          bytes: wav,
          contentType: 'audio/wav',
          filename: 'omi-offline.wav',
        ),
      );
    }
    // Advance only after a successful, complete transfer and after any recording
    // above was durably ingested. On a timeout, an abort, or an error status the
    // cursor stays put so the whole range is retried rather than skipped.
    //
    // A complete range that decoded no usable audio is still advanced: the bytes
    // were delivered and are unusable, so re-reading them forever would wedge
    // every future sync behind the same dead range. syncDiagnostics records the
    // frame count so that case is visible rather than silent.
    if (transferComplete) {
      try {
        await _writeStorage(RingProtocol.encodeAdvanceCommand(done.nextSeq));
      } catch (_) {
        // A failed advance only costs a harmless re-drain next sync.
      }
    }
    return hasRecording ? 1 : 0;
  }

  /// Safe here: live audio (19b10001) and the ring (30295781) are different
  /// characteristics on different services, with independent buffers.
  @override
  bool get supportsConcurrentCapture => true;

  @override
  Map<String, Object?> get syncDiagnostics => <String, Object?>{
    'packetsExpected': _packetsExpected,
    'packetsTransferred': _packetsTransferred,
    'unreassembledBytes': _lastPendingBytes,
    'storageCharacteristicReadable': _storageReadable,
    'unreadPackets': _lastUnreadPackets,
    'opusFramesDecoded': _lastFrameCount,
    // -1 = no DONE received (timeout or abort); 0 = success; >0 = device error.
    'transferStatus': _lastDoneStatus,
    'decoderAvailable': _decoderAvailable,
  };

  @override
  Future<void> cancelStoredSync() async {
    // Unwind the local wait first: the device is told to stop, but it sends no
    // DONE for an aborted transfer, so without this the drain would sit on its
    // 8-minute timeout and hold up the capture that cancelled it.
    final pending = _activeDrain;
    _activeDrain = null;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    try {
      await _writeStorage(<int>[RingProtocol.cmdStop]);
    } catch (_) {
      // Best-effort abort.
    }
  }

  @override
  Future<void> dispose() async {
    // A teardown mid-drain must not leave the drain awaiting a DONE that can no
    // longer arrive.
    final pending = _activeDrain;
    _activeDrain = null;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    await _progress.close();
    await super.dispose();
  }

  Future<void> _writeStorage(List<int> bytes) => transport.writeCharacteristic(
    WearableDeviceUuids.omiStorageService,
    WearableDeviceUuids.omiStorageData,
    bytes,
  );

  // An optional characteristic that fails to read or subscribe is not the same
  // as one the device does not have: the first is a fault worth seeing in a
  // diagnostic export, the second is normal. Neither should interrupt the
  // connection, so both are recorded rather than thrown.
  void _noteOptionalCharacteristic(String event, Object error) {
    ClientDiagnosticLog.instance.record(
      'wearable',
      event,
      level: 'warn',
      details: <String, Object?>{'reason': error.toString()},
    );
  }

}

class OmiGlassConnector extends OmiConnector {
  OmiGlassConnector({required super.device, required super.transport});

  @override
  WearableAudioCodec get fallbackCodec => WearableAudioCodec.opus;

}
