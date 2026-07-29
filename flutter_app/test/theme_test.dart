import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  test(
    'NeoRecall palette preserves the family accent and product recording color',
    () {
      expect(
        neoRecallPaletteFor(Brightness.dark).accent,
        const Color(0xFFE1B052),
      );
      expect(
        neoRecallPaletteFor(Brightness.dark).secondary,
        const Color(0xFFD98AA6),
      );
      expect(
        neoRecallPaletteFor(Brightness.light).accent,
        const Color(0xFFB07D2B),
      );
      expect(
        neoRecallPaletteFor(Brightness.light).secondary,
        const Color(0xFFA8506E),
      );
    },
  );
}
