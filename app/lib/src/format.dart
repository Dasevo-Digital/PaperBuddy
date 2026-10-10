import 'package:intl/intl.dart';

/// Datum in der Sprache der App (`Intl.defaultLocale`, siehe `useLanguage`).
String formatDay(DateTime d) => DateFormat.yMMMd().format(d);
String formatDayTime(DateTime d) => DateFormat.yMMMd().add_Hm().format(d.toLocal());

/// `#a6cee3` → Farbwert für `Color`.
int parseHexColor(String hex, {int fallback = 0xFFA6CEE3}) {
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return fallback;
  return int.tryParse('FF$h', radix: 16) ?? fallback;
}
