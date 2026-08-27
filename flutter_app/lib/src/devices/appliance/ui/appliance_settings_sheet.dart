import 'package:flutter/material.dart';

import 'wifi_password_prompt.dart';

import '../../../../main_shared.dart';
import '../../../../main_spacing.dart';
import '../../../../main_theme.dart';
import '../../../record/record_controls.dart';
import '../appliance_controller.dart';
import '../appliance_protocol.dart';
import 'appliance_sheet_scaffold.dart';

/// The second level: things that are set once and then forgotten.
///
/// Kept separate from the device page on purpose. Everything here is a decision
/// somebody makes when they set the device up or change their mind — none of it
/// belongs in the way of "am I recording?".
Future<void> showApplianceSettingsSheet(
  BuildContext context,
  ApplianceController controller, {
  required String deviceName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) =>
        ApplianceSettingsSheet(controller: controller, deviceName: deviceName),
  );
}

class ApplianceSettingsSheet extends StatefulWidget {
  const ApplianceSettingsSheet({
    super.key,
    required this.controller,
    required this.deviceName,
  });

  final ApplianceController controller;
  final String deviceName;

  @override
  State<ApplianceSettingsSheet> createState() => _ApplianceSettingsSheetState();
}

class _ApplianceSettingsSheetState extends State<ApplianceSettingsSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.deviceName,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ApplianceSheetScaffold(
      controller: widget.controller,
      title: 'Device settings',
      initialSize: 0.7,
      minSize: 0.4,
      maxSize: 0.92,
      children: (BuildContext context, NeoRecallPalette palette) => <Widget>[
        _nameSection(palette),
        _networkSection(palette),
        _checkSection(palette),
        _softwareSection(palette),
        _removeSection(palette),
      ],
    );
  }

  Widget _nameSection(NeoRecallPalette palette) => SectionCard(
    eyebrow: 'NAME',
    child: Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(
              hintText: 'Desk in the study',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: widget.controller.isConnected
              ? () => widget.controller.rename(_name.text.trim())
              : null,
          child: const Text('Save'),
        ),
      ],
    ),
  );

  Widget _networkSection(NeoRecallPalette palette) {
    final controller = widget.controller;
    final status = controller.status;
    return SectionCard(
      eyebrow: 'NETWORK',
      trailing: TextButton.icon(
        onPressed: !controller.isConnected || controller.isLookingForNetworks
            ? null
            : controller.lookForNetworks,
        icon: controller.isLookingForNetworks
            ? const ButtonSpinner()
            : const Icon(Icons.refresh_rounded, size: 18),
        label: Text(controller.isLookingForNetworks ? 'Looking…' : 'Change'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            status?.networkOnline ?? false
                ? 'Connected. Recordings are sent when you stop recording.'
                : 'Not connected. Recordings are kept on the device until it is.',
            style: TextStyle(color: palette.textMuted, fontSize: 13),
          ),
          if (controller.networks.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            for (final WifiNetwork network in controller.networks.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  network.secured
                      ? Icons.wifi_lock_rounded
                      : Icons.wifi_rounded,
                  color: palette.textMuted,
                  size: 20,
                ),
                title: Text(
                  network.ssid,
                  style: TextStyle(color: palette.textPrimary, fontSize: 14),
                ),
                onTap: () => _joinNetwork(network),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _joinNetwork(WifiNetwork network) async {
    final password = await askForWifiPassword(context, network.ssid);
    if (password == null || !mounted) return;
    await widget.controller.completeSetup(
      wifiSsid: network.ssid,
      wifiPassword: password,
      deviceName: _name.text.trim(),
    );
  }

  /// A line of explanation with one action against it, busy or not.
  ///
  /// The sound check and the software section are the same shape: something to
  /// read on the left, and on the right either a button or the spinner that
  /// replaces it while the device is working. They were written out twice and
  /// had already drifted — one used 12 points of separation, the other none,
  /// and only one of them disabled its button while the link was busy.
  Widget _actionRow({
    required Widget label,
    required String action,
    required bool busy,
    required VoidCallback? onPressed,
  }) => Row(
    children: <Widget>[
      Expanded(child: label),
      const SizedBox(width: AppSpacing.sm),
      if (busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: ButtonSpinner(),
        )
      else
        TextButton(onPressed: onPressed, child: Text(action)),
    ],
  );

  Widget _checkSection(NeoRecallPalette palette) {
    final controller = widget.controller;
    final checks = controller.checks;
    return SectionCard(
      eyebrow: 'SOUND CHECK',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _actionRow(
            // The device answers this itself: it plays a tone and listens for
            // it, so nobody has to be in the room to say what they heard.
            label: Text(
              'Have the device play a tone and listen for it.',
              style: TextStyle(color: palette.textMuted, fontSize: 12.5),
            ),
            action: 'Check',
            busy: controller.isChecking,
            onPressed: controller.isConnected && !controller.isBusy
                ? controller.runSelfTest
                : null,
          ),
          if (checks.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            for (final ApplianceCheck check in checks)
              _checkVerdict(palette, check),
          ],
        ],
      ),
    );
  }

  Widget _checkVerdict(NeoRecallPalette palette, ApplianceCheck check) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          check.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          size: 18,
          color: check.ok ? palette.success : palette.danger,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                check.name,
                style: TextStyle(color: palette.textPrimary, fontSize: 14),
              ),
              if (check.detail.isNotEmpty)
                Text(
                  check.detail,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _softwareSection(NeoRecallPalette palette) {
    final controller = widget.controller;
    final status = controller.status;
    final version = status?.firmware ?? '';
    return SectionCard(
      eyebrow: 'SOFTWARE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _actionRow(
            label: Text(
              version.isEmpty ? 'Version unknown' : 'Version $version',
              style: TextStyle(color: palette.textPrimary, fontSize: 15),
            ),
            action: 'Check now',
            busy: status?.isUpdating ?? false,
            onPressed: controller.isConnected && !controller.isBusy
                ? controller.checkForUpdate
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: status?.autoUpdate ?? true,
            onChanged: controller.isConnected
                ? (bool value) => controller.useAutomaticUpdates(value)
                : null,
            title: Text(
              'Keep this device up to date',
              style: TextStyle(color: palette.textPrimary, fontSize: 15),
            ),
            subtitle: Text(
              // Say what it will and will not do. "Updates automatically" on a
              // recorder invites the obvious worry, and the answer is good.
              'Checks once a day and installs new versions by itself. It never '
              'interrupts a recording — an update waits until you have stopped.',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _removeSection(NeoRecallPalette palette) => SectionCard(
    eyebrow: 'REMOVE',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Takes this device off your account. Recordings already sent stay in '
          'NeoRecall; anything still waiting on the device is lost.',
          style: TextStyle(color: palette.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: widget.controller.isConnected ? _confirmRemoval : null,
          icon: Icon(Icons.link_off_rounded, color: palette.danger, size: 18),
          label: Text(
            'Remove this device',
            style: TextStyle(color: palette.danger),
          ),
        ),
      ],
    ),
  );

  Future<void> _confirmRemoval() async {
    final status = widget.controller.status;
    final pending = status?.pendingRecordings ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: Text(
          pending > 0
              // Naming the real cost rather than a generic warning.
              ? 'It still has $pending recording${pending == 1 ? '' : 's'} that '
                    'have not been sent. Removing it now loses them.'
              : 'You can set it up again at any time by holding its button for '
                    'five seconds.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.removeFromAccount();
    if (mounted) Navigator.of(context).pop();
  }
}
