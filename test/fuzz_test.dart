// Seeded byte-preservation fuzzing. Override the run with FACET_FUZZ_SEED and
// FACET_FUZZ_CASES; a failure prints the seed and a shrunk input.
import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:test/test.dart';

import 'support/notes.dart';

final _breaks = RegExp(r'\r\n|\r|\n');
late Directory _root;
var _runs = 0, _edits = 0, _roundTrips = 0;

/// Replaces the content of zero-based line [index], keeping its BOM and break.
String replaceLine(String text, int index, String content) {
  final breaks = _breaks.allMatches(text).toList();
  var start = index == 0 ? 0 : breaks[index - 1].end;
  if (index == 0 && text.startsWith('\uFEFF')) start = 1;
  final end = index < breaks.length ? breaks[index].start : text.length;
  return text.replaceRange(start, end, content);
}

DateTime _day(String date) {
  final [year, month, day] = date.split('-').map(int.parse).toList();
  return DateTime(year, month, day);
}

String _decode(List<int> bytes) =>
    (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? '\uFEFF' : '') +
    utf8.decode(bytes, allowMalformed: true);

class _Probe {
  const _Probe(this.name, this.body, [this.target]);
  final String name;
  final String? Function(_Run run) body;
  final Line? target;
}

class _Run {
  _Run(this.note, this.vault, this.path) : original = note.text;
  final Note note;
  final Vault vault;
  final String path;
  final String original;

  int index(Line line) => note.lines.indexOf(line);
  String line(Line target, TaskLine model) => replaceLine(original, index(target), model.text);
  VaultTask at(Line target) =>
      vault.list().singleWhere((t) => t.path == path && t.task.line == index(target) + 1);

  /// Compares [file] with [expected] byte for byte, then the parsed task with [model].
  String? check(String step, String expected,
      {VaultTask? task, TaskLine? model, String? file, bool roundTrip = false}) {
    if (task != null) _edits++;
    final actual = File('${vault.root.path}/${file ?? path}').readAsBytesSync();
    final wanted = utf8.encode(expected);
    if (actual.length != wanted.length || Iterable.generate(wanted.length).any((i) => actual[i] != wanted[i])) {
      return '$step did not produce the documented bytes.\n'
          '  expected ${literal(expected)}\n  actual   ${literal(_decode(actual))}';
    }
    if (task != null && model != null &&
        (task.task.title != model.title || task.task.due != model.due || task.task.done != model.done)) {
      return '$step parsed title ${literal(task.task.title)}, due ${task.task.due}, done ${task.task.done}; '
          'expected ${literal(model.title)}, due ${model.due}, done ${model.done}.';
    }
    if (roundTrip) _roundTrips++;
    return null;
  }
}

String? _execute(_Probe probe, Note note, String path) {
  final dir = Directory('${_root.path}/${_runs++}')..createSync();
  try {
    File('${dir.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(utf8.encode(note.text));
    return probe.body(_Run(note, Vault(dir), path));
  } on Object catch (e, stack) {
    return '${probe.name} threw $e\n$stack';
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Note _shrink(Note note, String path, _Probe probe) {
  var current = note;
  for (var progress = true; progress;) {
    progress = false;
    for (final candidate in current.smaller(probe.target)) {
      if (_execute(probe, candidate, path) != null) {
        current = candidate;
        progress = true;
        break;
      }
    }
  }
  return current;
}

/// Every intended task parses with its title, due date and state, and nothing else does.
_Probe _parse() => _Probe('parse', (run) {
  final parsed = {
    for (final t in run.vault.list().where((t) => t.path == run.path)) t.task.line: t.task,
  };
  final lines = run.note.lines;
  for (var i = 0; i < lines.length; i++) {
    final model = lines[i].task, task = parsed.remove(i + 1);
    if (model == null && task == null) continue;
    if (model == null) return 'Line ${i + 1} parsed as a task: ${literal(task!.raw)}';
    if (task == null) return 'Line ${i + 1} is not parsed as a task: ${literal(model.text)}';
    if (task.title != model.title || task.due != model.due || task.done != model.done) {
      return 'Line ${i + 1} parsed title ${literal(task.title)}, due ${task.due}, done ${task.done}; '
          'expected ${literal(model.title)}, due ${model.due}, done ${model.done}.';
    }
    if (task.status.symbol != (model.check == 'X' ? 'x' : model.check) ||
        task.priority != model.priority || task.recurrence != model.recurrence) {
      return 'Line ${i + 1} parsed status ${task.status.name}, priority ${task.priority}, '
          'recurrence ${task.recurrence}; expected [${model.check}], ${model.priority}, ${model.recurrence}.';
    }
  }
  return parsed.isEmpty ? null : 'Unexpected tasks on lines ${parsed.keys}.';
});

/// Set then clear, or move, move back, clear and set again.
_Probe _due(Line target, String date, String other) => _Probe('reschedule', (run) {
  final t = target.task!;
  if (t.due == null) {
    final dated = t.withDue(date);
    final v = run.vault.reschedule(run.at(target).id, date);
    return run.check('Setting 📅 $date', run.line(target, dated), task: v, model: dated) ??
        run.check('Clearing the new date', run.original,
            task: run.vault.reschedule(v.id, null), model: t, roundTrip: true);
  }
  final moved = t.withDue(other), cleared = t.withDue(null), restored = cleared.withDue(t.due);
  var v = run.vault.reschedule(run.at(target).id, other);
  final failure = run.check('Moving 📅 to $other', run.line(target, moved), task: v, model: moved) ??
      run.check('Moving 📅 back to ${t.due}', run.original,
          task: v = run.vault.reschedule(v.id, t.due), model: t, roundTrip: true) ??
      run.check('Clearing 📅', run.line(target, cleared),
          task: v = run.vault.reschedule(v.id, null), model: cleared) ??
      run.check('Setting 📅 ${t.due} again', run.line(target, restored),
          task: run.vault.reschedule(v.id, t.due), model: restored);
  // A single-spaced date in the documented position, directly before ✅, 🆔
  // or the end, returns to the same bytes.
  if (failure != null || restored.text != t.text) return failure;
  return run.check('Clearing and setting 📅 ${t.due}', run.original, roundTrip: true);
}, target);

/// Toggle completion and back.
_Probe _completion(Line target, String day) => _Probe('setCompleted', (run) {
  final t = target.task!;
  if (t.recurrence != null) return _repeating(run, target, day);
  final completion = t.field('✅');
  final again = completion?.value ?? day;
  final first = t.withCompletion(!t.done, day), second = first.withCompletion(t.done, again);
  final v = run.vault.setCompleted(run.at(target).id, !t.done, completedAt: _day(day));
  final failure = run.check(t.done ? 'Reopening' : 'Completing on $day', run.line(target, first),
          task: v, model: first) ??
      run.check(t.done ? 'Completing again on $again' : 'Reopening', run.line(target, second),
          task: run.vault.setCompleted(v.id, t.done, completedAt: _day(again)), model: second);
  // Reopening writes an open box and completing a lowercase x. TaskForge tasks
  // regain ✅ single-spaced before 🆔. Only lines already in that form
  // round-trip, which the model reports.
  if (failure != null || second.text != t.text) return failure;
  return run.check('Toggling completion twice', run.original, roundTrip: true);
}, target);

/// A repeating task can be reopened but not completed, so TaskForge can create
/// its next occurrence. A refused completion leaves the note unchanged.
String? _repeating(_Run run, Line target, String day) {
  final t = target.task!;
  String? refuses(String id, String expected) {
    try {
      run.vault.setCompleted(id, true, completedAt: _day(day));
      return 'Completing a repeating task succeeded.';
    } on FormatException {
      return run.check('Refusing to complete a repeating task', expected);
    }
  }
  if (!t.done) return refuses(run.at(target).id, run.original);
  final reopened = t.withCompletion(false, day);
  final v = run.vault.setCompleted(run.at(target).id, false);
  return run.check('Reopening a repeating task', run.line(target, reopened), task: v, model: reopened) ??
      refuses(v.id, run.line(target, reopened));
}

/// Append to Inbox.md with its first line ending, or refuse inside an open fence.
_Probe _capture(String title, String? due) => _Probe('capture', (run) {
  final base = run.path == 'Inbox.md' ? run.original : '';
  if (run.path == 'Inbox.md' && run.note.unclosed) {
    try {
      run.vault.capture(title, due: due);
      return 'Capture inside an open code fence succeeded.';
    } on FormatException {
      return run.check('Refusing to capture inside an open fence', run.original);
    }
  }
  final ending = _breaks.firstMatch(base)?[0] ?? '\n';
  final needsBreak = base.isNotEmpty && base != '﻿' && !base.endsWith('\n') && !base.endsWith('\r');
  final expected =
      '$base${needsBreak ? ending : ''}- [ ] ${title.trim()}${due == null ? '' : ' 📅 $due'}$ending';
  final v = run.vault.capture(title, due: due);
  final failure = run.check('Capturing ${literal(title)}', expected, file: 'Inbox.md');
  if (failure != null) return failure;
  _edits++;
  if (v.task.title != title.trim() || v.task.due != due || v.task.done ||
      v.task.line != _breaks.allMatches(expected).length) {
    return 'Captured line ${v.task.line} parsed title ${literal(v.task.title)}, due ${v.task.due}.';
  }
  return null;
});

void main() {
  final seed = int.tryParse(Platform.environment['FACET_FUZZ_SEED'] ?? '') ?? 20261119;
  final cases = int.tryParse(Platform.environment['FACET_FUZZ_CASES'] ?? '') ?? 300;
  setUpAll(() => _root = Directory.systemTemp.createTempSync('facet-fuzz-'));
  tearDownAll(() => _root.deleteSync(recursive: true));

  test('seeded notes keep every byte outside the edited task', () {
    var tasks = 0;
    for (var i = 0; i < cases; i++) {
      final caseSeed = seed + i;
      final generator = NoteGenerator(caseSeed);
      final note = generator.note();
      final path = generator.chance(0.6) ? 'Inbox.md' : 'Projects/Ünïcode 🚀/Plan.md';
      final targets = note.lines.where((l) => l.task != null).toList()..shuffle(generator.random);
      tasks += targets.length;
      final probes = [
        _parse(),
        for (final target in targets.take(3)) ...[
          _due(target, generator.date(), () {
            var other = generator.date();
            while (other == target.task!.due) {
              other = generator.date();
            }
            return other;
          }()),
          _completion(target, generator.date()),
        ],
        _capture('${generator.pick(['', ' ', '\t'])}${generator.title()}${generator.pick(['', ' ', '  '])}',
            generator.chance(0.5) ? generator.date() : null),
      ];
      for (final probe in probes) {
        if (_execute(probe, note, path) == null) continue;
        final minimal = _shrink(note, path, probe);
        final line = probe.target == null ? '' : ' on line ${minimal.lines.indexOf(probe.target!) + 1}';
        fail('Fuzz case $caseSeed failed. Rerun with FACET_FUZZ_SEED=$caseSeed FACET_FUZZ_CASES=1.\n'
            '${probe.name}$line of $path: ${_execute(probe, minimal, path)}\n'
            'Minimal input: ${literal(minimal.text)}');
      }
    }
    print('Fuzzed $cases notes from seed $seed: $tasks tasks, $_edits verified edits, '
        '$_roundTrips byte-identical round trips.');
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('parser regressions found while fuzzing', () {
    for (final separator in lineSeparators) {
      final code = 'U+${separator.codeUnitAt(0).toRadixString(16).toUpperCase()}';
      test('a $code inside a title keeps the task', () {
        final task = parseMarkdown('- [ ] Plan${separator}launch 📅 2027-01-01\n').single;
        expect(task.title, 'Plan${separator}launch');
        expect(task.due, '2027-01-01');
      });
    }
  });
}
