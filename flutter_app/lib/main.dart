import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'main_auth.dart';
import 'main_controller.dart';
import 'main_shared.dart';
import 'main_shell.dart';
import 'main_theme.dart';
import 'src/devices/audio_codec_decoder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(initializeWearableAudioCodecs());
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 780),
        minimumSize: Size(760, 560),
        center: true,
        title: 'NeoRecall',
      ),
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
    if (mounted) setState(() {});
    if (_desktop && _trayRecording != controller.isRecording) {
      _trayRecording = controller.isRecording;
      _updateTray();
    }
  }

  Future<void> _initializeDesktopShell() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    await _updateTray();
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
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
          MenuItem(label: 'Open NeoRecall', onClick: (_) => _showWindow()),
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
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (controller.isRecording) {
      await windowManager.hide();
      return;
    }
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
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
        ? NeoRecallShell(controller: controller)
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
