import 'package:flutter/material.dart';

import '../../../../main_shared.dart';
import '../../../../main_spacing.dart';
import '../../../../main_theme.dart';
import '../appliance_controller.dart';

/// The frame every appliance sheet is drawn in.
///
/// The device page, its settings and the setup flow had each written out the
/// same `DraggableScrollableSheet`, the same rounded-and-bordered container, the
/// same handle and the same `fromLTRB(20, 12, 20, 32)` list padding. They had
/// already drifted — different padding constants on different sheets, a gap
/// between some cards and none between others — which is what "the padding is
/// still bad" looks like from the outside.
///
/// One frame, one set of numbers, and the numbers come from [AppSpacing] rather
/// than from whatever looked right the day the sheet was written.
class ApplianceSheetScaffold extends StatelessWidget {
  const ApplianceSheetScaffold({
    super.key,
    required this.controller,
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
    this.initialSize = 0.82,
    this.minSize = 0.5,
    this.maxSize = 0.95,
    this.spaceChildren = true,
    this.showControllerMessage = true,
  });

  final ApplianceController controller;

  /// The sheet's own heading. A device name, which does not change underneath
  /// the sheet, so it is a value rather than a callback.
  final String title;

  /// The line under the heading, and the action beside it. Both are callbacks
  /// for the same reason [children] is: they are rebuilt whenever the appliance
  /// says something new, and a value captured by the caller's `build` would be
  /// the state as it was when the sheet opened. That is not theoretical — it is
  /// what made a live status line freeze the moment the sheet was on screen.
  final String? Function()? subtitle;
  final Widget? Function()? trailing;

  /// The cards, rebuilt on every change the appliance reports. Read the
  /// controller *inside* this callback — anything captured outside it is frozen
  /// at the moment the sheet opened.
  ///
  /// One gap of [AppSpacing.sm] is placed between each; the list's padding
  /// provides the space above the first and below the last, so a caller never
  /// adds its own.
  final List<Widget> Function(BuildContext context, NeoRecallPalette palette)
  children;

  final double initialSize;
  final double minSize;
  final double maxSize;

  /// Whether to put a gap between each child. True for a sheet of cards; false
  /// for the setup flow, whose steps are prose and controls that space
  /// themselves.
  final bool spaceChildren;

  /// Whether to show whatever the appliance last said. The setup flow keeps its
  /// own error — it has to say things the appliance never sent, like "this app
  /// is not signed in yet" — and showing both would print two messages about
  /// one failure.
  final bool showControllerMessage;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return DraggableScrollableSheet(
      initialChildSize: initialSize,
      minChildSize: minSize,
      maxChildSize: maxSize,
      expand: false,
      builder: (BuildContext context, ScrollController scrollController) =>
          Container(
            decoration: BoxDecoration(
              color: palette.bgSecondary,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.panel),
              ),
              border: Border.all(color: palette.border),
            ),
            child: AnimatedBuilder(
              animation: controller,
              builder: (BuildContext context, _) => ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xl,
                ),
                children: <Widget>[
                  const SheetHandle(),
                  _heading(palette),
                  const SizedBox(height: AppSpacing.md),
                  // Whatever the appliance last said about something the owner
                  // asked for. Every sheet gets this, because every sheet has a
                  // control that the appliance is entitled to refuse — and a
                  // refusal nobody shows is a control that "does nothing".
                  if (showControllerMessage &&
                      controller.message.isNotEmpty) ...<Widget>[
                    InlineMessage(
                      message: controller.message,
                      error: controller.messageIsError,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (spaceChildren)
                    ...spaced(children(context, palette))
                  else
                    ...children(context, palette),
                ],
              ),
            ),
          ),
    );
  }

  Widget _heading(NeoRecallPalette palette) {
    final String? line = subtitle?.call();
    final Widget? action = trailing?.call();
    return Row(
      children: <Widget>[
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (line != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                line,
                style: TextStyle(color: palette.textMuted, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      ?action,
    ],
    );
  }
}

/// The cards of a sheet, with one gap between each and none at either end.
List<Widget> spaced(List<Widget> cards) => <Widget>[
  for (var index = 0; index < cards.length; index += 1) ...<Widget>[
    if (index > 0) const SizedBox(height: AppSpacing.sm),
    cards[index],
  ],
];
