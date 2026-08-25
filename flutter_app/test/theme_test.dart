import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  test('NeoRecall palette follows the NeoAgent control-surface colors', () {
    expect(
      neoRecallPaletteFor(Brightness.dark).accent,
      const Color(0xFFE1B052),
    );
    expect(
      neoRecallPaletteFor(Brightness.dark).accentAlt,
      const Color(0xFF84BA87),
    );
    expect(
      neoRecallPaletteFor(Brightness.dark).secondary,
      const Color(0xFFDE8A78),
    );
    expect(
      neoRecallPaletteFor(Brightness.light).accent,
      const Color(0xFFB07D2B),
    );
    expect(
      neoRecallPaletteFor(Brightness.light).accentAlt,
      const Color(0xFF5E6B4C),
    );
    expect(
      neoRecallPaletteFor(Brightness.light).secondary,
      const Color(0xFFAE473C),
    );
  });
}
