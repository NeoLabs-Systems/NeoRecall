import 'dart:async';
import 'dart:typed_data';

import 'base_connector.dart';
import 'device_models.dart';
import 'offline_audio.dart';
import 'offline_sync.dart';
import 'ring_protocol.dart';

class OmiConnector extends WearableConnector with WearableOfflineSync {
  OmiConnector({required super.device, required super.transport});

  WearableAudioCodec _codec = WearableAudioCodec.pcm8;

  WearableAudioCodec get fallbackCodec => WearableAudioCodec.pcm8;

  @override
  WearableAudioCodec get codec => _codec;

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
    } catch (_) {}
    try {
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.batteryService,
          WearableDeviceUuids.batteryLevel,
        )).listen((value) {
          if (value.isNotEmpty) batteryLevels.add(value.first);
        }),
      );
    } catch (_) {}
    try {
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.buttonService,
          WearableDeviceUuids.buttonTrigger,
        )).listen((value) {
          if (value.isNotEmpty) buttonEvents.add(value);
        }),
      );
    } catch (_) {}
  }

  Future<void> _syncTime() async {
    try {
      final epochSeconds =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final bytes = ByteData(4)..setUint32(0, epochSeconds, Endian.little);
      await transport.writeCharacteristic(
        WearableDeviceUuids.timeSyncService,
        WearableDeviceUuids.timeSyncWrite,
        bytes.buffer.asUint8List(),
      );
    } catch (_) {}
  }

  Future<WearableAudioCodec> _readCodec() async {
    try {
      final value = await transport.readCharacteristic(
        WearableDeviceUuids.omiService,
        WearableDeviceUuids.omiAudioCodec,
      );
      if (value.isEmpty) return fallbackCodec;
      final codecId = value.first;
      switch (codecId) {
        case 1:
          return WearableAudioCodec.pcm8;
        case 20:
          return WearableAudioCodec.opus;
        case 21:
          return WearableAudioCodec.opusFs320;
        default:
          return fallbackCodec;
      }
    } catch (_) {
      return fallbackCodec;
    }
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
    // Live capture and the offline ring drain are mutually exclusive: the ring
    // buffer only exists to cover phone-away gaps, so it is drained while idle,
    // never mid-recording (which would also contend for the storage channel).
    if (recording) return 0;
    final assembler = OfflineWavAssembler(codec: codec, stripBleHeader: false);
    if (!await assembler.ensureSupported()) {
      assembler.dispose();
      return 0;
    }
    final reassembler = RingRecordReassembler();
    final infoCompleter = Completer<RingInfo?>();
    final doneCompleter = Completer<int?>();
    var frameCount = 0;

    final subscription =
        (await transport.characteristicStream(
          WearableDeviceUuids.omiStorageService,
          WearableDeviceUuids.omiStorageData,
        )).listen((value) {
          if (value.isEmpty) return;
          switch (value[0]) {
            case RingProtocol.notifyInfo:
              final info = RingProtocol.parseInfoNotification(value);
              if (info != null && !infoCompleter.isCompleted) {
                infoCompleter.complete(info);
              }
            case RingProtocol.notifyData:
              reassembler.append(value.sublist(1));
              for (final record in reassembler.drainRecords()) {
                final audio = record.sublist(RingProtocol.timestampBytes);
                for (final frame in RingProtocol.parseAudioPayload(audio)) {
                  assembler.addFrame(frame);
                  frameCount += 1;
                }
              }
            case RingProtocol.notifyDone:
              final done = RingProtocol.parseDoneNotification(value);
              if (done != null && !doneCompleter.isCompleted) {
                doneCompleter.complete(done.nextSeq);
              }
          }
        });

    RingInfo? info;
    int? nextSeq;
    try {
      await _writeStorage(<int>[RingProtocol.cmdInfo]);
      info = await infoCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (info == null || info.writeSeq <= info.readSeq) return 0;
      await _writeStorage(RingProtocol.encodeReadCommand(info.readSeq));
      nextSeq = await doneCompleter.future.timeout(
        const Duration(minutes: 8),
        onTimeout: () => null,
      );
    } finally {
      await subscription.cancel();
    }

    final pcmBytes = assembler.pcmByteLength;
    final wav = assembler.toWav();
    assembler.dispose();
    final hasRecording = frameCount > 0 && pcmBytes >= minBytes;
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
    // Advance only once the device signalled DONE (the range was fully
    // transferred) and only after any recording above was durably ingested. On
    // a DONE timeout we leave the cursor put so the whole range is retried next
    // sync rather than being skipped and lost.
    if (nextSeq != null) {
      try {
        await _writeStorage(RingProtocol.encodeAdvanceCommand(nextSeq));
      } catch (_) {
        // A failed advance only costs a harmless re-drain next sync.
      }
    }
    return hasRecording ? 1 : 0;
  }

  @override
  Future<void> cancelStoredSync() async {
    try {
      await _writeStorage(<int>[RingProtocol.cmdStop]);
    } catch (_) {
      // Best-effort abort.
    }
  }

  Future<void> _writeStorage(List<int> bytes) => transport.writeCharacteristic(
    WearableDeviceUuids.omiStorageService,
    WearableDeviceUuids.omiStorageData,
    bytes,
  );
}

class OmiGlassConnector extends OmiConnector {
  OmiGlassConnector({required super.device, required super.transport});

  @override
  WearableAudioCodec get fallbackCodec => WearableAudioCodec.opus;
}
