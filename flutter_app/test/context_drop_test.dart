import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/context/context_content_type.dart';
import 'package:neorecall/src/context/dropped_file.dart';
import 'package:neorecall/src/context/file_drop_surface.dart';
import 'package:neorecall/src/context/recording_context_drop_target.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/recording/audio_frame.dart';
import 'package:neorecall/src/recording/recorder.dart';

/// Dropping a file anywhere in the app attaches it to the running recording.
/// The gesture only exists while a recording is live: outside one there is no
/// session to attach to, so the page must hand drops back to the browser.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  DroppedFile file(String name, {String? declaredType}) => DroppedFile(
    name: name,
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
    declaredType: declaredType,
  );

  group('context content types', () {
    test('the type the platform reported wins over the extension', () {
      expect(
        contextContentTypeFor('notes.bin', declared: 'application/pdf'),
        'application/pdf',
      );
    });

    test('the extension fills in what the platform left blank', () {
      expect(
        contextContentTypeFor('brief.pdf', declared: ''),
        'application/pdf',
      );
      expect(contextContentTypeFor('shot.JPG'), 'image/jpeg');
      expect(
        contextContentTypeFor('rows.csv', declared: 'application/octet-stream'),
        'text/csv',
      );
    });

    test('an unknown file stays a plain byte stream', () {
      expect(contextContentTypeFor('capture'), 'application/octet-stream');
      expect(contextContentTypeFor('capture.q3z'), 'application/octet-stream');
    });

    test('the image picker never returns a non-image type', () {
      expect(contextImageContentTypeFor('scan'), 'image/jpeg');
      expect(contextImageContentTypeFor('scan.png'), 'image/png');
    });
  });

  testWidgets('a drop during a recording is added as context', (tester) async {
    final _FakeDropSurface surface = _FakeDropSurface();
    final _RecordingController controller = _RecordingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        RecordingContextDropTarget(
          controller: controller,
          surface: surface,
          child: const Text('app'),
        ),
      ),
    );

    expect(surface.listening, isTrue);

    surface.hover(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Drop to add context'), findsOneWidget);

    await surface.drop(<DroppedFile>[
      file('brief.pdf'),
      file('shot.png', declaredType: 'image/png'),
    ]);
    await tester.pump();

    expect(controller.added, <String>[
      'brief.pdf:application/pdf',
      'shot.png:image/png',
    ]);
    expect(find.text('2 files added as context'), findsOneWidget);
    expect(find.text('Drop to add context'), findsNothing);
  });

  testWidgets('a file the browser cannot read is reported, not swallowed', (
    tester,
  ) async {
    final _FakeDropSurface surface = _FakeDropSurface();
    final _RecordingController controller = _RecordingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        RecordingContextDropTarget(
          controller: controller,
          surface: surface,
          child: const Text('app'),
        ),
      ),
    );

    surface.fail(const FileDropReadException('Photos'));
    await tester.pump();

    expect(find.textContaining('Photos could not be read'), findsOneWidget);
    expect(controller.added, isEmpty);
  });

  testWidgets('the item the session rejects names the file and the reason', (
    tester,
  ) async {
    final _FakeDropSurface surface = _FakeDropSurface();
    final _RecordingController controller = _RecordingController()
      ..rejection = 'This file is larger than the server limit.';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        RecordingContextDropTarget(
          controller: controller,
          surface: surface,
          child: const Text('app'),
        ),
      ),
    );

    await surface.drop(<DroppedFile>[file('huge.pdf')]);
    await tester.pump();

    expect(
      find.text('huge.pdf: This file is larger than the server limit.'),
      findsOneWidget,
    );
  });

  testWidgets('without a recording the page keeps the browser behavior', (
    tester,
  ) async {
    final _FakeDropSurface surface = _FakeDropSurface();
    final _RecordingController controller = _RecordingController()
      ..sessionId = null;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        RecordingContextDropTarget(
          controller: controller,
          surface: surface,
          child: const Text('app'),
        ),
      ),
    );

    expect(surface.listening, isFalse);
    expect(find.text('app'), findsOneWidget);

    // Starting a recording arms the page, and stopping it hands drops back.
    controller.sessionId = 'session-live';
    controller.notify();
    await tester.pump();
    expect(surface.listening, isTrue);

    controller.sessionId = null;
    controller.notify();
    await tester.pump();
    expect(surface.listening, isFalse);
  });
}

/// A controller that reports a live session without opening a real recorder.
class _RecordingController extends NeoRecallController {
  _RecordingController() : super(recorder: _FakeRecorder());

  String? sessionId = 'session-live';
  String? rejection;
  final List<String> added = <String>[];

  void notify() => notifyListeners();

  @override
  bool get isRecording => sessionId != null;

  @override
  String? get activeRecordingSessionId => sessionId;

  @override
  Future<void> addRecordingFile({
    required String sessionId,
    required Uint8List bytes,
    required String name,
    required String contentType,
  }) async {
    final String? reason = rejection;
    if (reason != null) throw StateError(reason);
    added.add('$name:$contentType');
  }
}

/// Stands in for the browser document, so the test can drive a drop.
class _FakeDropSurface implements FileDropSurface {
  bool listening = false;
  void Function(bool hovering)? _onHover;
  void Function(List<DroppedFile> files)? _onDrop;
  void Function(Object error)? _onError;

  @override
  bool get isAvailable => true;

  @override
  void start({
    required void Function(bool hovering) onHover,
    required void Function(List<DroppedFile> files) onDrop,
    required void Function(Object error) onError,
  }) {
    listening = true;
    _onHover = onHover;
    _onDrop = onDrop;
    _onError = onError;
  }

  @override
  void stop() {
    listening = false;
    _onHover = null;
    _onDrop = null;
    _onError = null;
  }

  void hover(bool hovering) => _onHover?.call(hovering);

  void fail(Object error) => _onError?.call(error);

  Future<void> drop(List<DroppedFile> files) async {
    _onHover?.call(false);
    _onDrop?.call(files);
    // The handler reads and queues each file before it reports the outcome.
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeRecorder implements RecallRecorder {
  @override
  Stream<RecordedAudioChunk> get chunks =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<RecordedAudioChunk> get partials =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<String> get warnings => const Stream<String>.empty();
  @override
  Stream<double> get levels => const Stream<double>.empty();
  @override
  bool get isRecording => true;
  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) async => const RecorderCapability(
    microphone: true,
    systemAudio: false,
    persistentStorage: false,
    sampleRate: 16000,
    sourceKind: 'microphone',
  );
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
