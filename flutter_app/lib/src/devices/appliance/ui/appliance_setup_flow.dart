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
      setState(() => _error = 'Turn Bluetooth on to set up a device.');
      return;
    }
    if (availability == GattAvailability.unsupported) {
      setState(() => _error = 'This device cannot use Bluetooth.');
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
        _error =
            'Could not pair. Hold the button on the device for five seconds '
            'until it beeps three times, then try again.';
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
      _error = 'The device did not answer. Check the network and try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ApplianceSheetScaffold(
      controller: widget.controller,
      title: 'Add a NeoRecall Desk',
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
        'Plug the device in and wait for its short rising tone. If it has been '
        'set up before, hold its button for five seconds first.',
        style: TextStyle(color: palette.textMuted, fontSize: 14),
      ),
      const SizedBox(height: 18),
      if (widget.controller.isScanning && found.isEmpty)
        const Center(
          child: Padding(padding: EdgeInsets.all(24), child: ButtonSpinner()),
        )
      else if (found.isEmpty)
        const EmptyState(
          icon: Icons.bluetooth_searching_rounded,
          title: 'Nothing found yet',
          message:
              'Hold the button on the device for five seconds, then look again.',
        )
      else
        for (final ApplianceCandidate candidate in found)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassSurface(
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
                    child: const Text('Set up'),
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
          label: Text(widget.controller.isScanning ? 'Looking…' : 'Look again'),
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
            'Press the button on ${_chosen?.name ?? 'the device'}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The device has no screen, so pressing its button is how it knows '
            'the request came from someone standing next to it.',
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
        eyebrow: 'NAME',
        child: TextField(
          controller: _deviceName,
          decoration: const InputDecoration(
            hintText: 'Desk in the study',
            isDense: true,
          ),
        ),
      ),
      const SizedBox(height: 14),
      SectionCard(
        eyebrow: 'NETWORK',
        trailing: TextButton.icon(
          onPressed: widget.controller.isLookingForNetworks
              ? null
              : widget.controller.lookForNetworks,
          icon: widget.controller.isLookingForNetworks
              ? const ButtonSpinner()
              : const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Refresh'),
        ),
        child: networks.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  widget.controller.isLookingForNetworks
                      ? 'Looking for networks…'
                      : 'No networks found yet.',
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
            'Setting the device up…',
            style: TextStyle(color: palette.textPrimary, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            'It is joining your network and signing in.',
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
            'Ready',
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose "${_deviceName.text.trim()}" as the speaker and microphone '
            'on your computer, then press its button to record.',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  ];
}
