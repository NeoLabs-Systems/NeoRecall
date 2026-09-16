import 'dart:async';

import 'package:flutter/material.dart';

import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../sync/processing_status.dart';
import '../../l10n/gen/app_l10n.dart';

class ProcessingStatusPanel extends StatefulWidget {
  const ProcessingStatusPanel({
    super.key,
    required this.status,
    required this.onRetry,
    required this.onUploadWithMobileData,
    required this.onReview,
  });

  final ProcessingStatusSnapshot status;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUploadWithMobileData;
  final VoidCallback onReview;

  @override
  State<ProcessingStatusPanel> createState() => _ProcessingStatusPanelState();
}

class _ProcessingStatusPanelState extends State<ProcessingStatusPanel> {
  bool _expanded = false;
  bool _retrying = false;
  bool _uploadingWithMobileData = false;

  String _eta(Duration duration, AppL10n l10n) {
    if (duration.inSeconds < 45) return l10n.processingEtaUnderMinute;
    if (duration.inMinutes < 60) {
      return l10n.processingEtaMinutes((duration.inSeconds / 60).ceil());
    }
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return minutes < 10
        ? l10n.processingEtaHours(hours)
        : l10n.processingEtaHoursMinutes(hours, minutes);
  }

  String _headline(ProcessingStatusSnapshot status, AppL10n l10n) {
    if (status.hasIssues &&
        status.activeStage == ProcessingPipelineStage.phoneQueue) {
      return l10n.processingNeedsAttention;
    }
    return switch (status.activeStage) {
      ProcessingPipelineStage.watchTransfer =>
        l10n.processingStageWatchTransfer,
      ProcessingPipelineStage.phoneQueue => l10n.processingStagePhoneQueue,
      ProcessingPipelineStage.upload => l10n.processingStageUpload,
      ProcessingPipelineStage.serverQueue => l10n.processingStageServerQueue,
      ProcessingPipelineStage.transcription =>
        l10n.processingStageTranscription,
      ProcessingPipelineStage.finalizing => l10n.processingStageFinalizing,
      ProcessingPipelineStage.complete => l10n.processingStageComplete,
    };
  }

  IconData _icon(ProcessingStatusSnapshot status) {
    if (status.hasIssues) return Icons.sync_problem_rounded;
    return switch (status.activeStage) {
      ProcessingPipelineStage.watchTransfer => Icons.bluetooth_audio_rounded,
      ProcessingPipelineStage.phoneQueue => Icons.phone_android_rounded,
      ProcessingPipelineStage.upload => Icons.cloud_upload_rounded,
      ProcessingPipelineStage.serverQueue => Icons.hourglass_top_rounded,
      ProcessingPipelineStage.transcription => Icons.graphic_eq_rounded,
      ProcessingPipelineStage.finalizing => Icons.verified_user_outlined,
      ProcessingPipelineStage.complete => Icons.verified_rounded,
    };
  }

  List<_ProcessingStepData> _steps(
    ProcessingStatusSnapshot status,
    AppL10n l10n,
  ) {
    final watchDetail = status.watchPendingSeconds > 0
        ? l10n.processingWatchAudioWaiting(
            _shortDuration(Duration(seconds: status.watchPendingSeconds)),
          )
        : status.watchTransferActive
        ? l10n.processingWatchReceiving
        : status.watchPending > 0
        ? l10n.processingWatchItemsWaiting(status.watchPending)
        : l10n.processingWatchNoBacklog;
    final serverTotal = status.serverQueued + status.transcribing;
    return <_ProcessingStepData>[
      _ProcessingStepData(
        icon: Icons.bluetooth_audio_rounded,
        title: l10n.processingStepDeviceTransfer,
        detail: watchDetail,
        count: status.watchPending,
        active: status.watchTransferActive || status.watchPending > 0,
        fraction: status.watchFraction,
      ),
      _ProcessingStepData(
        icon: Icons.phone_android_rounded,
        title: l10n.processingStepStoredOnPhone,
        detail: status.phoneQueued == 0
            ? l10n.processingNoLocalQueue
            : l10n.processingReadyForUpload(status.phoneQueued),
        count: status.phoneQueued,
        active: status.phoneQueued > 0,
      ),
      _ProcessingStepData(
        icon: Icons.cloud_upload_rounded,
        title: l10n.processingStepServerUpload,
        detail: status.uploading == 0
            ? l10n.processingNoUploadInFlight
            : l10n.processingUploadingNow(status.uploading),
        count: status.uploading,
        active: status.uploading > 0,
      ),
      _ProcessingStepData(
        icon: Icons.graphic_eq_rounded,
        title: l10n.processingStepServerTranscription,
        detail: status.transcribing > 0
            ? l10n.processingTranscribingQueued(
                status.transcribing,
                status.serverQueued,
              )
            : serverTotal > 0
            ? l10n.processingWaitingForWorker(serverTotal)
            : l10n.processingServerQueueClear,
        count: serverTotal,
        active: serverTotal > 0,
      ),
      _ProcessingStepData(
        icon: Icons.verified_user_outlined,
        title: l10n.processingStepSafeCompletion,
        detail: status.complete
            ? l10n.processingTranscriptPersisted
            : status.finalizing > 0
            ? l10n.processingVerifying(status.finalizing)
            : l10n.processingWaitingEarlierStages,
        count: status.finalizing,
        active: status.finalizing > 0,
        complete: status.complete,
      ),
    ];
  }

  String _shortDuration(Duration duration) {
    if (duration.inMinutes < 1) return '${duration.inSeconds}s';
    if (duration.inHours < 1) return '${duration.inMinutes}m';
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }

  String _audioDuration(Duration duration) {
    if (duration.inMinutes < 1) return '${duration.inSeconds}s audio';
    if (duration.inHours < 1) {
      final seconds = duration.inSeconds.remainder(60);
      return seconds == 0
          ? '${duration.inMinutes}m audio'
          : '${duration.inMinutes}m ${seconds}s audio';
    }
    final minutes = duration.inMinutes.remainder(60);
    return minutes == 0
        ? '${duration.inHours}h audio'
        : '${duration.inHours}h ${minutes}m audio';
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _uploadWithMobileData() async {
    setState(() => _uploadingWithMobileData = true);
    try {
      await widget.onUploadWithMobileData();
    } finally {
      if (mounted) setState(() => _uploadingWithMobileData = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final status = widget.status;
    final color = status.hasIssues
        ? palette.warning
        : status.complete
        ? palette.success
        : palette.accent;
    final facts = <String>[
      if (status.totalPending + status.watchPending > 0)
        strings.processingPendingCount(
          status.totalPending + status.watchPending,
        ),
      if (status.totalAudioDuration > Duration.zero)
        _audioDuration(status.totalAudioDuration),
      if (status.pendingBytes > 0)
        strings.processingMbProtected(
          (status.pendingBytes / 1048576).toStringAsFixed(1),
        ),
      if (status.eta != null)
        strings.processingEtaPrefix(_eta(status.eta!, strings)),
      if (status.eta == null && status.etaCalibrating)
        strings.processingEtaCalibrating,
    ];
    final steps = _steps(status, strings);

    return Semantics(
      button: true,
      expanded: _expanded,
      label: '${_headline(status, strings)}. ${facts.join(', ')}',
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.075),
          borderRadius: BorderRadius.circular(AppRadius.input),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.input),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 10, 11),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_icon(status), size: 19, color: color),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _headline(status, strings),
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (facts.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  facts.join(' · '),
                                  style: TextStyle(
                                    color: palette.textMuted,
                                    fontSize: 11.5,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: palette.textMuted,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        for (
                          var index = 0;
                          index < steps.length;
                          index++
                        ) ...<Widget>[
                          Expanded(
                            child: Tooltip(
                              message: steps[index].title,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                height: 4,
                                decoration: BoxDecoration(
                                  color: steps[index].complete
                                      ? palette.success
                                      : steps[index].active
                                      ? color
                                      : palette.border,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                          if (index != steps.length - 1)
                            const SizedBox(width: 4),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (status.waitingForUnmeteredNetwork)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey<String>('upload-with-mobile-data'),
                    onPressed: _uploadingWithMobileData
                        ? null
                        : _uploadWithMobileData,
                    icon: _uploadingWithMobileData
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_cell_rounded, size: 18),
                    label: Text(strings.processingUploadOnMobileData),
                  ),
                ),
              ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: <Widget>[
                    Divider(height: 1, color: palette.border),
                    const SizedBox(height: 6),
                    for (final step in steps)
                      _ProcessingStep(step: step, tint: color),
                    if (status.totalPending > 0) ...<Widget>[
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('pending-audio-review'),
                          onPressed: widget.onReview,
                          icon: const Icon(Icons.headphones_rounded, size: 18),
                          label: Text(strings.processingReviewQueued),
                        ),
                      ),
                    ],
                    if (status.issues.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      for (final issue in status.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: palette.warning,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  issue.count > 1
                                      ? '${issue.count} recordings · ${issue.message}'
                                      : issue.message,
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 11.5,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (status.canRetry)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _retrying ? null : _retry,
                            icon: _retrying
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 17),
                            label: Text(strings.processingRetryFailed),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessingStepData {
  const _ProcessingStepData({
    required this.icon,
    required this.title,
    required this.detail,
    required this.count,
    required this.active,
    this.fraction,
    this.complete = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final int count;
  final bool active;
  final double? fraction;
  final bool complete;
}

class _ProcessingStep extends StatelessWidget {
  const _ProcessingStep({required this.step, required this.tint});
  final _ProcessingStepData step;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = step.complete
        ? palette.success
        : step.active
        ? tint
        : palette.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(width: 25, child: Icon(step.icon, size: 17, color: color)),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  step.title,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  step.detail,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
                if (step.fraction != null) ...<Widget>[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: step.fraction,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                    backgroundColor: palette.border,
                    color: color,
                  ),
                ],
              ],
            ),
          ),
          if (step.count > 0)
            Container(
              constraints: const BoxConstraints(minWidth: 24),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '${step.count}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
