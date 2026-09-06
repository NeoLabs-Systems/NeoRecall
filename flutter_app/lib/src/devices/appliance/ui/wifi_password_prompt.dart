import 'package:flutter/material.dart';

/// Ask for a Wi-Fi password.
///
/// Both places that need this — first-time setup and changing networks later —
/// were carrying an identical copy of the same forty-nine lines. One dialog
/// means the two cannot drift apart: whatever is true of the password field
/// during setup stays true when somebody moves the appliance to another network.
///
/// Returns the password, or null when the person backed out. An empty string is
/// a real answer: it means an open network.
Future<String?> askForWifiPassword(BuildContext context, String ssid) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _WifiPasswordPrompt(ssid: ssid),
  );
}

class _WifiPasswordPrompt extends StatefulWidget {
  const _WifiPasswordPrompt({required this.ssid});

  final String ssid;

  @override
  State<_WifiPasswordPrompt> createState() => _WifiPasswordPromptState();
}

class _WifiPasswordPromptState extends State<_WifiPasswordPrompt> {
  final TextEditingController _password = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.ssid),
    content: TextField(
      controller: _password,
      autofocus: true,
      obscureText: _obscured,
      decoration: InputDecoration(
        labelText: 'Network password',
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscured ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          ),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
      onSubmitted: (String value) => Navigator.of(context).pop(value),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(_password.text),
        child: const Text('Join'),
      ),
    ],
  );
}
