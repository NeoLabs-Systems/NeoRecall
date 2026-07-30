import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_theme.dart';
import 'main_shared.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  bool loading = true;
  List<dynamic> sources = [];

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() => loading = true);
    try {
      final response = await widget.controller.api.request('GET', '/sources') as Map;
      setState(() {
        sources = response['sources'] as List<dynamic>;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load sources: $error')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _addSource() async {
    final result = await showDialog(
      context: context,
      builder: (context) => _AddSourceDialog(controller: widget.controller),
    );
    if (result == true) {
      _loadSources();
    }
  }

  Future<void> _toggleSource(Map<String, dynamic> source, bool enabled) async {
    try {
      await widget.controller.api.request('PATCH', '/sources/${source['id']}', body: {'enabled': enabled});
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update source: $error')));
      }
    }
  }

  Future<void> _deleteSource(Map<String, dynamic> source) async {
    try {
      await widget.controller.api.request('DELETE', '/sources/${source['id']}');
      _loadSources();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete source: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sources.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.input_rounded, size: 64, color: palette.textMuted),
              const SizedBox(height: 16),
              Text(
                'No Sources Configured',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add external sources like Discord bots here to feed audio into NeoRecall.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _addSource,
                icon: const Icon(Icons.add),
                label: const Text('Add Source'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: _addSource,
        backgroundColor: palette.accent,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: sources.length,
        itemBuilder: (context, index) {
          final source = sources[index];
          final typeName = source['type'] == 'discord' ? 'Discord Selfbot' : source['type'];
          return Card(
            color: palette.bgCard,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(
                source['type'] == 'discord' ? Icons.discord : Icons.input_rounded,
                color: palette.accent,
              ),
              title: Text(source['name'], style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w600)),
              subtitle: Text(typeName, style: TextStyle(color: palette.textSecondary)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: source['enabled'],
                    onChanged: (val) => _toggleSource(source, val),
                    activeColor: palette.accent,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: palette.danger),
                    onPressed: () => _deleteSource(source),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.controller});

  final NeoRecallController controller;

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _nameController = TextEditingController();
  final _tokenController = TextEditingController();
  final _usersController = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final token = _tokenController.text.trim();
    final users = _usersController.text.trim();

    if (name.isEmpty || token.isEmpty || users.isEmpty) return;

    setState(() => _saving = true);
    try {
      await widget.controller.api.request('POST', '/sources', body: {
        'type': 'discord',
        'name': name,
        'enabled': true,
        'config': {
          'token': token,
          'targetUsers': users,
        },
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);

    return AlertDialog(
      backgroundColor: palette.bgCard,
      title: Text('Add Discord Source', style: TextStyle(color: palette.textPrimary)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.danger),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: palette.danger),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'WARNING: Using a user token to automate joining and recording voice channels is a violation of Discord Terms of Service. This can lead to your account being permanently banned.',
                      style: TextStyle(color: palette.danger, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Source Name',
                labelStyle: TextStyle(color: palette.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.accent)),
              ),
              style: TextStyle(color: palette.textPrimary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Discord User Token',
                labelStyle: TextStyle(color: palette.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.accent)),
              ),
              obscureText: true,
              style: TextStyle(color: palette.textPrimary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersController,
              decoration: InputDecoration(
                labelText: 'Target User IDs (comma separated)',
                labelStyle: TextStyle(color: palette.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: palette.accent)),
              ),
              style: TextStyle(color: palette.textPrimary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(backgroundColor: palette.accent),
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save Source', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
