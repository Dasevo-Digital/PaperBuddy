import 'package:intl/intl.dart';

final _day = DateFormat('d. MMM yyyy', 'de');
final _dayTime = DateFormat('d. MMM yyyy, HH:mm', 'de');

String formatDay(DateTime d) => _day.format(d);
String formatDayTime(DateTime d) => _dayTime.format(d.toLocal());

/// `#a6cee3` → Farbwert für `Color`.
int parseHexColor(String hex, {int fallback = 0xFFA6CEE3}) {
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return fallback;
  return int.tryParse('FF$h', radix: 16) ?? fallback;
}
