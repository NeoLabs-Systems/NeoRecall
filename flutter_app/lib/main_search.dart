import 'dart:async';

import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
import 'main_spacing.dart';
import 'main_theme.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.controller});
  final NeoRecallController controller;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController query = TextEditingController();
  Timer? debounce;

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void changed(String value) {
    debounce?.cancel();
    debounce = Timer(
      const Duration(milliseconds: 280),
      () => widget.controller.search(value),
    );
    // Rebuild so the Ask affordance enables the moment there is something to
    // ask about, rather than one debounce later.
    setState(() {});
  }

  /// A citation's own words, not its plumbing. `kind` plus a local timestamp is
  /// what the reader can actually match against their day.
  String _citationLabel(Map<String, dynamic> citation) {
    final kind = (citation['kind'] as String?)?.trim();
    final raw = citation['timestamp'];
    if (raw is! String) return kind?.isNotEmpty == true ? kind! : 'source';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return kind ?? 'source';
    final local = parsed.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final today = DateUtils.isSameDay(local, DateTime.now());
    return today
        ? '${kind ?? 'source'} · today $time'
        : '${kind ?? 'source'} · '
              '${MaterialLocalizations.of(context).formatShortDate(local)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final controller = widget.controller;
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = compact ? AppSpacing.lg - 4 : AppSpacing.lg;
    final hasQuery = query.text.trim().isNotEmpty;
    final results = controller.searchResults;

    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, compact ? 20 : 28, gutter, 40),
      children: <Widget>[
        const ScreenHeader(title: 'Search'),
        TextField(
          controller: query,
          onChanged: changed,
          onSubmitted: controller.search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            hintText: 'Search memories and transcripts',
            // "Ask" writes an answer over the results, which takes longer than
            // retrieval — so it is a deliberate second act, not what Enter does.
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                onPressed: hasQuery ? () => controller.ask(query.text) : null,
                child: const Text('Ask'),
              ),
            ),
          ),
        ),

        if (controller.askAnswer != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const SectionLabel(label: 'Answer'),
          const SizedBox(height: 4),
          Text(
            controller.askAnswer!,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          if (controller.askCitations.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                for (final citation in controller.askCitations)
                  MetaPill(
                    icon: Icons.link_rounded,
                    label: _citationLabel(citation),
                  ),
              ],
            ),
          ],
        ],

        const SizedBox(height: AppSpacing.lg),
        if (results.isEmpty)
          EmptyState(
            icon: Icons.search_rounded,
            title: hasQuery ? 'Nothing matched' : 'Search your recall',
            message: hasQuery
                ? 'Try a different wording, a name, or a shorter phrase.'
                : 'A name, a topic, an event, or a plain description of what '
                      'was said. Every query runs local keyword and semantic '
                      'retrieval.',
          )
        else ...<Widget>[
          SectionLabel(
            label: 'Results',
            trailing: '${results.length}',
          ),
          for (var index = 0; index < results.length; index++)
            _ResultRow(result: results[index], showDivider: index > 0),
        ],
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result, required this.showDivider});

  final Map<String, dynamic> result;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final title = result['title'] as String?;
    final body = (result['body'] as String?) ?? '';
    final kind = (result['kind'] as String?) ?? 'result';

    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            )
          : null,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(kind.toUpperCase(), style: sectionEyebrowStyle(palette)),
          if (title != null && title.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              title,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
              ),
            ),
          ],
          const SizedBox(height: 5),
          Text(
            body,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
