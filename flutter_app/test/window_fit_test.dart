import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/desktop/window_coordinator.dart';

void main() {
  const preferred = DesktopWindowCoordinator.librarySize;

  test('a roomy display gets the window at its intended size', () {
    expect(
      DesktopWindowCoordinator.clampToVisible(
        preferred,
        const Size(2560, 1440),
      ),
      preferred,
    );
  });

  test('a short work area shrinks the window instead of running off it', () {
    // 1280x800 laptop, menu bar and dock taken out.
    const visible = Size(1280, 700);
    final fitted = DesktopWindowCoordinator.clampToVisible(preferred, visible);
    expect(fitted.height, lessThan(preferred.height));
    expect(fitted.height, lessThanOrEqualTo(visible.height));
    expect(fitted.width, lessThanOrEqualTo(visible.width));
    expect(
      fitted.height,
      visible.height - DesktopWindowCoordinator.screenMargin,
    );
  });

  test('a narrow work area shrinks the width too', () {
    final fitted = DesktopWindowCoordinator.clampToVisible(
      preferred,
      const Size(1024, 1400),
    );
    expect(fitted.width, 1024 - DesktopWindowCoordinator.screenMargin);
    expect(fitted.height, preferred.height);
  });

  test('an implausibly small display still yields a usable window', () {
    final fitted = DesktopWindowCoordinator.clampToVisible(
      preferred,
      const Size(40, 30),
    );
    expect(fitted.width, greaterThan(0));
    expect(fitted.height, greaterThan(0));
  });
}
