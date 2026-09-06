import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/appliance/appliance_offline_sync.dart';
import 'package:neorecall/src/devices/omi/offline_sync.dart';

import 'support/appliance_test_support.dart';

/// Rescuing recordings from a Desk that has no Wi-Fi.
///
/// The wire is the risky part, so that is what these tests drive: the listing,
/// the paged transfer with a deliberately lost notification, and — most
/// important — the custody rule that a hash mismatch must never acknowledge,
/// because the ack is what lets the Desk delete its only copy.
void main() {
  const int pageBytes = 192;

  late ApplianceRig rig;
  late ApplianceOfflineSync sync;

  setUp(() async {
    rig = ApplianceRig();
    sync = ApplianceOfflineSync(rig.link);
    await rig.connect();
  });

  tearDown(() => rig.controller.dispose());

  // Incompressible on purpose: a periodic pattern lets zlib fold the whole
  // recording into a page or two, and a test about losing page 2 needs a
  // transfer that actually has one.
  final Random noise = Random(42);
  Uint8List wavOf(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => noise.nextInt(256)));

  /// What the device would do: compress, then answer pulls with pages.
  void serveChunk(
    String id,
    Uint8List wav, {
    Set<int> dropOnFirstAttempt = const <int>{},
  }) {
    final Uint8List packed = Uint8List.fromList(ZLibEncoder().convert(wav));
    final int total = (packed.length + pageBytes - 1) ~/ pageBytes;
    int attempts = 0;
    rig.transport.onCommandWrite = (Map<String, Object?> command) {
      if (command['c'] == 'drain_list') {
        rig.transport.pushDiscovery(<String, Object?>{
          'v': 1,
          'k': 'pending',
          'p': 0,
          'n': 1,
          'e': <Map<String, Object?>>[
            <String, Object?>{
              'id': id,
              'by': wav.length,
              'du': 5000,
              'sh': sha256.convert(wav).toString(),
              'at': '2026-08-30T10:00:00Z',
            },
          ],
        });
      }
      if (command['c'] == 'drain_pull') {
        attempts += 1;
        final int from = command['fp'] is int ? command['fp']! as int : 0;
        for (int page = from; page < total; page += 1) {
          if (attempts == 1 && dropOnFirstAttempt.contains(page)) continue;
          rig.transport.pushDiscovery(<String, Object?>{
            'v': 1,
            'k': 'audio',
            'ch': id.substring(0, 8),
            'p': page,
            'n': total,
            'd': Uint8List.sublistView(
              packed,
              page * pageBytes,
              (page + 1) * pageBytes > packed.length
                  ? packed.length
                  : (page + 1) * pageBytes,
            ),
          });
        }
      }
    };
  }

  test('a stranded recording travels to the phone and is acknowledged', () async {
    final Uint8List wav = wavOf(4000);
    serveChunk('chunk-aaaa-1111', wav);

    final List<WearableRecording> received = <WearableRecording>[];
    final int emitted = await sync.drainStoredAudio((recording) async {
      received.add(recording);
    });

    expect(emitted, 1);
    expect(received.single.bytes, wav);
    expect(received.single.contentType, 'audio/wav');
    expect(received.single.id, 'desk-chunk-aaaa-1111');
    final Map<String, Object?> ack = rig
        .commandsNamed('drain_ack')
        .single;
    expect(ack['sh'], sha256.convert(wav).toString());
  });

  test('a lost page is resumed, not restarted', () async {
    final Uint8List wav = wavOf(2500);
    serveChunk('chunk-bbbb-2222', wav, dropOnFirstAttempt: <int>{2});

    final int emitted = await sync.drainStoredAudio((_) async {});

    expect(emitted, 1);
    final List<Map<String, Object?>> pulls = rig.commandsNamed('drain_pull');
    expect(pulls.length, 2);
    // The second ask names the first missing page rather than starting over —
    // at Bluetooth speeds a restart is minutes, a resume is seconds.
    expect(pulls.last['fp'], 2);
  });

  test('bytes that do not match the hash are never acknowledged', () async {
    final Uint8List wav = wavOf(1000);
    serveChunk('chunk-cccc-3333', wav);
    // The device lied (or the transfer corrupted): the listing promises a
    // different recording than the pages deliver.
    rig.transport.onCommandWrite = _tamperedListing(rig, wav);

    final int emitted = await sync.drainStoredAudio((_) async {
      fail('corrupt bytes must never reach the import pipeline');
    });

    expect(emitted, 0);
    expect(rig.commandsNamed('drain_ack'), isEmpty);
  });
}

void Function(Map<String, Object?>) _tamperedListing(
  ApplianceRig rig,
  Uint8List wav,
) {
  const int pageBytes = 192;
  final Uint8List packed = Uint8List.fromList(ZLibEncoder().convert(wav));
  final int total = (packed.length + pageBytes - 1) ~/ pageBytes;
  return (Map<String, Object?> command) {
    if (command['c'] == 'drain_list') {
      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'pending',
        'p': 0,
        'n': 1,
        'e': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'chunk-cccc-3333',
            'by': wav.length,
            'du': 1000,
            'sh': 'f' * 64, // not the hash of what the pages carry
            'at': '2026-08-30T10:00:00Z',
          },
        ],
      });
    }
    if (command['c'] == 'drain_pull') {
      for (int page = 0; page < total; page += 1) {
        rig.transport.pushDiscovery(<String, Object?>{
          'v': 1,
          'k': 'audio',
          'ch': 'chunk-cc',
          'p': page,
          'n': total,
          'd': Uint8List.sublistView(
            packed,
            page * pageBytes,
            (page + 1) * pageBytes > packed.length
                ? packed.length
                : (page + 1) * pageBytes,
          ),
        });
      }
    }
  };
}
