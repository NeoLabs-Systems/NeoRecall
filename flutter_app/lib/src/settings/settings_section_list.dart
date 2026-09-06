import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';

/// The scrolling body every settings section sits in.
///
/// Carries the inline error for the section above its content. Transient
/// notices render in the app-wide status bar (see main_shell) and are
/// deliberately not repeated here.
class SettingsSectionList extends StatelessWidget {
  const SettingsSectionList({
    super.key,
    required this.controller,
    required this.children,
  });

  final NeoRecallController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(right: 2, bottom: 32),
      children: <Widget>[
        if (controller.error != null) ...<Widget>[
          InlineMessage(message: controller.error!, error: true),
          const SizedBox(height: 14),
        ],
        ...children,
      ],
    );
  }
}
