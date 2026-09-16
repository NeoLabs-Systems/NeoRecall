import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/models/timeline_moment.dart';
import 'src/sync/pending_audio_preview.dart';
import 'src/widgets/local_audio_transport.dart';
import 'l10n/gen/app_l10n.dart';

Future<void> showMomentAudioSheet(
  BuildContext context,
  NeoRecallController controller,
  TimelineMoment moment,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: neoRecallPaletteOf(context).surface,
    builder: (context) =>
        _MomentAudioSheet(controller: controller, moment: moment),
  );
}

class _MomentAudioSheet extends StatefulWidget {
  const _MomentAudioSheet({required this.controller, required this.moment});

  final NeoRecallController controller;
  final TimelineMoment moment;

  @override
  State<_MomentAudioSheet> createState() => _MomentAudioSheetState();
}

class _MomentAudioSheetState extends State<_MomentAudioSheet> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completeSubscription;
  List<PendingAudioPart> _parts = const <PendingAudioPart>[];
  final Map<int, Duration> _measured = <int, Duration>{};
  PlayerState _playerState = PlayerState.stopped;
  Duration _partPosition = Duration.zero;
  double? _scrubMs;
  int _partIndex = 0;
  int _operation = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _operation += 1;
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _completeSubscription?.cancel();
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final parts = await widget.controller.loadMomentAudio(widget.moment);
      if (!mounted) return;
      if (parts.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'This recording is no longer kept on this device.';
        });
        return;
      }
      _parts = parts;
      await _loadPart(0, autoplay: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst(
          RegExp(r'^(Bad state|StateError|Exception):\s*'),
          '',
        );
      });
    }
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    _stateSubscription = player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });
    _positionSubscription = player.onPositionChanged.listen((position) {
      if (mounted) setState(() => _partPosition = position);
    });
    _completeSubscription = player.onPlayerComplete.listen((_) {
      if (_partIndex + 1 < _parts.length) {
        unawaited(_loadPart(_partIndex + 1, autoplay: true));
      } else if (mounted) {
        setState(() {
          _partPosition = _partDuration(_partIndex);
          _playerState = PlayerState.completed;
        });
      }
    });
    return player;
  }

  Future<void> _loadPart(
    int index, {
    required bool autoplay,
    Duration position = Duration.zero,
  }) async {
    final operation = ++_operation;
    setState(() {
      _partIndex = index;
      _partPosition = position;
      _scrubMs = null;
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.controller.readRetainedAudioPart(
        _parts[index].id,
      );
      if (!mounted || operation != _operation) return;
      final player = _ensurePlayer();
      await player.setSource(
        BytesSource(bytes, mimeType: _parts[index].mimeType),
      );
      final measured = await player.getDuration();
      if (measured != null && measured > Duration.zero) {
        _measured[index] = measured;
      }
      if (position > Duration.zero) await player.seek(position);
      if (autoplay) await player.resume();
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _error = error.toString().replaceFirst(
          RegExp(r'^(Bad state|StateError|Exception):\s*'),
          '',
        );
      });
    } finally {
      if (mounted && operation == _operation) {
        setState(() => _loading = false);
      }
    }
  }

  Duration _partDuration(int index) {
    if (index < 0 || index >= _parts.length) return Duration.zero;
    final measured = _measured[index];
    if (measured != null && measured > Duration.zero) return measured;
    if (_parts[index].duration > Duration.zero) return _parts[index].duration;
    return Duration.zero;
  }

  Duration get _totalDuration {
    var sum = Duration.zero;
    for (var i = 0; i < _parts.length; i += 1) {
      sum += _partDuration(i);
    }
    if (sum > Duration.zero) return sum;
    final span = widget.moment.endedAt.difference(widget.moment.startedAt);
    return span.isNegative ? Duration.zero : span;
  }

  Duration get _globalPosition {
    var preceding = Duration.zero;
    for (var i = 0; i < _partIndex; i += 1) {
      preceding += _partDuration(i);
    }
    final value = preceding + _partPosition;
    final total = _totalDuration;
    return value > total ? total : value;
  }

  Future<void> _seek(Duration target) async {
    var preceding = Duration.zero;
    for (var index = 0; index < _parts.length; index += 1) {
      final end = preceding + _partDuration(index);
      if (target < end || index == _parts.length - 1) {
        final local = target - preceding;
        await _loadPart(
          index,
          autoplay: _playerState == PlayerState.playing,
          position: local.isNegative ? Duration.zero : local,
        );
        return;
      }
      preceding = end;
    }
  }

  Future<void> _toggle() async {
    if (_loading || _parts.isEmpty) return;
    final player = _ensurePlayer();
    if (_playerState == PlayerState.playing) {
      await player.pause();
    } else if (_playerState == PlayerState.completed) {
      await _loadPart(0, autoplay: true);
    } else {
      try {
        await player.resume();
      } catch (_) {
        await _loadPart(_partIndex, autoplay: true);
      }
    }
  }

  String _title(BuildContext context) {
    final generated = widget.moment.titleEn?.trim();
    if (generated != null && generated.isNotEmpty) return generated;
    return widget.moment.isPending ? 'Just recorded' : 'Conversation';
  }

  String _subtitle(BuildContext context) {
    final local = widget.moment.startedAt.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(local)} · '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    color: palette.accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _title(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _subtitle(context),
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: AppL10n.of(context).actionClose,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (widget.controller.isRecording)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: palette.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  border: Border.all(
                    color: palette.warning.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.headset_rounded,
                      size: 17,
                      color: palette.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppL10n.of(context).audioHeadphonesWarning,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  _error!,
                  style: TextStyle(color: palette.textSecondary, fontSize: 13),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 18),
              LocalAudioTransport(
                playing: _playerState == PlayerState.playing,
                loading: _loading,
                position: _globalPosition,
                duration: _totalDuration,
                scrubMs: _scrubMs,
                onPlayPause: _toggle,
                onSkipBack: () => unawaited(
                  _seek(_globalPosition - LocalAudioTransport.skip),
                ),
                onSkipForward: () => unawaited(
                  _seek(_globalPosition + LocalAudioTransport.skip),
                ),
                onScrub: (value) => setState(() => _scrubMs = value),
                onScrubEnd: (value) {
                  setState(() => _scrubMs = null);
                  unawaited(_seek(Duration(milliseconds: value.round())));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
