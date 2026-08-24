import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  test(
    'NeoRecall palette preserves the calm accent and visible recording color',
    () {
      expect(
        neoRecallPaletteFor(Brightness.dark).accent,
        const Color(0xFF8FA0FF),
      );
      expect(
        neoRecallPaletteFor(Brightness.dark).secondary,
        const Color(0xFFFF786D),
      );
      expect(
        neoRecallPaletteFor(Brightness.light).accent,
        const Color(0xFF5E73E8),
      );
      expect(
        neoRecallPaletteFor(Brightness.light).secondary,
        const Color(0xFFE5534B),
      );
    },
  );
}
