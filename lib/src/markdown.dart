/// A trailing metadata field: its kind's position in TaskForge order (-1 for
/// fields Facet keeps but never inserts next to), the span including leading
/// whitespace, and the span of its value text.
typedef _Field = ({int rank, int start, int value, int valueEnd, int end});

/// TaskForge's checkbox statuses. `x` and `X` both mean done.
enum TaskStatus {
  todo(' '),
  done('x'),
  cancelled('-'),
  inProgress('/'),
  onHold('!'),
  planned('>'),
  deferred('~'),
  blocked('#'),
  someday('?'),
  ready('*');

  const TaskStatus(this.symbol);
  final String symbol;

  /// Done or cancelled. Closed tasks are hidden unless completed tasks are shown.
  bool get closed => this == done || this == cancelled;

  static TaskStatus parse(String symbol) =>
      symbol == 'X' ? done : values.firstWhere((s) => s.symbol == symbol);
}

/// A one-based source location and the exact text of a supported task.
class MarkdownTask {
  const MarkdownTask._(this.line, this.raw, this.title, this.status, this.due, this.scheduled,
      this.start, this.end, this.priority, this.recurrence, this._checkOffset, this._insertAt,
      this._taskForge, this._due, this._completion, this._fields, this._fieldsEnd);
  final int line;
  final String raw;
  /// The text before the trailing fields, so `📅`, `⏫` or `🔁 every week`
  /// never show up in it.
  final String title;
  final TaskStatus status;
  final String? due;
  /// The `⏳` work date, separate from the due date.
  final String? scheduled;
  /// The `🎯` start and optional end in minutes after midnight. An end clock
  /// time at or before the start falls on the following day.
  final int? start, end;
  /// highest, high, medium, low or lowest.
  final String? priority;
  /// The `🔁` rule, such as `every week`.
  final String? recurrence;
  final int _checkOffset;
  final int _insertAt;
  final bool _taskForge;
  final _Field? _due;
  final _Field? _completion;
  final List<_Field> _fields;
  final int _fieldsEnd;

  bool get done => status == TaskStatus.done;

  String withCompletion(bool value, {DateTime? completedAt}) {
    if (done == value) return raw;
    if (value && recurrence != null) {
      // TaskForge creates the next occurrence on completion. A plain [x] here
      // would end the series, so leave repeating tasks to TaskForge.
      throw const FormatException('This task repeats. Complete it in TaskForge so its next occurrence is created.');
    }
    var next = raw;
    if (_taskForge) {
      final completion = _completion;
      if (value && completion == null) {
        final when = (completedAt ?? DateTime.now()).toLocal();
        final day = when.toIso8601String().split('T').first;
        next = next.replaceRange(_insertAt, _insertAt, ' ✅ $day');
      } else if (!value && completion != null) {
        next = next.replaceRange(completion.start, completion.end, '');
      }
    }
    return next.replaceRange(_checkOffset, _checkOffset + 1, value ? 'x' : ' ');
  }

  String withDue(String? value) {
    if (value != null) validateDate(value);
    final field = _due;
    if (field == null) {
      return value == null ? raw : raw.replaceRange(_insertAt, _insertAt, ' 📅 $value');
    }
    if (value == null) return raw.replaceRange(field.start, field.end, '');
    return raw.replaceRange(field.value, field.valueEnd, value);
  }

  /// Sets the `⏳` date and `🎯` time, replacing values in place. Missing fields
  /// are inserted in TaskForge order and a null date or start removes its field.
  String withSchedule(String? date, {int? start, int? end}) {
    if (date != null) validateDate(date);
    if (start != null && date == null) {
      throw const FormatException('A start time needs a scheduled date.');
    }
    if (start == null && end != null) {
      throw const FormatException('An end time needs a start time.');
    }
    if (start != null && (start < 0 || start >= _day)) {
      throw const FormatException('Choose a start time within the day.');
    }
    if (end != null && (end <= start! || end > start + _day)) {
      throw const FormatException('Choose an end time after the start time.');
    }
    final time = start == null ? null
        : end == null ? _clock(start) : '${_clock(start)}-${_clock(end)}';
    final edits = [?_edit(0, '🎯', time), ?_edit(2, '⏳', date)]
      ..sort((a, b) => a.start == b.start ? b.rank - a.rank : b.start - a.start);
    var next = raw;
    for (final e in edits) {
      next = next.replaceRange(e.start, e.end, e.text);
    }
    return next;
  }

  ({int rank, int start, int end, String text})? _edit(int rank, String emoji, String? value) {
    for (final f in _fields) {
      if (f.rank != rank) continue;
      return value == null ? (rank: rank, start: f.start, end: f.end, text: '')
          : (rank: rank, start: f.value, end: f.valueEnd, text: value);
    }
    if (value == null) return null;
    final at = _fields.where((f) => f.rank > rank).firstOrNull?.start ?? _fieldsEnd;
    return (rank: rank, start: at, end: at, text: ' $emoji $value');
  }
}

void validateDate(String input) {
  if (!RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(input)) {
    throw const FormatException('Use a date in YYYY-MM-DD format.');
  }
  final parsed = DateTime.tryParse('${input}T00:00:00Z');
  if (parsed == null || parsed.year < 1 || parsed.toIso8601String().split('T').first != input) {
    throw const FormatException('The date does not exist.');
  }
}

bool _validDate(String input) {
  try {
    validateDate(input);
    return true;
  } on FormatException {
    return false;
  }
}

const _day = 24 * 60;

/// TaskForge's 12-hour clock without a space, such as `9:00AM`.
String _clock(int minutes) {
  final hour = minutes ~/ 60 % 24;
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '${hour % 12 == 0 ? 12 : hour % 12}:$minute${hour < 12 ? 'AM' : 'PM'}';
}

int _minutes(String clock) {
  final [hour, minute] = clock.substring(0, clock.length - 2).split(':').map(int.parse).toList();
  return hour % 12 * 60 + minute + (clock.endsWith('PM') ? 12 * 60 : 0);
}

// dotAll lets a title contain U+2028 and U+2029, which `.` would otherwise
// refuse. Markdown does not treat either as a line break.
final _item = RegExp(r'^([ \t]*[-*+][ \t]+\[)([ xX\-/!>~#?*])\](?:([ \t]+)(.*))?$', dotAll: true);
const _clockTime = r'(?:[1-9]|1[0-2]):[0-5]\d[AP]M';
final _clockAt = RegExp('($_clockTime)(?:-($_clockTime))?');
final _dateAt = RegExp(r'\d{4}-\d\d-\d\d');
final _idAt = RegExp(r'[A-Za-z0-9_-]+');
final _dependsAt = RegExp(r'[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+)*');
final _limitAt = RegExp(r'\d{4}-\d\d-\d\d|\d+(?:/\d+)?');
// Dataview fields, which TaskForge reads alongside the emoji tokens.
final _bracketAt = RegExp(r'\[([^\[\]():\r\n]+?)::[ \t]*([^\[\]\r\n]*?)[ \t]*\]');
final _parenAt = RegExp(r'\(([^\[\]():\r\n]+?)::[ \t]*([^()\r\n]*?)[ \t]*\)');

/// The documented emoji tokens, with optional variation selector U+FE0F.
const _dateMarkers = {'📅': 'due', '⏳': 'scheduled', '🛫': 'startDate', '✅': 'done', '❌': 'cancelled', '➕': 'created'};
const _priorityMarkers = {'🔺': 'highest', '⏫': 'high', '🔼': 'medium', '🔽': 'low', '⏬': 'lowest'};
const _otherMarkers = ['🎯', '🔁', '🔢', '🆔', '⛔'];
final _markers = [..._dateMarkers.keys, ..._priorityMarkers.keys, ..._otherMarkers];
/// Dataview keys with the meaning of an emoji token.
const _fieldKeys = {
  'due': 'due', 'scheduled': 'scheduled', 'start': 'startDate', 'completion': 'done',
  'cancelled': 'cancelled', 'created': 'created', 'priority': 'priority', 'repeat': 'recurrence',
  'id': 'id', 'dependsOn': 'depends',
};
const _dateKinds = {'due', 'scheduled', 'startDate', 'done', 'cancelled', 'created'};
/// TaskForge writes these fields after the title in this order.
const _ranks = {'time': 0, 'created': 1, 'scheduled': 2, 'due': 3, 'done': 4, 'id': 5};

final _fence = RegExp(r'^[ \t]*(\x60{3,}|~{3,})(.*)$');
final lineBreak = RegExp(r'\r\n|\r|\n');

bool _blank(int c) => c == 0x20 || c == 0x09;
bool _idChar(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x2d;

/// Where trailing spaces and an optional ` ^block-id` begin. This scans back
/// from the end in linear time and matches `(?:[ \t]+\^[A-Za-z0-9-]+)?[ \t]*$`.
int _suffixStart(String raw) {
  var end = raw.length;
  while (end > 0 && _blank(raw.codeUnitAt(end - 1))) {
    end--;
  }
  var id = end;
  while (id > 0 && _idChar(raw.codeUnitAt(id - 1))) {
    id--;
  }
  if (id == end || id == 0 || raw.codeUnitAt(id - 1) != 0x5e) return end;
  final caret = id - 1;
  var start = caret;
  while (start > 0 && _blank(raw.codeUnitAt(start - 1))) {
    start--;
  }
  return start < caret ? start : end;
}

bool _closesFrontMatter(String line) => line.trimRight() == '---' || line.trimRight() == '...';

List<MarkdownTask> parseMarkdown(String source) {
  final lines = source.split(lineBreak);
  final tasks = <MarkdownTask>[];
  String? fence;
  var frontMatter = false;
  for (var i = 0; i < lines.length; i++) {
    final raw = i == 0 && lines[i].startsWith('﻿')
        ? lines[i].substring(1)
        : lines[i];
    // An opening `---` only starts front matter when a closing line follows.
    // Otherwise it is a thematic break and the note's tasks stay visible.
    if (i == 0 && raw.trimRight() == '---' && lines.skip(1).any(_closesFrontMatter)) {
      frontMatter = true;
      continue;
    }
    if (frontMatter) {
      if (_closesFrontMatter(raw)) frontMatter = false;
      continue;
    }
    final marker = _fence.firstMatch(raw);
    if (marker != null) {
      final run = marker[1]!;
      if (fence == null) {
        fence = run;
      } else if (run.startsWith(fence) && marker[2]!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;
    final item = _item.firstMatch(raw);
    if (item == null) continue;
    tasks.add(_parseTask(i + 1, raw, item));
  }
  return tasks;
}

/// One field read at a token's first non-blank character. [kind] names its
/// meaning, such as `due` or `priority`, or `field:<key>` for an unknown
/// Dataview key, which is kept without a meaning.
typedef _Token = ({String kind, int value, int valueEnd, int end, String text});

int _skipBlank(String raw, int from, int limit) {
  var at = from;
  while (at < limit && _blank(raw.codeUnitAt(at))) {
    at++;
  }
  return at;
}

/// Whether a field may begin at [at], used to end a free-text `🔁` rule.
bool _fieldStarts(String raw, int at) =>
    _markers.any((m) => raw.startsWith(m, at)) ||
    _bracketAt.matchAsPrefix(raw, at) != null || _parenAt.matchAsPrefix(raw, at) != null;

_Token? _read(String raw, int at, int limit) {
  bool boundary(int end) => end <= limit && (end == limit || _blank(raw.codeUnitAt(end)));
  // A value follows at least one space or tab.
  int? valueAt(int k) {
    final v = _skipBlank(raw, k, limit);
    return v > k && v < limit ? v : null;
  }
  _Token? prefixed(String kind, int k, RegExp pattern, {bool date = false}) {
    final v = valueAt(k);
    if (v == null) return null;
    final m = pattern.matchAsPrefix(raw, v);
    if (m == null || !boundary(m.end) || (date && !_validDate(m[0]!))) return null;
    return (kind: kind, value: v, valueEnd: m.end, end: m.end, text: m[0]!);
  }

  for (final marker in _markers) {
    if (!raw.startsWith(marker, at)) continue;
    var k = at + marker.length;
    if (k < limit && raw.codeUnitAt(k) == 0xfe0f) k++;
    if (_dateMarkers[marker] case final kind?) return prefixed(kind, k, _dateAt, date: true);
    if (_priorityMarkers[marker] case final level?) {
      return boundary(k) ? (kind: 'priority', value: at, valueEnd: k, end: k, text: level) : null;
    }
    switch (marker) {
      case '🎯':
        return prefixed('time', k, _clockAt);
      case '🆔':
        return prefixed('id', k, _idAt);
      case '⛔':
        return prefixed('depends', k, _dependsAt);
      case '🔢':
        return prefixed('limit', k, _limitAt);
      case '🔁':
        // Natural language, such as `every week on Monday`. It runs until the
        // next field or the end, and must start with "every".
        final v = valueAt(k);
        if (v == null || !raw.substring(v, limit).toLowerCase().startsWith('every')) return null;
        var end = v;
        while (end < limit) {
          if (_blank(raw.codeUnitAt(end))) {
            final next = _skipBlank(raw, end, limit);
            if (next >= limit || _fieldStarts(raw, next)) break;
            end = next;
          } else {
            end++;
          }
        }
        return (kind: 'recurrence', value: v, valueEnd: end, end: end, text: raw.substring(v, end));
    }
  }
  final bracket = _bracketAt.matchAsPrefix(raw, at) ?? _parenAt.matchAsPrefix(raw, at);
  if (bracket == null || !boundary(bracket.end)) return null;
  final key = bracket[1]!.trim();
  final value = bracket[2]!;
  final source = bracket[0]!;
  final v = at + _skipBlank(source, source.indexOf('::') + 2, source.length);
  var kind = _fieldKeys[key] ?? 'field:$key';
  if (_dateKinds.contains(kind) && !_validDate(value)) kind = 'field:$key';
  if (kind == 'priority' && !_priorityMarkers.containsValue(value.toLowerCase())) kind = 'field:$key';
  final text = kind == 'priority' ? value.toLowerCase() : value;
  return (kind: kind, value: v, valueEnd: v + value.length, end: bracket.end, text: text);
}

/// Reads a run of fields that starts with the blank at [start] and ends
/// exactly at [limit], or null. Each meaning may appear once.
List<(int, _Token)>? _fieldsFrom(String raw, int start, int limit) {
  final seen = <String>{};
  final out = <(int, _Token)>[];
  var pos = start;
  while (pos < limit) {
    final at = _skipBlank(raw, pos, limit);
    if (at == pos || at >= limit) return null;
    final token = _read(raw, at, limit);
    if (token == null || !seen.add(token.kind)) return null;
    out.add((pos, token));
    pos = token.end;
  }
  return out.isEmpty ? null : out;
}

MarkdownTask _parseTask(int line, String raw, RegExpMatch item) {
  final suffixStart = _suffixStart(raw);
  final checkOffset = item[1]!.length;
  final bodyStart = checkOffset + 2 + (item[3]?.length ?? 0);
  // The fields are the longest run at the end of the line that reads entirely
  // as fields, in any order. Trying each run of blanks from the left finds it.
  // An emoji mentioned in prose before that run stays part of the title.
  List<(int, _Token)> fields = const [];
  for (var i = checkOffset + 2; i < suffixStart;) {
    if (!_blank(raw.codeUnitAt(i))) {
      i++;
      continue;
    }
    if (_fieldsFrom(raw, i, suffixStart) case final found?) {
      fields = found;
      break;
    }
    i = _skipBlank(raw, i, suffixStart);
  }
  final titleEnd = fields.isEmpty ? suffixStart : fields.first.$1;
  final title = titleEnd < bodyStart ? '' : raw.substring(bodyStart, titleEnd);
  _Token? of(String kind) => fields.where((f) => f.$2.kind == kind).firstOrNull?.$2;
  _Field? span(String kind) {
    for (final (start, t) in fields) {
      if (t.kind == kind) return (rank: _ranks[kind] ?? -1, start: start, value: t.value, valueEnd: t.valueEnd, end: t.end);
    }
    return null;
  }

  var insertAt = suffixStart;
  for (final (start, t) in fields) {
    if (t.kind == 'done' || t.kind == 'id') {
      insertAt = start;
      break;
    }
  }
  final time = of('time');
  final clock = time == null ? null : _clockAt.matchAsPrefix(time.text);
  final start = clock == null ? null : _minutes(clock[1]!);
  final end = clock?[2] == null ? null : _minutes(clock![2]!);
  return MarkdownTask._(
    line, raw, title, TaskStatus.parse(item[2]!), of('due')?.text, of('scheduled')?.text,
    start, end == null || end > start! ? end : end + _day,
    of('priority')?.text, of('recurrence')?.text,
    checkOffset, insertAt, of('created') != null && of('id') != null,
    span('due'), span('done'),
    [for (final (s, t) in fields) (rank: _ranks[t.kind] ?? -1, start: s, value: t.value, valueEnd: t.valueEnd, end: t.end)],
    suffixStart,
  );
}
