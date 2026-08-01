import 'package:flutter/material.dart';

/// Client-side presentation metadata for source integrations.
///
/// Meeting platforms also come from the server catalog; this map supplies
/// icons and fallbacks when the catalog is unavailable.
class SourcePlatformCopy {
  const SourcePlatformCopy({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    this.auth = 'manual',
    this.prerequisites = const <String>[],
    this.connectLabel = 'Setup',
  });

  final String id;
  final String name;
  final IconData icon;
  final String description;
  final String auth;
  final List<String> prerequisites;
  final String connectLabel;
}

const List<SourcePlatformCopy> kStaticIntegrations = <SourcePlatformCopy>[
  SourcePlatformCopy(
    id: 'discord',
    name: 'Discord',
    icon: Icons.discord,
    description: 'Automatically record specific users in voice channels you join.',
    auth: 'manual',
    connectLabel: 'Setup',
  ),
  SourcePlatformCopy(
    id: 'plaud',
    name: 'PLAUD',
    icon: Icons.cloud_sync_outlined,
    description: 'Import recordings from your PLAUD wearable via your PLAUD account.',
    auth: 'manual',
    connectLabel: 'Setup',
  ),
  SourcePlatformCopy(
    id: 'google_meet',
    name: 'Google Meet',
    icon: Icons.video_call_outlined,
    description: 'Import cloud recordings from Google Meet after each call.',
    auth: 'oauth',
    connectLabel: 'Connect Google',
    prerequisites: <String>[
      'Google Workspace account that can record Meet calls',
      'Recordings saved to Google Drive',
    ],
  ),
  SourcePlatformCopy(
    id: 'zoom',
    name: 'Zoom',
    icon: Icons.videocam_outlined,
    description: 'Import cloud recordings from your Zoom account after each meeting.',
    auth: 'oauth',
    connectLabel: 'Connect Zoom',
    prerequisites: <String>[
      'Zoom account with cloud recording enabled',
    ],
  ),
  SourcePlatformCopy(
    id: 'microsoft_teams',
    name: 'Microsoft Teams',
    icon: Icons.groups_outlined,
    description: 'Import cloud recordings from Microsoft Teams meetings you organize.',
    auth: 'oauth',
    connectLabel: 'Connect Microsoft',
    prerequisites: <String>[
      'Microsoft work or school account that can record Teams meetings',
      'Access as meeting organizer for recordings',
    ],
  ),
];

SourcePlatformCopy? copyFor(String id) {
  for (final item in kStaticIntegrations) {
    if (item.id == id) return item;
  }
  return null;
}

IconData iconFor(String id) => copyFor(id)?.icon ?? Icons.extension_outlined;
