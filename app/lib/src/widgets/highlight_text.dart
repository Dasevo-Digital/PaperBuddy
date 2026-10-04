import 'package:flutter/material.dart';

/// Zeigt einen Suchausschnitt des Servers an, Treffer stehen dort in
/// `<span class="match">…</span>`. Alles andere HTML wird entfernt.
class HighlightText extends StatelessWidget {
  const HighlightText(this.html, {super.key, this.maxLines = 2, this.style});

  final String html;
  final int maxLines;
  final TextStyle? style;

  static final _match = RegExp(
    r'<span class="match">(.*?)</span>',
    dotAll: true,
  );
  static final _tags = RegExp(r'<[^>]+>');

  static String _clean(String s) => s
      .replaceAll(_tags, '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\s+'), ' ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = style ?? theme.textTheme.bodySmall;
    final strong = base?.copyWith(
      fontWeight: FontWeight.w700,
      backgroundColor: theme.colorScheme.tertiaryContainer,
      color: theme.colorScheme.onTertiaryContainer,
    );
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _match.allMatches(html)) {
      spans.add(TextSpan(text: _clean(html.substring(last, m.start))));
      spans.add(TextSpan(text: _clean(m.group(1)!), style: strong));
      last = m.end;
    }
    spans.add(TextSpan(text: _clean(html.substring(last))));
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
