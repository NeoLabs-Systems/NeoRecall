import 'package:flutter/material.dart';

import '../../main_spacing.dart';
import '../../main_theme.dart';
import 'memory_formatting.dart';

/// The transcript a memory or a highlight was built from.
///
/// A memory can cite dozens of transcript segments, and a segment is often a
/// single sentence. Giving each one its own bordered card turned the bottom of
/// the detail sheet into a long column of nearly empty boxes that had to be
/// scrolled past to reach the end. Two things fix that without hiding anything:
/// consecutive segments spoken without a real break are one passage with one
/// timestamp, and only the first few passages are shown until the reader asks
/// for the rest.
class TranscriptExcerpts extends StatefulWidget {
  const TranscriptExcerpts({
    super.key,
    required this.sources,
    this.emptyLabel = 'No transcript excerpts are linked to this memory.',
    this.showTimes = true,
    this.initialCount = 3,
  });

  /// Rows as the detail endpoint returns them: `started_at` and `text`.
  final List<Map<String, dynamic>> sources;
  final String emptyLabel;

  /// A highlight cites a single moment, so its evidence reads better without a
  /// clock down the side.
  final bool showTimes;
  final int initialCount;

  @override
  State<TranscriptExcerpts> createState() => _TranscriptExcerptsState();
}

/// Speech continues across a segment boundary far more often than it stops. A
/// minute of silence is the point where a new timestamp tells the reader
/// something they did not already know.
const Duration _passageGap = Duration(minutes: 1);

class _Passage {
  const _Passage(this.startedAt, this.text);

  final DateTime? startedAt;
  final String text;
}

List<_Passage> _passages(List<Map<String, dynamic>> sources) {
  final passages = <_Passage>[];
  DateTime? previousEnd;
  final buffer = StringBuffer();
  DateTime? bufferStart;

  void flush() {
    final text = buffer.toString().trim();
    if (text.isNotEmpty) passages.add(_Passage(bufferStart, text));
    buffer.clear();
    bufferStart = null;
  }

  for (final source in sources) {
    final text = (source['text'] as String? ?? '').trim();
    if (text.isEmpty) continue;
    final started = DateTime.tryParse(source['started_at'] as String? ?? '');
    final ended =
        DateTime.tryParse(source['ended_at'] as String? ?? '') ?? started;
    final previous = previousEnd;
    final breaks =
        previous == null ||
        started == null ||
        started.difference(previous) >= _passageGap;
    if (breaks) {
      flush();
      bufferStart = started;
    } else {
      buffer.write(' ');
    }
    buffer.write(text);
    previousEnd = ended ?? previousEnd;
  }
  flush();
  return passages;
}

class _TranscriptExcerptsState extends State<TranscriptExcerpts> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    if (widget.sources.isEmpty) {
      return Text(
        widget.emptyLabel,
        style: TextStyle(color: palette.textMuted, height: 1.4),
      );
    }

    final passages = _passages(widget.sources);
    final visible = _expanded
        ? passages
        : passages.take(widget.initialCount).toList();
    final hidden = passages.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // One frame around the whole transcript rather than one per line: the
        // passages belong together, and hairline rules separate them well
        // enough without repeating a border and a radius for every sentence.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: palette.bgSecondary.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var index = 0; index < visible.length; index += 1)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    decoration: index == 0
                        ? null
                        : BoxDecoration(
                            border: Border(
                              top: BorderSide(color: palette.borderLight),
                            ),
                          ),
                    child: _passageRow(palette, visible[index]),
                  ),
              ],
            ),
          ),
        ),
        if (hidden > 0 || _expanded)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('transcript-excerpts-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              icon: Icon(
                _expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 17,
              ),
              label: Text(
                _expanded
                    ? 'Show less'
                    : '$hidden more ${hidden == 1 ? 'passage' : 'passages'}',
              ),
            ),
          ),
      ],
    );
  }

  Widget _passageRow(NeoRecallPalette palette, _Passage passage) {
    final text = Text(
      passage.text,
      style: TextStyle(color: palette.textSoft, height: 1.45, fontSize: 13),
    );
    if (!widget.showTimes || passage.startedAt == null) return text;
    // A fixed column keeps every passage starting on the same line, which is
    // what makes the list scannable rather than ragged.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 58,
          child: Text(
            formatTime(passage.startedAt!),
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.65,
            ),
          ),
        ),
        Expanded(child: text),
      ],
    );
  }
}
