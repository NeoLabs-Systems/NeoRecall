import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
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

  /// Kept clear of the menu bar and dock, so a window sized to the work area
  /// still reads as a window rather than filling the screen edge to edge.
  static const double screenMargin = 48;

  static const Color _darkChrome = Color(0xFF151514);
  static const Color _lightChrome = Color(0xFFF8F7F2);

  /// The library window as it should open on this machine.
  ///
  /// The size used to be a fixed 1180x780. On any display whose work area is
  /// shorter than that -- a laptop at a scaled resolution, an external screen
  /// with a large dock -- the frame ran past the bottom of the screen and the
  /// native window background showed through the part Flutter had not laid
  /// out, as black bands along the edges.
  Future<WindowOptions> initialWindowOptions() async {
    final size = await fitToScreen(librarySize);
    return WindowOptions(
      size: size,
      minimumSize: _withinBounds(libraryMinimumSize, size),
      center: true,
      title: 'NeoRecall',
      // Painted before the first frame arrives, so a resize never exposes an
      // unpainted black rectangle.
      backgroundColor:
          PlatformDispatcher.instance.platformBrightness == Brightness.dark
          ? _darkChrome
          : _lightChrome,
    );
  }

  /// [desired], shrunk to what the display it opens on can actually show.
  @visibleForTesting
  Future<Size> fitToScreen(Size desired) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visible = display.visibleSize ?? display.size;
      return clampToVisible(desired, visible);
    } on Object {
      // No display to ask (headless, or a platform without the plugin): the
      // requested size is still the best guess available.
      return desired;
    }
  }

  @visibleForTesting
  static Size clampToVisible(Size desired, Size visible) {
    // A display smaller than the margin is not a real display; never return a
    // size at or below zero for one.
    final width = math.max(
      floatingSize.width,
      math.min(desired.width, visible.width - screenMargin),
    );
    final height = math.max(
      floatingSize.height,
      math.min(desired.height, visible.height - screenMargin),
    );
    return Size(width, height);
  }

  /// A minimum larger than the window itself would force the frame back off
  /// the screen, so it follows the fitted size down.
  static Size _withinBounds(Size minimum, Size bounds) => Size(
    math.min(minimum.width, bounds.width),
    math.min(minimum.height, bounds.height),
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
    await windowManager.setSize(floatingSize);
    await _alignFloating();
    await _show(activate: activate);
  }

  Future<void> showConsentSurface() async {
    await windowManager.setMinimumSize(consentSize);
    await windowManager.setSize(consentSize);
    await _alignFloating();
  }

  /// Paints the native window behind whatever Flutter draws.
  ///
  /// Floating mode makes the window transparent for its rounded pill, and a
  /// transparent window shows black wherever Flutter has not painted. Every
  /// other surface -- sign-in, local setup, the library -- restores a solid
  /// chrome colour so a resize or a short layout can never expose one.
  Future<void> applyChromeBackground(Brightness brightness) =>
      windowManager.setBackgroundColor(
        brightness == Brightness.dark ? _darkChrome : _lightChrome,
      );

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
    final size = await fitToScreen(librarySize);
    await windowManager.setMinimumSize(_withinBounds(libraryMinimumSize, size));
    await applyChromeBackground(brightness);
    await windowManager.setSize(size);
    await windowManager.center();
    await _show();
  }

  Future<void> hide() => windowManager.hide();

  Future<void> show() => _show();

  Future<void> _show({bool activate = true}) async {
    await windowManager.show(inactive: !activate);
    if (activate) await windowManager.focus();
  }

  Future<void> _alignFloating() async {
    await windowManager.setAlignment(Alignment.bottomRight);
    final position = await windowManager.getPosition();
    await windowManager.setPosition(position - floatingScreenInset);
  }
}
