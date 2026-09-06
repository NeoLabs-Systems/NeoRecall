import 'package:flutter/material.dart';

/// Client-side presentation metadata for source integrations.
class SourcePlatformCopy {
  const SourcePlatformCopy({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    this.auth = 'manual',
    this.category = SourceCategory.liveCapture,
    this.prerequisites = const <String>[],
    this.connectLabel = 'Setup',
  });

  final String id;
  final String name;
  final IconData icon;
  final String description;
  final String auth;
  final SourceCategory category;
  final List<String> prerequisites;
  final String connectLabel;
}

enum SourceCategory {
  /// Sources that capture audio while a call is active.
  liveCapture,
}

const List<SourcePlatformCopy> kStaticIntegrations = <SourcePlatformCopy>[
  SourcePlatformCopy(
    id: 'discord',
    name: 'Discord',
    icon: Icons.discord,
    description:
        'Joins voice channels as your bot and records when people you list are present.',
    auth: 'manual',
    category: SourceCategory.liveCapture,
    connectLabel: 'Setup',
  ),
];

SourcePlatformCopy? copyFor(String id) {
  for (final item in kStaticIntegrations) {
    if (item.id == id) return item;
  }
  return null;
}

IconData iconFor(String id) => copyFor(id)?.icon ?? Icons.extension_outlined;
