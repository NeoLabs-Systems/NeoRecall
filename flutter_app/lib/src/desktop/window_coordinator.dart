import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Owns native desktop window presentation so app lifecycle code only decides
/// which experience should be visible.
class DesktopWindowCoordinator {
  const DesktopWindowCoordinator();

  static const Size floatingSize = Size(360, 84);
  static const Size floatingMinimumSize = floatingSize;
  static const Size consentSize = Size(380, 280);
  static const Offset floatingScreenInset = Offset(16, 16);
  static const Size librarySize = Size(1180, 780);
  static const Size libraryMinimumSize = Size(760, 560);

  static const WindowOptions initialOptions = WindowOptions(
    size: librarySize,
    minimumSize: libraryMinimumSize,
    center: true,
    title: 'NeoRecall',
  );

  Future<void> showFloating({bool activate = true}) async {
    await windowManager.setMinimumSize(floatingMinimumSize);
    await windowManager.setResizable(false);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setAlwaysOnTop(true);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await windowManager.setVisibleOnAllWorkspaces(
        true,
        visibleOnFullScreen: true,
      );
    }
    await windowManager.setSkipTaskbar(true);
    await windowManager.setHasShadow(true);
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setSize(floatingSize, animate: true);
    await _alignFloating();
    await _show(activate: activate);
  }

  Future<void> showConsentSurface() async {
    await windowManager.setMinimumSize(consentSize);
    await windowManager.setSize(consentSize, animate: true);
    await _alignFloating();
  }

  Future<void> showLibrary(Brightness brightness) async {
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setAlwaysOnTop(false);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await windowManager.setVisibleOnAllWorkspaces(false);
    }
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(libraryMinimumSize);
    await windowManager.setBackgroundColor(
      brightness == Brightness.dark
          ? const Color(0xFF151514)
          : const Color(0xFFF8F7F2),
    );
    await windowManager.setSize(librarySize, animate: true);
    await windowManager.center(animate: true);
    await _show();
  }

  Future<void> hide() => windowManager.hide();

  Future<void> show() => _show();

  Future<void> _show({bool activate = true}) async {
    await windowManager.show(inactive: !activate);
    if (activate) await windowManager.focus();
  }

  Future<void> _alignFloating() async {
    await windowManager.setAlignment(Alignment.bottomRight, animate: true);
    final position = await windowManager.getPosition();
    await windowManager.setPosition(
      position - floatingScreenInset,
      animate: true,
    );
  }
}
