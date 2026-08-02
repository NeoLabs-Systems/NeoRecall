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
  /// Discord voice + Meet / Zoom / Teams notetaker bots — same product surface.
  liveCapture,
  /// Wearable / import accounts (PLAUD).
  import,
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
  SourcePlatformCopy(
    id: 'meeting',
    name: 'Meetings',
    icon: Icons.video_call_outlined,
    description:
        'Joins Google Meet, Zoom, or Microsoft Teams as a notetaker bot and records live audio during the call.',
    auth: 'manual',
    category: SourceCategory.liveCapture,
    connectLabel: 'Join a meeting',
    prerequisites: <String>[
      'Paste a Meet, Zoom, or Teams meeting link',
      'Optional: connect your account so the bot is admitted (not as a guest)',
    ],
  ),
  SourcePlatformCopy(
    id: 'plaud',
    name: 'PLAUD',
    icon: Icons.cloud_sync_outlined,
    description: 'Import recordings from your PLAUD wearable via your PLAUD account.',
    auth: 'manual',
    category: SourceCategory.import,
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
