import 'dart:async';

import 'package:flutter/material.dart';

import 'main_controller.dart';
import 'main_shared.dart';
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
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return ListView(
      padding: const EdgeInsets.all(28),
      children: <Widget>[
        const ScreenHeader(
          eyebrow: 'SEARCH',
          title: 'Recall naturally',
          description:
              'Every query runs free local keyword and semantic retrieval. Ask is an explicit, separately rate-limited OpenRouter action.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: query,
          onChanged: changed,
          onSubmitted: widget.controller.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: 'Search memories and transcripts',
            suffixIcon: IconButton(
              tooltip: 'Ask over retrieved context',
              onPressed: query.text.trim().isEmpty
                  ? null
                  : () => widget.controller.ask(query.text),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
          ),
        ),
        if (widget.controller.askAnswer != null) ...<Widget>[
          const SizedBox(height: 18),
          GlassSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('ANSWER', style: sectionEyebrowStyle(palette)),
                const SizedBox(height: 10),
                Text(
                  widget.controller.askAnswer!,
                  style: const TextStyle(height: 1.5),
                ),
                if (widget.controller.askCitations.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.controller.askCitations
                        .map(
                          (citation) => Chip(
                            avatar: const Icon(Icons.link_outlined, size: 16),
                            label: Text(
                              '${citation['kind']} · ${citation['timestamp'] == null ? 'source' : DateTime.parse(citation['timestamp'] as String).toLocal().toString().split('.').first}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (widget.controller.searchResults.isEmpty)
          const GlassSurface(
            child: EmptyState(
              icon: Icons.manage_search,
              title: 'Search your recall',
              message:
                  'Try a name, topic, event, or a natural-language description.',
            ),
          )
        else
          for (final result in widget.controller.searchResults)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassSurface(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Chip(label: Text(result['kind'] as String)),
                        const Spacer(),
                        Text(
                          ((result['score'] as num?) ?? 0)
                              .toDouble()
                              .toStringAsFixed(3),
                          style: TextStyle(color: palette.textMuted),
                        ),
                      ],
                    ),
                    if (result['title'] != null)
                      Text(
                        result['title'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      result['body'] as String,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.textSoft, height: 1.45),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
