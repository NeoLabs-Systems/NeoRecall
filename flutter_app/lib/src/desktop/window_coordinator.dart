import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Owns native desktop window presentation so app lifecycle code only decides
/// which experience should be visible.
class DesktopWindowCoordinator {
  const DesktopWindowCoordinator();

  static const Size floatingSize = Size(470, 238);
  static const Size floatingMinimumSize = Size(400, 200);
  static const Offset floatingScreenInset = Offset(20, 20);
  static const Size librarySize = Size(1180, 780);
  static const Size libraryMinimumSize = Size(760, 560);

  static const WindowOptions initialOptions = WindowOptions(
    size: librarySize,
    minimumSize: libraryMinimumSize,
    center: true,
    title: 'NeoRecall',
  );

  Future<void> showFloating() async {
    await windowManager.setMinimumSize(floatingMinimumSize);
    await windowManager.setResizable(false);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setSize(floatingSize, animate: true);
    await windowManager.setAlignment(Alignment.bottomRight, animate: true);
    final position = await windowManager.getPosition();
    await windowManager.setPosition(
      position - floatingScreenInset,
      animate: true,
    );
    await _showAndFocus();
  }

  Future<void> showLibrary(Brightness brightness) async {
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(libraryMinimumSize);
    await windowManager.setBackgroundColor(
      brightness == Brightness.dark
          ? const Color(0xFF151514)
          : const Color(0xFFF8F7F2),
    );
    await windowManager.setSize(librarySize, animate: true);
    await windowManager.center(animate: true);
    await _showAndFocus();
  }

  Future<void> hide() => windowManager.hide();

  Future<void> show() => _showAndFocus();

  Future<void> _showAndFocus() async {
    await windowManager.show();
    await windowManager.focus();
  }
}
