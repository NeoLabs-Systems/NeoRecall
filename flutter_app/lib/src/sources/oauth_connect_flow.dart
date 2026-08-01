import 'dart:async';

import 'package:flutter/material.dart';

import '../../main_controller.dart';
import 'open_url.dart';

/// Starts platform OAuth in the system browser and waits until the source appears.
class OauthConnectFlow {
  OauthConnectFlow(this.controller);

  final NeoRecallController controller;

  /// Opens the provider authorize URL and polls until [type] is connected or
  /// [timeout] elapses. Returns true when connected.
  Future<bool> connect(
    BuildContext context,
    String type, {
    Duration timeout = const Duration(minutes: 3),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final start = await controller.api.request(
      'GET',
      '/api/v1/sources/oauth/$type/start',
    ) as Map;
    final authorizeUrl = start['authorizeUrl'] as String?;
    if (authorizeUrl == null || authorizeUrl.isEmpty) {
      throw StateError('Server did not return an authorization URL.');
    }

    await openExternalUrl(authorizeUrl);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Complete sign-in in your browser. This screen will update when you are connected.'),
          duration: Duration(seconds: 6),
        ),
      );
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      try {
        final catalog = await controller.api.request('GET', '/api/v1/sources/catalog') as Map;
        final platforms = (catalog['platforms'] as List<dynamic>? ?? <dynamic>[]);
        for (final raw in platforms) {
          final platform = Map<String, dynamic>.from(raw as Map);
          if (platform['type'] == type && platform['connected'] == true) {
            return true;
          }
        }
      } catch (_) {
        // Keep polling through transient network blips.
      }
    }
    return false;
  }
}
