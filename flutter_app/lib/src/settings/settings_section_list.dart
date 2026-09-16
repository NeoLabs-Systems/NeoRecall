import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';

/// The scrolling body every settings section sits in.
///
/// Cards are spaced by this list rather than by each section remembering a gap
/// after itself — the same rule the general/recording panes use, so Security,
/// Integrations and Watch line up with the rest of Settings.
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
    final blocks = <Widget>[
      if (controller.error != null)
        InlineMessage(message: controller.error!, error: true),
      ...children,
    ];
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      itemCount: blocks.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm + 2),
      itemBuilder: (context, index) => blocks[index],
    );
  }
}
