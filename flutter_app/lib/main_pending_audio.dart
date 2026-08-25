import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/sync/pending_audio_preview.dart';

Future<void> showPendingAudioReviewSheet(
  BuildContext context,
  NeoRecallController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: neoRecallPaletteOf(context).surface,
  builder: (context) => _PendingAudioReviewSheet(controller: controller),
);

class _PendingAudioReviewSheet extends StatefulWidget {
  const _PendingAudioReviewSheet({required this.controller});

  final NeoRecallController controller;

  @override
  State<_PendingAudioReviewSheet> createState() =>
      _PendingAudioReviewSheetState();
}

class _PendingAudioReviewSheetState extends State<_PendingAudioReviewSheet> {
  List<PendingAudioRecording>? _recordings;
  String? _loadError;
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completeSubscription;
  PendingAudioRecording? _selected;
  PlayerState _playerState = PlayerState.stopped;
  Duration _partPosition = Duration.zero;
  double? _scrubPositionMs;
  int _partIndex = 0;
  int _operation = 0;
  bool _loadingPart = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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

  Future<void> _load() async {
    try {
      final recordings = await widget.controller.loadPendingAudioRecordings();
      if (!mounted) return;
      setState(() => _recordings = recordings);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.toString());
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
      final selected = _selected;
      if (selected == null) return;
      if (_partIndex + 1 < selected.parts.length) {
        unawaited(_loadPart(selected, _partIndex + 1, autoplay: true));
      } else if (mounted) {
        setState(() {
          _partPosition = selected.parts.last.duration;
          _playerState = PlayerState.completed;
        });
      }
    });
    return player;
  }

  Future<void> _toggle(PendingAudioRecording recording) async {
    if (_loadingPart) return;
    final player = _ensurePlayer();
    if (_selected?.id == recording.id) {
      if (_playerState == PlayerState.playing) {
        await player.pause();
      } else if (_playerState == PlayerState.completed) {
        await _loadPart(recording, 0, autoplay: true);
      } else {
        try {
          await player.resume();
        } catch (_) {
          await _loadPart(recording, _partIndex, autoplay: true);
        }
      }
      return;
    }
    await _loadPart(recording, 0, autoplay: true);
  }

  Future<void> _loadPart(
    PendingAudioRecording recording,
    int index, {
    required bool autoplay,
    Duration position = Duration.zero,
  }) async {
    final operation = ++_operation;
    setState(() {
      _selected = recording;
      _partIndex = index;
      _partPosition = position;
      _scrubPositionMs = null;
      _loadingPart = true;
      _loadError = null;
    });
    try {
      final part = recording.parts[index];
      final bytes = await widget.controller.readPendingAudioPart(part.id);
      if (!mounted || operation != _operation) return;
      final player = _ensurePlayer();
      await player.setSource(BytesSource(bytes, mimeType: part.mimeType));
      if (position > Duration.zero) await player.seek(position);
      if (autoplay) await player.resume();
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _selected = null;
        _loadError = error.toString().replaceFirst(
          RegExp(r'^(Bad state|StateError|Exception):\s*'),
          '',
        );
      });
    } finally {
      if (mounted && operation == _operation) {
        setState(() => _loadingPart = false);
      }
    }
  }

  Duration _partBase(PendingAudioRecording recording, int partIndex) =>
      recording.parts
          .take(partIndex)
          .fold(Duration.zero, (total, part) => total + part.duration);

  Duration _globalPosition(PendingAudioRecording recording) {
    final value = _partBase(recording, _partIndex) + _partPosition;
    return value > recording.duration ? recording.duration : value;
  }

  Future<void> _seek(PendingAudioRecording recording, Duration target) async {
    var preceding = Duration.zero;
    for (var index = 0; index < recording.parts.length; index += 1) {
      final part = recording.parts[index];
      final end = preceding + part.duration;
      if (target < end || index == recording.parts.length - 1) {
        final local = target - preceding;
        await _loadPart(
          recording,
          index,
          autoplay: _playerState == PlayerState.playing,
          position: local.isNegative ? Duration.zero : local,
        );
        return;
      }
      preceding = end;
    }
  }

  String _clock(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60).remainder(60);
    final seconds = totalSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _title(BuildContext context, DateTime startedAt) {
    final local = startedAt.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(local)} · '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  String _stage(PendingAudioPlaybackStage stage) => switch (stage) {
    PendingAudioPlaybackStage.needsAttention => 'Needs attention',
    PendingAudioPlaybackStage.onDevice => 'On this device',
    PendingAudioPlaybackStage.uploading => 'Uploading',
    PendingAudioPlaybackStage.serverProcessing => 'On server',
    PendingAudioPlaybackStage.finalizing => 'Finalizing',
  };

  Color _stageColor(
    NeoRecallPalette palette,
    PendingAudioPlaybackStage stage,
  ) => switch (stage) {
    PendingAudioPlaybackStage.needsAttention => palette.warning,
    PendingAudioPlaybackStage.onDevice => palette.accentAlt,
    PendingAudioPlaybackStage.uploading => palette.accent,
    PendingAudioPlaybackStage.serverProcessing => palette.info,
    PendingAudioPlaybackStage.finalizing => palette.success,
  };

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.13),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.headphones_rounded,
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
                          'Review queued audio',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Local playback only · upload continues normally',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (widget.controller.isRecording)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
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
                        'Recording is active. Use headphones to avoid recording the playback again.',
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline_rounded,
                      size: 17,
                      color: palette.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _loadError!,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _load, child: const Text('Refresh')),
                  ],
                ),
              ),
            Flexible(child: _body(palette)),
          ],
        ),
      ),
    );
  }

  Widget _body(NeoRecallPalette palette) {
    final recordings = _recordings;
    if (recordings == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(36),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (recordings.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 34),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.audio_file_outlined, size: 34, color: palette.textMuted),
            const SizedBox(height: 10),
            Text(
              'No retained audio is currently available to review.',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 22),
      itemCount: recordings.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _recordingCard(recordings[index]),
    );
  }

  Widget _recordingCard(PendingAudioRecording recording) {
    final palette = neoRecallPaletteOf(context);
    final selected = _selected?.id == recording.id;
    final playing = selected && _playerState == PlayerState.playing;
    final stageColor = _stageColor(palette, recording.stage);
    final globalPosition = selected
        ? _globalPosition(recording)
        : Duration.zero;
    final maxMs = recording.duration.inMilliseconds <= 0
        ? 1.0
        : recording.duration.inMilliseconds.toDouble();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected
            ? palette.accent.withValues(alpha: 0.08)
            : palette.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(
          color: selected
              ? palette.accent.withValues(alpha: 0.3)
              : palette.border,
        ),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 42,
                height: 42,
                child: IconButton.filledTonal(
                  tooltip: playing ? 'Pause' : 'Play',
                  onPressed: _loadingPart ? null : () => _toggle(recording),
                  icon: _loadingPart && selected
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _title(context, recording.startedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_clock(recording.duration)} · '
                      '${(recording.byteSize / 1048576).toStringAsFixed(1)} MB',
                      style: TextStyle(color: palette.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: stageColor.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  _stage(recording.stage),
                  style: TextStyle(
                    color: stageColor,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (selected) ...<Widget>[
            const SizedBox(height: 10),
            Slider(
              value:
                  (_scrubPositionMs ?? globalPosition.inMilliseconds.toDouble())
                      .clamp(0.0, maxMs)
                      .toDouble(),
              max: maxMs,
              onChanged: _loadingPart
                  ? null
                  : (value) => setState(() => _scrubPositionMs = value),
              onChangeEnd: _loadingPart
                  ? null
                  : (value) {
                      setState(() => _scrubPositionMs = null);
                      unawaited(
                        _seek(recording, Duration(milliseconds: value.round())),
                      );
                    },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: <Widget>[
                  Text(
                    _clock(
                      _scrubPositionMs == null
                          ? globalPosition
                          : Duration(milliseconds: _scrubPositionMs!.round()),
                    ),
                    style: TextStyle(color: palette.textMuted, fontSize: 10.5),
                  ),
                  const Spacer(),
                  Text(
                    _clock(recording.duration),
                    style: TextStyle(color: palette.textMuted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
