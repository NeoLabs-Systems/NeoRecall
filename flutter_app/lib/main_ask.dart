import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';
import 'src/models/ask.dart';

/// Ask: one conversation with your own recall.
///
/// This replaced a results list. A query over a life is almost never a lookup —
/// it is a question with a time in it, a name, a half-remembered promise — so
/// the answer leads and the evidence it was written from sits under it, ranked,
/// rather than the other way round.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final TextEditingController question = TextEditingController();
  final ScrollController scroll = ScrollController();
  int _lastTurnCount = 0;

  @override
  void dispose() {
    question.dispose();
    scroll.dispose();
    super.dispose();
  }

  void submit([String? text]) {
    final value = (text ?? question.text).trim();
    if (value.isEmpty || widget.controller.askBusy) return;
    question.clear();
    setState(() {});
    widget.controller.ask(value);
  }

  /// Keeps the newest turn in view without fighting a reader who has scrolled
  /// up: only a turn that was not there a build ago pulls the list down.
  void _followConversation(int turnCount) {
    if (turnCount == _lastTurnCount) return;
    _lastTurnCount = turnCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = compact ? AppSpacing.lg - 4 : AppSpacing.lg;
    final turns = controller.askTurns;
    _followConversation(turns.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: turns.isEmpty
              ? _AskIntro(gutter: gutter, onPick: submit)
              : ListView.builder(
                  controller: scroll,
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    compact ? 20 : 28,
                    gutter,
                    AppSpacing.lg,
                  ),
                  itemCount: turns.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _TurnView(turn: turns[index], first: index == 0),
                ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (turns.isNotEmpty && !controller.askBusy) ...<Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: controller.clearAsk,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('New question'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              _Composer(
                controller: question,
                busy: controller.askBusy,
                hint: turns.isEmpty
                    ? 'Ask anything about your day'
                    : 'Ask a follow-up',
                onSubmit: submit,
                palette: palette,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AskIntro extends StatelessWidget {
  const _AskIntro({required this.gutter, required this.onPick});

  final double gutter;
  final void Function(String) onPick;

  static const List<String> _starters = <String>[
    'What did I do today?',
    'What did I say I would follow up on this week?',
    'Who did I talk to yesterday, and about what?',
  ];

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 0),
      children: <Widget>[
        const ScreenHeader(
          eyebrow: 'Recall',
          title: 'Ask',
          description:
              'Your recall, in your own words. Retrieval and the answer both '
              'run wherever your NeoRecall server does — no query leaves it.',
        ),
        const SectionLabel(label: 'Start with'),
        for (final starter in _starters)
          HairlineRow(
            title: starter,
            leading: Icon(
              Icons.auto_awesome_rounded,
              size: 18,
              color: palette.accent,
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: palette.textMuted,
            ),
            onTap: () => onPick(starter),
          ),
      ],
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({required this.turn, required this.first});

  final AskTurn turn;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.bgTertiary,
                  border: Border.all(color: palette.border),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(AppRadius.card),
                    topRight: Radius.circular(AppRadius.card),
                    bottomLeft: Radius.circular(AppRadius.card),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 12,
                ),
                child: Text(
                  turn.question,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (turn.isPending)
            const AskThinkingIndicator()
          else if (turn.error != null)
            InlineMessage(message: turn.error!, error: true)
          else
            _Answer(turn: turn),
        ],
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({required this.turn});

  final AskTurn turn;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 12),
              child: _AnswerMark(color: palette.accent),
            ),
            Expanded(
              child: Text(
                turn.answer ?? '',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
        if (turn.sources.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          SectionLabel(label: 'Sources', trailing: '${turn.sources.length}'),
          for (var index = 0; index < turn.sources.length; index++)
            _SourceRow(
              source: turn.sources[index],
              showDivider: index > 0,
            ),
        ],
        if (turn.weakCount > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.filter_alt_off_rounded,
                size: 14,
                color: palette.textMuted,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '${turn.weakCount} weaker matches were left out — they share '
                  'words with the question, not meaning.',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The gold dot an answer is written under — the resting state of the same
/// light that pulses while the answer is being written.
class _AnswerMark extends StatelessWidget {
  const _AnswerMark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.showDivider});

  final AskSource source;
  final bool showDivider;

  String _when(BuildContext context) {
    final at = source.occurredAt;
    if (at == null) return source.kindLabel.toUpperCase();
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final today = DateUtils.isSameDay(at, DateTime.now());
    final date = today
        ? 'today'
        : MaterialLocalizations.of(context).formatShortDate(at);
    return '${source.kindLabel} · $date $time'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    // A weak match is still shown, but never dressed as a strong one: the
    // meter and the muted fill are the difference the reader needs.
    final strong = source.relevance >= 0.7;
    final fill = strong ? palette.accent : palette.textSecondary;
    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            )
          : null,
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _when(context),
                  style: sectionEyebrowStyle(palette),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                source.relevance.toStringAsFixed(2),
                style: monoMetricStyle(palette, size: 10.5, color: fill),
              ),
              const SizedBox(width: 8),
              _RelevanceMeter(value: source.relevance, color: fill),
            ],
          ),
          if (source.title != null && source.title!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              source.title!,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
          if (source.excerpt.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              source.excerpt,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RelevanceMeter extends StatelessWidget {
  const _RelevanceMeter({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return SizedBox(
      width: 42,
      height: 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Stack(
          children: <Widget>[
            Container(color: palette.borderLight),
            FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.hint,
    required this.onSubmit,
    required this.palette,
  });

  final TextEditingController controller;
  final bool busy;
  final String hint;
  final VoidCallback onSubmit;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy ? 0.55 : 1,
      child: TextField(
        controller: controller,
        enabled: !busy,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          hintText: hint,
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: IconButton(
              onPressed: busy ? null : onSubmit,
              style: IconButton.styleFrom(
                backgroundColor: busy ? palette.bgTertiary : palette.accent,
                foregroundColor: busy ? palette.textMuted : palette.onAccent,
                minimumSize: const Size(44, 44),
              ),
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              tooltip: 'Ask',
            ),
          ),
        ),
      ),
    );
  }
}

/// The wait, made legible.
///
/// One gold light that breathes, two rings leaving it, and a sweep crossing a
/// hairline. The glow belongs to the dot and never to a panel behind it — the
/// rest of this design system is flat, and a thinking state is not a licence to
/// break it. Every motion stops when the platform asks for reduced motion.
class AskThinkingIndicator extends StatefulWidget {
  const AskThinkingIndicator({super.key});

  @override
  State<AskThinkingIndicator> createState() => _AskThinkingIndicatorState();
}

class _AskThinkingIndicatorState extends State<AskThinkingIndicator>
    with TickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat(reverse: true);
  late final AnimationController rings = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();
  late final AnimationController sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..repeat();

  @override
  void dispose() {
    pulse.dispose();
    rings.dispose();
    sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      pulse.stop();
      rings.stop();
      sweep.stop();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 26,
              height: 26,
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[pulse, rings]),
                  builder: (BuildContext context, _) => CustomPaint(
                    size: const Size.square(26),
                    painter: _ThinkingOrbPainter(
                      color: palette.accent,
                      pulse: still ? 0.5 : pulse.value,
                      ring: still ? null : rings.value,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            _ShimmerLabel(
              label: 'Searching your recall',
              animation: sweep,
              animate: !still,
              palette: palette,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 2,
          child: AnimatedBuilder(
            animation: sweep,
            builder: (BuildContext context, _) => CustomPaint(
              painter: _SweepPainter(
                track: palette.border,
                color: palette.accent,
                progress: still ? null : Curves.easeInOut.transform(sweep.value),
              ),
              size: Size.infinite,
            ),
          ),
        ),
      ],
    );
  }
}

class _ShimmerLabel extends StatelessWidget {
  const _ShimmerLabel({
    required this.label,
    required this.animation,
    required this.animate,
    required this.palette,
  });

  final String label;
  final Animation<double> animation;
  final bool animate;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label.toUpperCase(),
      style: sectionEyebrowStyle(palette).copyWith(
        color: animate ? Colors.white : palette.textMuted,
      ),
    );
    if (!animate) return text;
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (Rect bounds) {
          final travel = bounds.width * 1.6;
          final origin = -bounds.width * 0.3 + travel * animation.value;
          return LinearGradient(
            colors: <Color>[
              palette.textMuted,
              palette.accentHover,
              palette.textMuted,
            ],
            stops: const <double>[0.0, 0.5, 1.0],
          ).createShader(
            Rect.fromLTWH(origin - bounds.width * 0.5, 0, bounds.width, bounds.height),
          );
        },
        child: child,
      ),
      child: text,
    );
  }
}

class _ThinkingOrbPainter extends CustomPainter {
  const _ThinkingOrbPainter({
    required this.color,
    required this.pulse,
    required this.ring,
  });

  final Color color;

  /// 0..1, the breath.
  final double pulse;

  /// 0..1 through one ring's life, or null when motion is switched off.
  final double? ring;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final phase = ring;
    if (phase != null) {
      // Two rings, half a cycle apart, so one is always leaving as the other
      // arrives.
      for (final offset in <double>[0, 0.5]) {
        final progress = (phase + offset) % 1;
        final radius = size.width * (0.17 + 0.33 * progress);
        final fade = (1 - progress / 0.7).clamp(0.0, 1.0);
        if (fade <= 0) continue;
        canvas.drawCircle(
          centre,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.4 * fade),
        );
      }
    }
    final scale = 1 + 0.28 * pulse;
    canvas.drawCircle(
      centre,
      4.5 * scale * 1.9,
      Paint()
        ..color = color.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(centre, 4.5 * scale, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ThinkingOrbPainter old) =>
      old.pulse != pulse || old.ring != ring || old.color != color;
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter({
    required this.track,
    required this.color,
    required this.progress,
  });

  final Color track;
  final Color color;

  /// 0..1 across the hairline, or null when motion is switched off.
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = track,
    );
    final value = progress;
    if (value == null) return;
    final width = size.width * 0.34;
    final left = -width + (size.width + width * 2) * value;
    final band = Rect.fromLTWH(left, 0, width, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(band, radius),
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            color.withValues(alpha: 0),
            color,
            color.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}
