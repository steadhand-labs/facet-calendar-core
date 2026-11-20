/// Dates written in words at the start of a task title, such as
/// `**Thu Nov 5** · Study`. Obsidian Tasks and TaskForge 3.1.1 don't read a
/// date without its emoji, so Facet can offer to add the `📅`.
library;

const _months = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
  'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
  'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9,
  'oct': 10, 'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

const _weekdays = {
  'mon': DateTime.monday, 'monday': DateTime.monday,
  'tue': DateTime.tuesday, 'tues': DateTime.tuesday, 'tuesday': DateTime.tuesday,
  'wed': DateTime.wednesday, 'wednesday': DateTime.wednesday,
  'thu': DateTime.thursday, 'thur': DateTime.thursday, 'thurs': DateTime.thursday,
  'thursday': DateTime.thursday,
  'fri': DateTime.friday, 'friday': DateTime.friday,
  'sat': DateTime.saturday, 'saturday': DateTime.saturday,
  'sun': DateTime.sunday, 'sunday': DateTime.sunday,
};

// Longest names first, so "thursday" wins over "thu".
String _names(Map<String, int> names) => (names.keys.toList()..sort((a, b) => b.length - a.length)).join('|');

/// An optional `**` or `__`, then [weekday] [month] [day][ordinal], with an
/// optional four-digit year, ending before any letter or digit.
final _opening = RegExp(
    '^(?:\\*\\*|__)?\\s*(?:(${_names(_weekdays)})\\.?,?\\s+)?(${_names(_months)})\\.?\\s+'
    r'(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?![\p{L}\p{N}])',
    caseSensitive: false, unicode: true);

/// The `YYYY-MM-DD` date that [title] opens with, or null when it has none or
/// the date is uncertain.
///
/// A weekday or a year is required. Without a year, the weekday picks the one
/// year within 366 days of [today] on which the date falls on it. With both,
/// they must agree.
String? writtenDate(String title, DateTime today) {
  final match = _opening.firstMatch(title);
  if (match == null) return null;
  final weekday = match[1] == null ? null : _weekdays[match[1]!.toLowerCase()];
  final month = _months[match[2]!.toLowerCase()]!;
  final day = int.parse(match[3]!);
  final year = match[4] == null ? null : int.parse(match[4]!);
  if (weekday == null && year == null) return null;
  final base = DateTime.utc(today.year, today.month, today.day);
  final found = [
    for (final y in year == null ? [today.year - 1, today.year, today.year + 1] : [year])
      if (DateTime.utc(y, month, day) case final date
          // DateTime rolls "Nov 31" over to December 1, so check it didn't.
          when date.month == month && date.day == day &&
              (weekday == null || date.weekday == weekday) &&
              (year != null || date.difference(base).inDays.abs() <= 366))
        date,
  ];
  return found.length == 1 ? found.single.toIso8601String().split('T').first : null;
}
