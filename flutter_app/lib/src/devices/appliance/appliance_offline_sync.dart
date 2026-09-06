import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../diagnostics/client_diagnostic_log.dart';
import '../omi/offline_sync.dart';
import 'appliance_inflate.dart';
import 'appliance_link.dart';
import 'appliance_protocol.dart';

/// The Desk's recordings, rescued over Bluetooth when the Desk has no Wi-Fi.
///
/// This is the same [WearableOfflineSync] contract the wearables implement, so
/// the whole app-side flow — the sweep, the progress card, the durable import,
/// the upload policy — is the one that already exists. What differs is only the
/// wire underneath: list what is pending, pull one recording at a time as
/// numbered pages, and acknowledge each with the SHA-256 of the bytes actually
/// stored. The Desk deletes nothing until that hash matches its own record,
/// which is the release invariant translated for a receiver that is not the
/// server.
class ApplianceOfflineSync with WearableOfflineSync {
  ApplianceOfflineSync(this._link);

  final ApplianceLink _link;

  /// How long to wait for pages before asking again from the first gap.
  ///
  /// Generous on purpose: at BLE pace a stall is usually the phone briefly
  /// hogging the radio, not a dead link, and re-requesting too eagerly doubles
  /// traffic on a channel that has none to spare.
  static const Duration _stall = Duration(seconds: 6);

  /// Re-requests per recording before the pull is declared failed.
  static const int _maxResumes = 5;

  bool _cancelled = false;
  final StreamController<WearableSyncProgress> _progress =
      StreamController<WearableSyncProgress>.broadcast();
  final Map<String, Object?> _diagnostics = <String, Object?>{};

  @override
  Stream<WearableSyncProgress> get syncProgress => _progress.stream;

  @override
  Map<String, Object?> get syncDiagnostics =>
      Map<String, Object?>.unmodifiable(_diagnostics);

  @override
  Future<void> cancelStoredSync() async {
    _cancelled = true;
  }

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    _cancelled = false;
    _diagnostics.clear();
    final List<AppliancePendingRecording> pending = await _list();
    _diagnostics['listed'] = pending.length;
    if (pending.isEmpty) return 0;

    int pendingSeconds = pending.fold<int>(
      0,
      (int sum, AppliancePendingRecording p) => sum + p.durationMs ~/ 1000,
    );
    int emitted = 0;
    for (final AppliancePendingRecording entry in pending) {
      if (_cancelled) break;
      if (entry.byteSize < minBytes) continue;
      _progress.add(
        WearableSyncProgress(
          transferred: emitted,
          total: pending.length,
          pendingSeconds: pendingSeconds,
        ),
      );

      final Uint8List wav = inflate(await _pull(entry));
      final String digest = sha256.convert(wav).toString();
      if (digest != entry.sha256.toLowerCase()) {
        // Never acknowledge bytes that do not match: the ack is what lets the
        // Desk delete its only copy. A corrupt transfer is retried next sweep.
        _diagnostics['hash_mismatch'] = entry.id;
        ClientDiagnosticLog.instance.record(
          'appliance',
          'drain_hash_mismatch',
          level: 'error',
          details: <String, Object?>{'chunk': entry.id},
        );
        continue;
      }

      // Resolves only once the recording is durably stored on the phone —
      // that is the [WearableOfflineSync] contract, and the reason the ack
      // below is safe to send at all.
      await onRecording(
        WearableRecording(
          id: 'desk-${entry.id}',
          bytes: wav,
          contentType: 'audio/wav',
          filename: 'neorecall-desk-${entry.id.substring(0, 8)}.wav',
          capturedAt: entry.createdAt,
        ),
      );
      await _send(ApplianceCommand.drainAck(entry.id, digest));
      emitted += 1;
      pendingSeconds -= entry.durationMs ~/ 1000;
      _progress.add(
        WearableSyncProgress(
          transferred: emitted,
          total: pending.length,
          pendingSeconds: pendingSeconds < 0 ? 0 : pendingSeconds,
        ),
      );
    }
    return emitted;
  }

  Future<List<AppliancePendingRecording>> _list() async {
    final Future<ApplianceDiscovery> result = _link.discoveries
        .firstWhere((ApplianceDiscovery d) => d.kind == 'pending')
        .timeout(const Duration(seconds: 15));
    await _send(ApplianceCommand.drainList);
    final ApplianceDiscovery listing = await result;
    return listing.entries
        .map(AppliancePendingRecording.fromEntry)
        .whereType<AppliancePendingRecording>()
        .toList(growable: false);
  }

  /// Pull one recording, page by page, resuming across lost notifications.
  Future<Uint8List> _pull(AppliancePendingRecording entry) async {
    List<Uint8List?>? pages;
    int resumes = 0;

    while (true) {
      if (_cancelled) throw StateError('The sync was cancelled.');
      final List<Uint8List?>? soFar = pages;
      final int fromPage = soFar == null ? 0 : _firstGap(soFar);
      final Completer<void> complete = Completer<void>();
      Timer? stall;

      void arm() {
        stall?.cancel();
        stall = Timer(_stall, () {
          if (!complete.isCompleted) complete.complete();
        });
      }

      final StreamSubscription<ApplianceAudioPage> sub = _link.audioPages
          .listen((ApplianceAudioPage page) {
            if (!entry.id.startsWith(page.chunkPrefix)) return;
            pages ??= List<Uint8List?>.filled(page.pages, null);
            if (page.page < pages!.length) pages![page.page] = page.data;
            if (_firstGap(pages!) == pages!.length &&
                !complete.isCompleted) {
              complete.complete();
            } else {
              arm();
            }
          });
      arm();
      try {
        await _send(ApplianceCommand.drainPull(entry.id, fromPage: fromPage));
        await complete.future;
      } finally {
        stall?.cancel();
        await sub.cancel();
      }

      final List<Uint8List?>? received = pages;
      if (received != null && _firstGap(received) == received.length) {
        final BytesBuilder joined = BytesBuilder(copy: false);
        for (final Uint8List? page in received) {
          joined.add(page!);
        }
        return joined.takeBytes();
      }
      resumes += 1;
      _diagnostics['resumes'] = resumes;
      if (resumes > _maxResumes) {
        throw TimeoutException('The device stopped answering mid-transfer.');
      }
    }
  }

  static int _firstGap(List<Uint8List?> pages) {
    for (int i = 0; i < pages.length; i += 1) {
      if (pages[i] == null) return i;
    }
    return pages.length;
  }

  Future<void> _send(ApplianceCommand command) => _link.send(command);
}
