import 'package:flutter/material.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../format.dart';

/// Kleiner Tag in der Farbe aus Paperless.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.tag, this.dense = true});

  final Tag tag;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final bg = Color(parseHexColor(tag.color));
    final fg = Color(parseHexColor(tag.textColor, fallback: 0xFF000000));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: dense ? 1 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tag.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            (dense
                    ? Theme.of(context).textTheme.labelSmall
                    : Theme.of(context).textTheme.labelMedium)
                ?.copyWith(color: fg),
      ),
    );
  }
}
