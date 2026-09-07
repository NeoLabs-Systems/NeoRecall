import 'package:flutter/material.dart';

import 'wifi_password_prompt.dart';

import '../../../../main_shared.dart';
import '../../../../main_spacing.dart';
import '../../../../main_theme.dart';
import '../../../record/record_controls.dart';
import '../../ble/gatt_transport.dart';
import '../appliance_controller.dart';
import '../appliance_link.dart';
import '../appliance_protocol.dart';
import 'appliance_sheet_scaffold.dart';
import '../../../../l10n/gen/app_l10n.dart';

/// Setting the appliance up, with nothing to type that a person should not have
/// to type.
///
/// The user picks the device, presses its button, picks a network, and types
/// that network's password. They never see a server address and never see an
/// access key — the app mints one on their behalf and sends it over the
/// encrypted link.
///
/// The button press in the middle is not ceremony. A device with no screen
/// cannot show a pairing code to compare, so the appliance only accepts pairing
/// while it is in setup mode, and the only way into setup mode is a physical
/// press. That press is the proof somebody is standing at it.
Future<bool> showApplianceSetupFlow(
  BuildContext context,
  ApplianceController controller,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) =>
        ApplianceSetupFlow(controller: controller),
  );
  return result ?? false;
}

enum _Step { looking, confirmPairing, chooseNetwork, finishing, done }

class ApplianceSetupFlow extends StatefulWidget {
  const ApplianceSetupFlow({super.key, required this.controller});

  final ApplianceController controller;

  @override
  State<ApplianceSetupFlow> createState() => _ApplianceSetupFlowState();
}

class _ApplianceSetupFlowState extends State<ApplianceSetupFlow> {
  _Step _step = _Step.looking;
  String _error = '';
  ApplianceCandidate? _chosen;
  final TextEditingController _deviceName = TextEditingController(
    text: 'NeoRecall Desk',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _look());
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _look() async {
    setState(() {
      _step = _Step.looking;
      _error = '';
    });
    final availability = await widget.controller.bluetoothAvailability();
    if (!mounted) return;
    if (availability == GattAvailability.poweredOff) {
      setState(() => _error = AppL10n.of(context).applianceBluetoothOff);
      return;
    }
    if (availability == GattAvailability.unsupported) {
      setState(
        () => _error = AppL10n.of(context).applianceBluetoothUnsupported,
      );
      return;
    }
    await widget.controller.scanForAppliances();
  }

  Future<void> _connect(ApplianceCandidate candidate) async {
    setState(() {
      _chosen = candidate;
      _step = _Step.confirmPairing;
      _error = '';
    });
    final connected = await widget.controller.connectTo(candidate, pair: true);
    if (!mounted) return;
    if (!connected) {
      setState(() {
        _step = _Step.looking;
        _error = AppL10n.of(context).appliancePairFailed;
      });
      return;
    }
    setState(() => _step = _Step.chooseNetwork);
    await widget.controller.lookForNetworks();
  }

  Future<void> _join(WifiNetwork network) async {
    // An open network needs no password, and asking for one would be a form
    // with nothing to put in it.
    final password = network.secured
        ? await askForWifiPassword(context, network.ssid)
        : '';
    if (password == null || !mounted) return;

    setState(() {
      _step = _Step.finishing;
      _error = '';
    });
    final sent = await widget.controller.completeSetup(
      wifiSsid: network.ssid,
      wifiPassword: password,
      deviceName: _deviceName.text.trim(),
    );
    if (!mounted) return;
    if (!sent) {
      setState(() {
        _step = _Step.chooseNetwork;
        _error = widget.controller.message;
      });
      return;
    }
    await _awaitConfirmation();
  }

  /// Wait for the appliance to say whether it worked.
  ///
  /// The app deliberately does not declare success on send: joining a network
  /// and reaching a server are things only the device can find out, and a wrong
  /// Wi-Fi password is the common case.
  Future<void> _awaitConfirmation() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final failure = widget.controller.setupFailure;
      if (failure != null) {
        setState(() {
          _step = _Step.chooseNetwork;
          _error = failure;
        });
        return;
      }
      if (widget.controller.setupSucceeded) {
        setState(() => _step = _Step.done);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!mounted) return;
    setState(() {
      _step = _Step.chooseNetwork;
      _error = AppL10n.of(context).applianceNoAnswer;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ApplianceSheetScaffold(
      controller: widget.controller,
      title: AppL10n.of(context).applianceAddTitle,
      initialSize: 0.75,
      minSize: 0.5,
      maxSize: 0.92,
      // The steps lay themselves out, and this flow phrases its own errors.
      spaceChildren: false,
      showControllerMessage: false,
      children: (BuildContext context, NeoRecallPalette palette) => <Widget>[
        if (_error.isNotEmpty) ...<Widget>[
          InlineMessage(message: _error, error: true),
          const SizedBox(height: AppSpacing.sm),
        ],
        ..._stepBody(palette),
      ],
    );
  }

  List<Widget> _stepBody(NeoRecallPalette palette) => switch (_step) {
    _Step.looking => _looking(palette),
    _Step.confirmPairing => _confirmPairing(palette),
    _Step.chooseNetwork => _chooseNetwork(palette),
    _Step.finishing => _finishing(palette),
    _Step.done => _done(palette),
  };

  List<Widget> _looking(NeoRecallPalette palette) {
    final found = widget.controller.candidates;
    return <Widget>[
      Text(
        AppL10n.of(context).applianceLookingIntro,
        style: TextStyle(color: palette.textMuted, fontSize: 14),
      ),
      const SizedBox(height: 18),
      if (widget.controller.isScanning && found.isEmpty)
        const Center(
          child: Padding(padding: EdgeInsets.all(24), child: ButtonSpinner()),
        )
      else if (found.isEmpty)
        EmptyState(
          icon: Icons.bluetooth_searching_rounded,
          title: AppL10n.of(context).applianceNothingFound,
          message: AppL10n.of(context).applianceNothingFoundMessage,
        )
      else
        for (final ApplianceCandidate candidate in found)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppPanel(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  Icon(Icons.speaker_group_outlined, color: palette.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      candidate.name,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _connect(candidate),
                    child: Text(AppL10n.of(context).applianceSetUpAction),
                  ),
                ],
              ),
            ),
          ),
      const SizedBox(height: 12),
      Center(
        child: TextButton.icon(
          onPressed: widget.controller.isScanning ? null : _look,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(
            widget.controller.isScanning
                ? AppL10n.of(context).applianceLooking
                : AppL10n.of(context).applianceLookAgain,
          ),
        ),
      ),
    ];
  }

  List<Widget> _confirmPairing(NeoRecallPalette palette) => <Widget>[
    Center(
      child: Column(
        children: <Widget>[
          Icon(Icons.touch_app_rounded, size: 56, color: palette.accent),
          const SizedBox(height: 16),
          Text(
            AppL10n.of(context).appliancePressButton(
              _chosen?.name ?? AppL10n.of(context).applianceTheDevice,
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppL10n.of(context).appliancePressButtonWhy,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          const ButtonSpinner(),
        ],
      ),
    ),
  ];

  List<Widget> _chooseNetwork(NeoRecallPalette palette) {
    final networks = widget.controller.networks;
    return <Widget>[
      SectionCard(
        eyebrow: AppL10n.of(context).applianceNameEyebrow,
        child: TextField(
          controller: _deviceName,
          decoration: InputDecoration(
            hintText: AppL10n.of(context).applianceNameHint,
            isDense: true,
          ),
        ),
      ),
      const SizedBox(height: 14),
      SectionCard(
        eyebrow: AppL10n.of(context).applianceNetworkEyebrow,
        trailing: TextButton.icon(
          onPressed: widget.controller.isLookingForNetworks
              ? null
              : widget.controller.lookForNetworks,
          icon: widget.controller.isLookingForNetworks
              ? const ButtonSpinner()
              : const Icon(Icons.refresh_rounded, size: 18),
          label: Text(AppL10n.of(context).actionRefresh),
        ),
        child: networks.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  widget.controller.isLookingForNetworks
                      ? AppL10n.of(context).applianceLookingForNetworks
                      : AppL10n.of(context).applianceNoNetworks,
                  style: TextStyle(color: palette.textMuted, fontSize: 13),
                ),
              )
            : Column(
                children: <Widget>[
                  for (final WifiNetwork network in networks.take(10))
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
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                      onTap: () => _join(network),
                    ),
                ],
              ),
      ),
    ];
  }

  List<Widget> _finishing(NeoRecallPalette palette) => <Widget>[
    Center(
      child: Column(
        children: <Widget>[
          const Padding(padding: EdgeInsets.all(24), child: ButtonSpinner()),
          Text(
            AppL10n.of(context).applianceSettingUp,
            style: TextStyle(color: palette.textPrimary, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            AppL10n.of(context).applianceSettingUpDetail,
            style: TextStyle(color: palette.textMuted, fontSize: 13),
          ),
        ],
      ),
    ),
  ];

  List<Widget> _done(NeoRecallPalette palette) => <Widget>[
    Center(
      child: Column(
        children: <Widget>[
          Icon(Icons.check_circle_rounded, size: 56, color: palette.success),
          const SizedBox(height: 16),
          Text(
            AppL10n.of(context).applianceDoneTitle,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppL10n.of(context).applianceDoneBody(_deviceName.text.trim()),
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppL10n.of(context).actionDone),
          ),
        ],
      ),
    ),
  ];
}
