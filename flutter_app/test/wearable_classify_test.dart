import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/audio_codec_decoder.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';

void main() {
  test('classifies supported Omi-family devices', () {
    expect(
      DiscoveredWearable.classify(
        name: 'omi-dev',
        serviceUuids: <String>[WearableDeviceUuids.omiService],
      ),
      WearableDeviceType.omi,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'OmiGlass',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.omiGlass,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'Unknown',
        serviceUuids: <String>[WearableDeviceUuids.heyPocketService],
      ),
      WearableDeviceType.heyPocket,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'HeyPocket',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.heyPocket,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'PKT01-2246',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.heyPocket,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'PK01_BLUE',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.heyPocket,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'PocketBook Reader',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.custom,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'Memoket Gem',
        serviceUuids: const <String>[],
      ),
      WearableDeviceType.memoket,
    );
    expect(
      DiscoveredWearable.classify(
        name: 'Unknown',
        serviceUuids: <String>[WearableDeviceUuids.memoketService],
      ),
      WearableDeviceType.memoket,
    );
  });

  test(
    'does not claim Apple Watch or Ray-Ban Meta as supported BLE devices',
    () {
      expect(
        DiscoveredWearable.classify(
          name: 'Apple Watch',
          serviceUuids: const <String>[],
        ),
        isNot(WearableDeviceType.omi),
      );
      // Without service match, unknown names become custom (not silently omi).
      expect(
        DiscoveredWearable.classify(
          name: 'Ray-Ban Meta',
          serviceUuids: const <String>[],
        ),
        WearableDeviceType.custom,
      );
    },
  );

  test('pcm8 and pcm16 decoding produce PCM16 output', () {
    final pcm8 = WearableAudioDecoder(
      codec: WearableAudioCodec.pcm8,
      stripBleHeader: false,
    );
    final decoded8 = pcm8.decodePacket(<int>[128, 129, 127, 130])!;
    expect(decoded8.length, 8);

    final pcm16 = WearableAudioDecoder(
      codec: WearableAudioCodec.pcm16,
      stripBleHeader: true,
    );
    // header(3) + two int16 samples
    final decoded16 = pcm16.decodePacket(<int>[
      1,
      0,
      0,
      0x10,
      0x00,
      0x20,
      0x00,
    ])!;
    expect(decoded16, <int>[0x10, 0x00, 0x20, 0x00]);

    final assembler = OmiFrameAssembler();
    expect(assembler.accept(<int>[0, 0, 0, 1, 2, 3]), isNull);
    final frame = assembler.accept(<int>[1, 0, 0, 4, 5]);
    expect(frame, <int>[1, 2, 3]);
  });

  test('Opus frame candidates keep the TOC and offer a strip fallback', () {
    expect(
      WearableAudioDecoder.opusFrameCandidates(<int>[0xbc, 0x62, 0x11]),
      <List<int>>[
        <int>[0xbc, 0x62, 0x11],
        <int>[0x62, 0x11],
      ],
    );
    expect(
      WearableAudioDecoder.opusFrameCandidates(<int>[0x04, 0x11]),
      <List<int>>[
        <int>[0x04, 0x11],
      ],
    );
  });

  test('stereo Opus PCM is downmixed to mono', () {
    final mixed = WearableAudioDecoder.pcm16FromOpusSamples(<int>[
      1000,
      2000,
      -1000,
      1000,
    ], channels: 2);
    final view = ByteData.sublistView(mixed);
    expect(view.getInt16(0, Endian.little), 1500);
    expect(view.getInt16(2, Endian.little), 0);
  });

  test('MP3 codec is locally decodable without async initialization', () async {
    final decoder = WearableAudioDecoder(
      codec: WearableAudioCodec.mp3,
      stripBleHeader: false,
    );
    expect(decoder.isSupported, isTrue);
    expect(await decoder.ensureSupported(), isTrue);
    decoder.dispose();
  });
}
