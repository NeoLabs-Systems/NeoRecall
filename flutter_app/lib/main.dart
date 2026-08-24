import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'main_auth.dart';
import 'main_controller.dart';
import 'main_floating.dart';
import 'main_shared.dart';
import 'main_shell.dart';
import 'main_theme.dart';
import 'src/desktop/meeting_detector.dart';
import 'src/desktop/window_coordinator.dart';
import 'src/devices/audio_codec_decoder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(initializeWearableAudioCodecs());
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      DesktopWindowCoordinator.initialOptions,
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  runApp(const NeoRecallApp());
}

class NeoRecallApp extends StatefulWidget {
  const NeoRecallApp({super.key});
  @override
  State<NeoRecallApp> createState() => _NeoRecallAppState();
}

class _NeoRecallAppState extends State<NeoRecallApp>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late final NeoRecallController controller = NeoRecallController()
    ..addListener(_changed);
  bool _trayRecording = false;
  bool _floatingMode = false;
  bool _desktopExperienceReady = false;
  bool _configuringWindow = false;
  bool _meetingEnded = false;
  MeetingActivity? _meetingActivity;
  MeetingDetector? _meetingDetector;
  StreamSubscription<MeetingActivity>? _meetingSubscription;
  final DesktopWindowCoordinator _window = const DesktopWindowCoordinator();
  bool get _desktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.initialize());
    if (_desktop) _initializeDesktopShell();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground proactively resumes sync and refresh instead
    // of waiting for the periodic upload timer or a connectivity event.
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.onAppResumed());
    } else {
      controller.onAppPaused();
    }
  }

  void _changed() {
    final recordingStopped = _trayRecording && !controller.isRecording;
    if (recordingStopped && _meetingEnded) {
      _meetingActivity = null;
      _meetingEnded = false;
    }
    if (mounted) setState(() {});
    if (_desktop && _trayRecording != controller.isRecording) {
      _trayRecording = controller.isRecording;
      _updateTray();
    }
    if (_desktop) unawaited(_syncDesktopExperience());
  }

  Future<void> _initializeDesktopShell() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    await _updateTray();
  }

  Future<void> _showWindow() async {
    if (controller.authenticated) {
      await _enterFloatingMode();
    } else {
      await _window.show();
    }
  }

  Future<void> _hideWindow() => _window.hide();

  Future<void> _syncDesktopExperience() async {
    if (_configuringWindow || !controller.initialized) return;
    if (!controller.authenticated) {
      if (_desktopExperienceReady) {
        _desktopExperienceReady = false;
        await _meetingSubscription?.cancel();
        _meetingSubscription = null;
        await _meetingDetector?.dispose();
        _meetingDetector = null;
        await _openLibrary(selectNotes: false);
      }
      return;
    }
    if (_desktopExperienceReady) return;
    _desktopExperienceReady = true;
    _meetingDetector = createMeetingDetector();
    _meetingSubscription = _meetingDetector!.activities.listen(
      _onMeetingActivity,
    );
    await _meetingDetector!.start();
    await _enterFloatingMode();
  }

  void _onMeetingActivity(MeetingActivity activity) {
    if (!mounted) return;
    if (activity.type == MeetingActivityType.started) {
      setState(() {
        _meetingActivity = activity;
        _meetingEnded = false;
      });
      if (!controller.isRecording) unawaited(_enterFloatingMode());
      return;
    }
    if (_meetingActivity?.application == activity.application) {
      if (controller.isRecording) {
        setState(() => _meetingEnded = true);
        unawaited(_enterFloatingMode());
      } else {
        setState(() {
          _meetingActivity = null;
          _meetingEnded = false;
        });
      }
    }
  }

  Future<void> _enterFloatingMode() async {
    if (!_desktop || !controller.authenticated || _configuringWindow) return;
    _configuringWindow = true;
    try {
      if (mounted && !_floatingMode) setState(() => _floatingMode = true);
      await _window.showFloating();
    } finally {
      _configuringWindow = false;
    }
  }

  Future<void> _openLibrary({bool selectNotes = true}) async {
    if (!_desktop || _configuringWindow) return;
    _configuringWindow = true;
    try {
      if (selectNotes && controller.page == RecallPage.record) {
        controller.selectPage(RecallPage.timeline);
      }
      if (mounted && _floatingMode) setState(() => _floatingMode = false);
      await _window.showLibrary(
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
      );
    } finally {
      _configuringWindow = false;
    }
  }

  Future<void> _updateTray() async {
    final stem = controller.isRecording ? 'tray_recording' : 'tray_idle';
    await trayManager.setIcon(
      'assets/branding/$stem.${Platform.isWindows ? 'ico' : 'png'}',
    );
    await trayManager.setToolTip(
      controller.isRecording ? 'NeoRecall — Recording' : 'NeoRecall',
    );
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(label: 'Quick capture', onClick: (_) => _showWindow()),
          MenuItem(label: 'Open notes library', onClick: (_) => _openLibrary()),
          if (controller.isRecording)
            MenuItem(
              label: 'Stop recording',
              onClick: (_) async => controller.stopRecording(),
            ),
          MenuItem.separator(),
          MenuItem(
            label: 'Quit',
            onClick: (_) async {
              if (controller.isRecording) await controller.stopRecording();
              await windowManager.setPreventClose(false);
              await trayManager.destroy();
              await windowManager.destroy();
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_desktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    unawaited(_meetingSubscription?.cancel());
    unawaited(_meetingDetector?.dispose());
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Keep the tray process alive so meeting detection and upload recovery keep
    // working after the visible window closes.
    await _window.hide();
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'NeoRecall',
    themeMode: ThemeMode.system,
    theme: buildNeoRecallTheme(Brightness.light),
    darkTheme: buildNeoRecallTheme(Brightness.dark),
    home: !controller.initialized
        ? const _NeoRecallSplashView()
        : controller.authenticated && !controller.requiresBackendUrlSetup
        ? _desktop && _floatingMode
              ? FloatingCaptureWindow(
                  controller: controller,
                  meetingActivity: _meetingActivity,
                  meetingEnded: _meetingEnded,
                  onOpenLibrary: () => _openLibrary(),
                  onHide: () => _hideWindow(),
                  onDismissMeeting: () => setState(() {
                    _meetingActivity = null;
                    _meetingEnded = false;
                  }),
                )
              : NeoRecallShell(controller: controller)
        : NeoRecallAuthScreen(controller: controller),
  );
}

class _NeoRecallSplashView extends StatelessWidget {
  const _NeoRecallSplashView();

  @override
  Widget build(BuildContext context) {
    return AmbientBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandLockup(logoSize: 52),
              const SizedBox(height: 18),
              SizedBox(
                width: 180,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: const LinearProgressIndicator(minHeight: 4),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Loading NeoRecall'),
            ],
          ),
        ),
      ),
    );
  }
}
