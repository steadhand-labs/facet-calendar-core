import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Vault vault;
  late File inbox;
  setUp(() {
    root = Directory.systemTemp.createTempSync('facet-test-');
    vault = Vault(root);
    inbox = File('${root.path}/Inbox.md');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('capture, date, move, complete and reread an external edit', () {
    final newTask = vault.capture('Draft map');
    expect(inbox.readAsStringSync(), '- [ ] Draft map\n');
    final dated = vault.reschedule(newTask.id, '2028-02-29');
    expect(inbox.readAsStringSync(), '- [ ] Draft map 📅 2028-02-29\n');
    final moved = vault.reschedule(dated.id, '2028-03-01');
    expect(inbox.readAsStringSync(), '- [ ] Draft map 📅 2028-03-01\n');
    final done = vault.setCompleted(moved.id, true);
    expect(inbox.readAsStringSync(), '- [x] Draft map 📅 2028-03-01\n');
    inbox.writeAsStringSync('- [X] Revised map 📅 2028-03-02\n');
    expect(() => vault.reschedule(done.id, null), throwsA(isA<VaultConflict>()));
    final external = vault.list().single;
    expect(external.task.title, 'Revised map');
    expect(external.task.done, true);
    expect(external.task.due, '2028-03-02');
    vault.reschedule(external.id, null);
    expect(inbox.readAsStringSync(), '- [X] Revised map\n');
  });

  test('TaskForge lifecycle keeps its metadata and accepts an external edit', () {
    const captured = '- [ ] Review paper proofs ➕ 2026-11-19 🆔 mwnqserw\n';
    const datedToday = '- [ ] Review paper proofs ➕ 2026-11-19 📅 2026-11-19 🆔 mwnqserw\n';
    const datedTomorrow = '- [ ] Review paper proofs ➕ 2026-11-19 📅 2026-11-20 🆔 mwnqserw\n';
    const completed = '- [x] Review paper proofs ➕ 2026-11-19 📅 2026-11-20 ✅ 2026-11-19 🆔 mwnqserw\n';
    const revised = '- [x] Review revised proofs ➕ 2026-11-19 📅 2026-11-21 ✅ 2026-11-19 🆔 mwnqserw\n';
    const reopened = '- [ ] Review revised proofs ➕ 2026-11-19 📅 2026-11-21 🆔 mwnqserw\n';
    final note = File('${root.path}/TaskForge.md')..writeAsStringSync(captured);
    final task = vault.list().single;
    expect(task.path, 'TaskForge.md');
    expect(task.task.title, 'Review paper proofs');
    expect(task.task.due, isNull);
    final dated = vault.reschedule(task.id, '2026-11-19');
    expect(dated.task.title, task.task.title);
    expect(dated.task.due, '2026-11-19');
    expect(note.readAsBytesSync(), utf8.encode(datedToday));
    final moved = vault.reschedule(dated.id, '2026-11-20');
    expect(note.readAsBytesSync(), utf8.encode(datedTomorrow));
    final done = vault.setCompleted(moved.id, true, completedAt: DateTime(2026, 11, 19));
    expect(note.readAsBytesSync(), utf8.encode(completed));
    expect(done.task.done, true);
    expect(done.task.title, 'Review paper proofs');
    expect(done.task.due, '2026-11-20');
    note.writeAsStringSync(revised);
    expect(() => vault.setCompleted(done.id, false), throwsA(isA<VaultConflict>()));
    final external = vault.list().single;
    expect(external.task.title, 'Review revised proofs');
    expect(external.task.due, '2026-11-21');
    final open = vault.setCompleted(external.id, false);
    expect(note.readAsBytesSync(), utf8.encode(reopened));
    vault.reschedule(open.id, null);
    expect(note.readAsStringSync(), reopened.replaceFirst(' 📅 2026-11-21', ''));
  });

  for (final time in ['9:00AM', '9:00AM-9:30AM']) {
    test('TaskForge schedule $time survives independent due and status edits', () {
      final timed = '- [ ] Review revised proofs 🎯 $time ➕ 2026-11-19 ⏳ 2026-11-20 📅 2026-11-21 🆔 mwnqserw\n';
      final note = File('${root.path}/TaskForge.md')..writeAsStringSync(timed);
      final read = vault.list().single;
      expect(read.task.title, 'Review revised proofs');
      expect(read.task.due, '2026-11-21');
      expect(read.task.scheduled, '2026-11-20');
      expect((read.task.start, read.task.end), (540, time.contains('-') ? 570 : null));

      final undated = vault.reschedule(read.id, null);
      final withoutDue = timed.replaceFirst(' 📅 2026-11-21', '');
      expect(note.readAsStringSync(), withoutDue);
      expect(undated.task.due, isNull);
      expect(undated.task.title, read.task.title);
      expect(undated.task.scheduled, '2026-11-20');

      final restored = vault.reschedule(undated.id, '2026-11-21');
      expect(note.readAsStringSync(), timed);
      final checked = vault.setCompleted(restored.id, true, completedAt: DateTime(2026, 11, 19));
      expect(note.readAsStringSync(), timed.replaceFirst('[ ]', '[x]').replaceFirst(' 🆔', ' ✅ 2026-11-19 🆔'));
      expect((checked.task.scheduled, checked.task.start), ('2026-11-20', 540));
      vault.setCompleted(checked.id, false);
      expect(note.readAsBytesSync(), utf8.encode(timed));
    });
  }

  test('TaskForge schedule: add a time, set a duration, move it and clear it', () {
    const reopened = '- [ ] Review revised proofs ➕ 2026-11-19 📅 2026-11-21 🆔 mwnqserw\n';
    const timed = '- [ ] Review revised proofs 🎯 9:00AM ➕ 2026-11-19 ⏳ 2026-11-20 📅 2026-11-21 🆔 mwnqserw\n';
    const ranged = '- [ ] Review revised proofs 🎯 9:00AM-9:30AM ➕ 2026-11-19 ⏳ 2026-11-20 📅 2026-11-21 🆔 mwnqserw\n';
    const moved = '- [ ] Review revised proofs 🎯 2:30PM-3:00PM ➕ 2026-11-19 ⏳ 2026-11-22 📅 2026-11-21 🆔 mwnqserw\n';
    final note = File('${root.path}/TaskForge.md')..writeAsStringSync(reopened);
    final task = vault.list().single;
    expect((task.task.scheduled, task.task.start, task.task.end), (null, null, null));

    final scheduled = vault.schedule(task.id, '2026-11-20', start: 9 * 60);
    expect(note.readAsBytesSync(), utf8.encode(timed));
    expect((scheduled.task.scheduled, scheduled.task.start, scheduled.task.end), ('2026-11-20', 540, null));
    expect((scheduled.task.title, scheduled.task.due), ('Review revised proofs', '2026-11-21'));

    final ranged30 = vault.schedule(scheduled.id, '2026-11-20', start: 540, end: 570);
    expect(note.readAsBytesSync(), utf8.encode(ranged));
    expect(ranged30.task.end, 570);
    final same = vault.schedule(ranged30.id, '2026-11-20', start: 540, end: 570);
    expect(same.revision, ranged30.revision);
    expect(note.readAsBytesSync(), utf8.encode(ranged));

    final later = vault.schedule(same.id, '2026-11-22', start: 14 * 60 + 30, end: 15 * 60);
    expect(note.readAsBytesSync(), utf8.encode(moved));
    final untimed = vault.schedule(later.id, '2026-11-22');
    expect(note.readAsStringSync(), moved.replaceFirst(' 🎯 2:30PM-3:00PM', ''));
    expect((untimed.task.scheduled, untimed.task.start), ('2026-11-22', null));
    vault.schedule(untimed.id, null);
    expect(note.readAsBytesSync(), utf8.encode(reopened));
  });

  test('TaskForge due time from a calendar drop: read it, move it and clear it', () {
    // Bytes TaskForge 3.1.1 wrote when the task was dropped on 2 PM, then on
    // Friday 3:30 PM, in its calendar's Due view.
    const due = '- [ ] Facet due with block 📅 2026-11-21 🆔 mwntjnbu ^facet1\n';
    const dropped = '- [ ] Facet due with block ⏰ 2:00PM 📅 2026-11-21 🆔 mwntjnbu ^facet1\n';
    const moved = '- [ ] Facet due with block ⏰ 3:30PM 📅 2026-11-20 🆔 mwntjnbu ^facet1\n';
    final note = File('${root.path}/TaskForge.md')..writeAsStringSync(moved);
    final read = vault.list().single.task;
    expect((read.title, read.due, read.dueTime), ('Facet due with block', '2026-11-20', 15 * 60 + 30));
    expect((read.scheduled, read.start), (null, null));

    note.writeAsStringSync(due);
    final timed = vault.dueAt(vault.list().single.id, '2026-11-21', 14 * 60);
    expect(note.readAsBytesSync(), utf8.encode(dropped));
    expect((timed.task.title, timed.task.due, timed.task.dueTime), ('Facet due with block', '2026-11-21', 840));
    final later = vault.dueAt(timed.id, '2026-11-20', 15 * 60 + 30);
    expect(note.readAsBytesSync(), utf8.encode(moved));

    // A date-only change keeps the time. Removing the time keeps the date, and
    // clearing the due date takes its time with it.
    final dateOnly = vault.reschedule(later.id, '2026-11-22');
    expect(note.readAsStringSync(), moved.replaceFirst('2026-11-20', '2026-11-22'));
    expect(dateOnly.task.dueTime, 15 * 60 + 30);
    final untimed = vault.dueAt(dateOnly.id, '2026-11-22', null);
    expect(note.readAsStringSync(), due.replaceFirst('2026-11-21', '2026-11-22'));
    expect(untimed.task.dueTime, null);
    final again = vault.dueAt(untimed.id, '2026-11-22', 14 * 60);
    vault.reschedule(again.id, null);
    expect(note.readAsStringSync(), '- [ ] Facet due with block 🆔 mwntjnbu ^facet1\n');
  });

  // TaskForge's agents.md: "an edit re-serializes each field as emoji, keeping
  // an untouched bracket token in its own notation". So the bracket stays in
  // the title, a date change edits it in place, and the new `⏰` joins the
  // emoji fields after the title.
  test('a due time beside a mid-title Dataview due date goes with the emoji fields', () {
    const dataview = '- [ ] Dataview mid [due:: 2026-11-21] title 🆔 mwnyb7ik\n';
    const timed = '- [ ] Dataview mid [due:: 2026-11-21] title ⏰ 2:00PM 🆔 mwnyb7ik\n';
    final note = File('${root.path}/TaskForge.md')..writeAsStringSync(dataview);

    final read = vault.dueAt(vault.list().single.id, '2026-11-21', 14 * 60).task;
    expect(note.readAsBytesSync(), utf8.encode(timed));
    expect((read.title, read.due, read.dueTime), ('Dataview mid title', '2026-11-21', 14 * 60));

    final moved = vault.dueAt(vault.list().single.id, '2026-11-22', 14 * 60);
    expect(note.readAsStringSync(), timed.replaceFirst('2026-11-21', '2026-11-22'));
    vault.dueAt(moved.id, '2026-11-21', null);
    expect(note.readAsBytesSync(), utf8.encode(dataview));
  });

  test('a due time is added next to the due date and alongside a scheduled time', () {
    const scheduled = '- [ ] Review revised proofs 🎯 9:00AM-9:30AM ➕ 2026-11-19 ⏳ 2026-11-20 📅 2026-11-21 🆔 mwnqserw\n';
    final note = File('${root.path}/TaskForge.md')..writeAsStringSync(scheduled);
    final timed = vault.dueAt(vault.list().single.id, '2026-11-21', 17 * 60);
    expect(note.readAsStringSync(), scheduled.replaceFirst(' 📅', ' ⏰ 5:00PM 📅'));
    expect((timed.task.start, timed.task.end, timed.task.dueTime), (540, 570, 1020));

    // A plain task gains both fields at once, before the block ID.
    inbox.writeAsStringSync('- [ ] Draft map ^b1\n');
    final plain = vault.list().singleWhere((t) => t.path == 'Inbox.md');
    vault.dueAt(plain.id, '2028-02-29', 0);
    expect(inbox.readAsStringSync(), '- [ ] Draft map ⏰ 12:00AM 📅 2028-02-29 ^b1\n');

    // A range is not a due time, so it stays in the title.
    expect(parseMarkdown('- [ ] Call ⏰ 2:00PM-2:30PM 📅 2026-11-21\n').single.title, 'Call ⏰ 2:00PM-2:30PM');
    expect(() => vault.dueAt(vault.list().singleWhere((t) => t.path == 'Inbox.md').id, '2028-02-29', 24 * 60),
        throwsFormatException);
  });

  test('capture at a scheduled time writes 🎯 and ⏳ after the title', () {
    final timed = vault.capture('Call the printer', scheduled: '2027-04-14', start: 14 * 60);
    expect(inbox.readAsStringSync(), '- [ ] Call the printer 🎯 2:00PM ⏳ 2027-04-14\n');
    expect((timed.task.scheduled, timed.task.start, timed.task.due), ('2027-04-14', 840, null));

    vault.capture('Pack the proofs', due: '2027-04-16', scheduled: '2027-04-14', start: 14 * 60);
    expect(inbox.readAsStringSync(), endsWith('- [ ] Pack the proofs 🎯 2:00PM ⏳ 2027-04-14 📅 2027-04-16\n'));
    final before = inbox.readAsStringSync();
    expect(() => vault.capture('No day', start: 60), throwsFormatException);
    expect(() => vault.capture('Late', scheduled: '2027-04-14', start: 24 * 60), throwsFormatException);
    expect(inbox.readAsStringSync(), before);
  });

  test('plain Facet task gains, moves and loses a schedule in the same field order', () {
    final task = vault.capture('Draft map', due: '2028-03-01');
    final midnight = vault.schedule(task.id, '2028-02-28', start: 0);
    expect(inbox.readAsStringSync(), '- [ ] Draft map 🎯 12:00AM ⏳ 2028-02-28 📅 2028-03-01\n');
    final late = vault.schedule(midnight.id, '2028-02-29', start: 23 * 60 + 30, end: 24 * 60 + 30);
    expect(inbox.readAsStringSync(), '- [ ] Draft map 🎯 11:30PM-12:30AM ⏳ 2028-02-29 📅 2028-03-01\n');
    expect((late.task.title, late.task.start, late.task.end), ('Draft map', 1410, 1470));
    final undated = vault.reschedule(late.id, null);
    expect(inbox.readAsStringSync(), '- [ ] Draft map 🎯 11:30PM-12:30AM ⏳ 2028-02-29\n');
    final done = vault.setCompleted(undated.id, true);
    expect(inbox.readAsStringSync(), '- [x] Draft map 🎯 11:30PM-12:30AM ⏳ 2028-02-29\n');
    final redated = vault.reschedule(done.id, '2028-03-02');
    expect(inbox.readAsStringSync(), '- [x] Draft map 🎯 11:30PM-12:30AM ⏳ 2028-02-29 📅 2028-03-02\n');
    vault.schedule(redated.id, null);
    expect(inbox.readAsStringSync(), '- [x] Draft map 📅 2028-03-02\n');

    final ship = vault.capture('Ship');
    vault.schedule(ship.id, '2028-01-05', start: 12 * 60 + 5);
    expect(inbox.readAsStringSync(), '- [x] Draft map 📅 2028-03-02\n- [ ] Ship 🎯 12:05PM ⏳ 2028-01-05\n');
  });

  test('schedule edits keep BOM, newlines, tabs and block ID byte for byte', () {
    const original = '﻿* [ ]\tRésumé #copy\t^key  \r\nBody\n  + [ ] Call\t🎯\t9:00AM\t⏳\t2027-04-12';
    inbox.writeAsBytesSync(utf8.encode(original));
    final [first, second] = vault.list();
    final timed = vault.schedule(first.id, '2027-04-12', start: 13 * 60 + 5);
    final withFirst = original.replaceFirst('#copy', '#copy 🎯 1:05PM ⏳ 2027-04-12');
    expect(inbox.readAsBytesSync(), utf8.encode(withFirst));
    final cleared = vault.schedule(timed.id, null);
    expect(inbox.readAsBytesSync(), utf8.encode(original));
    final secondId = vault.list().last.id;
    expect(second.task.title, 'Call');
    expect(cleared.task.title, 'Résumé #copy');
    vault.schedule(secondId, '2027-04-13', start: 10 * 60, end: 11 * 60 + 15);
    expect(inbox.readAsBytesSync(),
        utf8.encode(original.replaceFirst('9:00AM\t⏳\t2027-04-12', '10:00AM-11:15AM\t⏳\t2027-04-13')));
  });

  test('parsed schedules round-trip unchanged and prose emoji stay in the title', () {
    for (final raw in [
      '- [ ] Review revised proofs 🎯 9:00AM ➕ 2026-11-19 ⏳ 2026-11-20 📅 2026-11-21 🆔 mwnqserw',
      '- [x] Review revised proofs 🎯 12:59PM-1:00AM ➕ 2026-11-19 ⏳ 2026-11-20 ✅ 2026-11-19 🆔 mwnqserw',
      '- [ ] Draft 🎯 10:00AM-10:00AM ⏳ 2028-02-29 ^block',
      '- [ ] Only a date ⏳ 2027-01-01',
    ]) {
      final task = parseMarkdown(raw).single;
      expect(task.withSchedule(task.scheduled, start: task.start, end: task.end), raw);
    }
    final timeOnly = parseMarkdown('- [ ] Only a time 🎯 12:00AM 📅 2027-01-02').single;
    expect((timeOnly.title, timeOnly.scheduled, timeOnly.start), ('Only a time', null, 0));
    expect(timeOnly.withSchedule('2027-01-01', start: 0),
        '- [ ] Only a time 🎯 12:00AM ⏳ 2027-01-01 📅 2027-01-02');
    final overnight = parseMarkdown('- [ ] Night 🎯 12:59PM-1:00AM').single;
    expect((overnight.start, overnight.end), (779, 1500));
    final allDay = parseMarkdown('- [ ] Shift 🎯 10:00AM-10:00AM').single;
    expect(allDay.end, 600 + 24 * 60);
    for (final (raw, title) in [
      ('- [ ] Aim 🎯 9:00AM then rest', 'Aim 🎯 9:00AM then rest'),
      ('- [ ] Bad 🎯 13:00PM', 'Bad 🎯 13:00PM'),
      ('- [ ] Twice ⏳ 2027-01-01 ⏳ 2027-01-02', 'Twice ⏳ 2027-01-01'),
    ]) {
      expect(parseMarkdown(raw).single.title, title);
    }
    expect(parseMarkdown('- [ ] Aim 🎯 9:00AM then rest').single.start, isNull);
  });

  test('invalid schedules leave the note intact', () {
    inbox.writeAsStringSync('- [ ] Plan 📅 2027-04-12\n');
    final id = vault.list().single.id;
    for (final edit in <void Function()>[
      () => vault.schedule(id, null, start: 540),
      () => vault.schedule(id, '2027-04-12', end: 570),
      () => vault.schedule(id, '2027-04-12', start: 24 * 60),
      () => vault.schedule(id, '2027-04-12', start: -1),
      () => vault.schedule(id, '2027-04-12', start: 540, end: 540),
      () => vault.schedule(id, '2027-04-12', start: 540, end: 540 + 24 * 60 + 1),
      () => vault.schedule(id, '2027-02-29', start: 540),
    ]) {
      expect(edit, throwsFormatException);
    }
    expect(inbox.readAsStringSync(), '- [ ] Plan 📅 2027-04-12\n');
  });

  test('preserve BOM, mixed newlines, tabs, Markdown and block ID byte for byte', () {
    const original = '\uFEFF* [X]\tRésumé #copy\t^key  \r\nBody\n  + [ ] Second';
    inbox.writeAsBytesSync(utf8.encode(original));
    final dated = vault.reschedule(vault.list().first.id, '2027-04-12');
    expect(inbox.readAsBytesSync(), utf8.encode(original.replaceFirst('#copy', '#copy 📅 2027-04-12')));
    vault.reschedule(dated.id, null);
    expect(inbox.readAsBytesSync(), utf8.encode(original));
    vault.capture('Third');
    expect(inbox.readAsBytesSync(), utf8.encode('$original\r\n- [ ] Third\r\n'));
  });

  test('ignore front matter, fenced examples, hidden folders and symlinks', () {
    inbox.writeAsStringSync('---\n- [ ] Metadata\n---\n~~~~md\n- [ ] Example\n~~~\n'
        '- [ ] Still a sample\n~~~~\n- [ ] Real\n');
    Directory('${root.path}/.obsidian').createSync();
    File('${root.path}/.obsidian/hidden.md').writeAsStringSync('- [ ] Hidden');
    File('${root.path}/note.sync-conflict.md').writeAsStringSync('- [ ] Duplicate');
    if (!Platform.isWindows) Link('${root.path}/alias.md').createSync(inbox.path);
    expect(vault.list().map((t) => t.task.title), ['Real']);
  });

  group('TaskForge and Obsidian Tasks format', () {
    test('a field after the due date no longer hides it, and edits stay in place', () {
      inbox.writeAsStringSync('- [ ] Ship v2 release 📅 2026-07-15 ⏫\n');
      final task = vault.list().single;
      expect(task.task.title, 'Ship v2 release');
      expect(task.task.due, '2026-07-15');
      expect(task.task.priority, 'high');
      final moved = vault.reschedule(task.id, '2026-07-16');
      expect(inbox.readAsStringSync(), '- [ ] Ship v2 release 📅 2026-07-16 ⏫\n');
      vault.reschedule(moved.id, null);
      expect(inbox.readAsStringSync(), '- [ ] Ship v2 release ⏫\n');
    });

    test('all ten checkbox statuses parse, and completing or reopening writes x or a space', () {
      const symbols = {
        ' ': TaskStatus.todo, 'x': TaskStatus.done, 'X': TaskStatus.done, '-': TaskStatus.cancelled,
        '/': TaskStatus.inProgress, '!': TaskStatus.onHold, '>': TaskStatus.planned,
        '~': TaskStatus.deferred, '#': TaskStatus.blocked, '?': TaskStatus.someday, '*': TaskStatus.ready,
      };
      inbox.writeAsStringSync([for (final s in symbols.keys) '- [$s] Task $s'].join('\n'));
      expect(vault.list().map((t) => t.task.status), symbols.values);
      expect(vault.list().where((t) => t.task.status.closed).map((t) => t.task.raw),
          ['- [x] Task x', '- [X] Task X', '- [-] Task -']);
      final active = vault.list().firstWhere((t) => t.task.status == TaskStatus.inProgress);
      final done = vault.setCompleted(active.id, true);
      expect(done.task.raw, '- [x] Task /');
      vault.setCompleted(done.id, false);
      expect(vault.list()[4].task.raw, '- [ ] Task /');
      expect(parseMarkdown('- [y] Not a status\n- [xx] Nor this\n'), isEmpty);
    });

    test('a repeating task shows a clean title but is completed in TaskForge', () {
      const line = '- [ ] Water the plants 🔁 every week 📅 2026-07-15\n';
      inbox.writeAsStringSync(line);
      final task = vault.list().single;
      expect(task.task.title, 'Water the plants');
      expect(task.task.recurrence, 'every week');
      expect(task.task.due, '2026-07-15');
      expect(() => vault.setCompleted(task.id, true), throwsFormatException);
      expect(inbox.readAsStringSync(), line);
      vault.reschedule(task.id, '2026-07-22');
      expect(inbox.readAsStringSync(), '- [ ] Water the plants 🔁 every week 📅 2026-07-22\n');
      inbox.writeAsStringSync('- [x] Water the plants 🔁 every week on Monday ⏫\n');
      final finished = vault.list().single;
      expect(finished.task.recurrence, 'every week on Monday');
      expect(vault.setCompleted(finished.id, false).task.raw, '- [ ] Water the plants 🔁 every week on Monday ⏫');
    });

    test('Dataview fields are read and edited in their own notation', () {
      inbox.writeAsStringSync('- [ ] Book venue [due:: 2026-07-15] (scheduled:: 2026-07-14)\n');
      final task = vault.list().single;
      expect(task.task.title, 'Book venue');
      expect(task.task.due, '2026-07-15');
      expect(task.task.scheduled, '2026-07-14');
      final moved = vault.reschedule(task.id, '2026-07-20');
      expect(inbox.readAsStringSync(), '- [ ] Book venue [due:: 2026-07-20] (scheduled:: 2026-07-14)\n');
      final timed = vault.schedule(moved.id, '2026-07-19', start: 9 * 60);
      expect(inbox.readAsStringSync(), '- [ ] Book venue 🎯 9:00AM [due:: 2026-07-20] (scheduled:: 2026-07-19)\n');
      vault.reschedule(timed.id, null);
      expect(inbox.readAsStringSync(), '- [ ] Book venue 🎯 9:00AM (scheduled:: 2026-07-19)\n');
      final custom = parseMarkdown('- [ ] Estimate [effort:: 3] [due:: soon]').single;
      expect(custom.title, 'Estimate');
      expect(custom.due, isNull);
    });

    test('start dates, created dates, IDs and dependencies stay out of the title', () {
      final tasks = parseMarkdown('- [ ] Start later 🛫 2026-07-12 📅 2026-07-15\n'
          '- [ ] Recurring ➕ 2026-07-01 🔁 every week 📅 2026-07-15 🆔 abc123\n'
          '- [-] Dropped 📅 2026-07-15 ❌ 2026-07-10 ⛔ abc123,def-4 🔢 3/10\n'
          '- [ ] Draft proposal #writing @desk +[[Q3 Roadmap]] 📅 2026-07-15\n'
          '- [ ] Urgent 🔺️ 📅 2026-07-15\n');
      expect(tasks.map((t) => t.title),
          ['Start later', 'Recurring', 'Dropped', 'Draft proposal #writing @desk +[[Q3 Roadmap]]', 'Urgent']);
      expect(tasks.map((t) => t.due), everyElement('2026-07-15'));
      expect(tasks[1].recurrence, 'every week');
      expect(tasks[4].priority, 'highest');
    });

    test('prose that only looks like a field stays in the title', () {
      final tasks = parseMarkdown('- [ ] Water 🔁 later 📅 2026-07-15\n'
          '- [ ] Read ⏫ chapter two\n- [ ] Ask (who:: me?) about it\n');
      expect(tasks.map((t) => t.title), ['Water 🔁 later', 'Read ⏫ chapter two', 'Ask (who:: me?) about it']);
      expect(tasks.first.due, '2026-07-15');
      expect(tasks[1].priority, isNull);
    });

    test('lines carrying TaskForge-stamped IDs parse with their dates', () {
      final tasks = parseMarkdown('- [ ] Facet timed 🎯 9:00AM ⏳ 2026-11-20 🆔 mwntjnel\n'
          '- [ ] Facet overnight 🎯 11:00PM-1:00AM ⏳ 2026-11-20 🆔 mwntjnfm\n'
          '- [ ] Facet due with block 📅 2026-11-20 🆔 mwntjnbu ^facet1\n');
      expect(tasks.map((t) => t.title), ['Facet timed', 'Facet overnight', 'Facet due with block']);
      expect(tasks[0].start, 9 * 60);
      expect((tasks[1].start, tasks[1].end), (23 * 60, 25 * 60));
      expect(tasks[2].due, '2026-11-20');
    });

    // TaskForge 3.1.1 read these lines after a refresh, stamped each with an
    // ID, and listed both on their due day with the titles below. Completing
    // the Dataview line in TaskForge wrote the exact `done` bytes.
    test('a tag after the fields and a Dataview field mid-title keep the due date', () {
      const tagged = '- [ ] Tag after fields 📅 2026-11-21 #work 🆔 mwnyb7gq\n';
      const dataview = '- [ ] Dataview mid [due:: 2026-11-21] title 🆔 mwnyb7ik\n';
      const done = '- [x] Dataview mid [due:: 2026-11-21] title ✅ 2026-11-19 🆔 mwnyb7ik\n';
      final note = File('${root.path}/TaskForge.md')..writeAsStringSync('$tagged$dataview');
      final [tag, mid] = vault.list();
      expect((tag.task.title, tag.task.due), ('Tag after fields', '2026-11-21'));
      expect((mid.task.title, mid.task.due), ('Dataview mid title', '2026-11-21'));

      final completed = vault.setCompleted(mid.id, true, completedAt: DateTime(2026, 11, 19));
      expect(note.readAsStringSync(), '$tagged$done');
      vault.setCompleted(completed.id, false);
      expect(note.readAsStringSync(), '$tagged$dataview');

      // Edits stay in place, and new fields go at the end, not mid-title.
      String id(int line) => vault.list().singleWhere((t) => t.task.line == line).id;
      vault.reschedule(id(1), '2026-11-22');
      vault.reschedule(id(2), '2026-11-23');
      expect(note.readAsStringSync(), '${tagged.replaceFirst('21', '22')}${dataview.replaceFirst('21', '23')}');
      vault.schedule(id(2), '2026-11-20', start: 9 * 60);
      vault.reschedule(id(1), null);
      expect(note.readAsStringSync(), '- [ ] Tag after fields #work 🆔 mwnyb7gq\n'
          '- [ ] Dataview mid [due:: 2026-11-23] title 🎯 9:00AM ⏳ 2026-11-20 🆔 mwnyb7ik\n');
      vault.reschedule(id(2), null);
      expect(vault.list().last.task.title, 'Dataview mid title');
      expect(note.readAsStringSync(), endsWith('- [ ] Dataview mid title 🎯 9:00AM ⏳ 2026-11-20 🆔 mwnyb7ik\n'));
    });

    test('tags before the fields stay in the title, and other bracket text is prose', () {
      final [before, alone, start, unknown, number, twice] = parseMarkdown(
          '- [ ] Draft #tag 📅 2026-11-21 #a #b/c\n'
          '- [ ] #tag\n'
          '- [ ] [due:: 2026-11-21] Call the printer\n'
          '- [ ] Ask [owner:: Bob] about `[due:: 2026-11-21]` today\n'
          '- [ ] Order 📅 2026-11-21 #123\n'
          '- [ ] Fix [due:: 2026-11-20] now 📅 2026-11-21\n');
      expect((before.title, before.due), ('Draft #tag', '2026-11-21'));
      expect((alone.title, alone.due), ('#tag', null));
      expect((start.title, start.due), ('Call the printer', '2026-11-21'));
      expect((unknown.title, unknown.due), ('Ask [owner:: Bob] about `[due:: 2026-11-21]` today', null));
      expect((number.title, number.due), ('Order 📅 2026-11-21 #123', null));
      expect((twice.title, twice.due), ('Fix [due:: 2026-11-20] now', '2026-11-21'));
    });

    test('a line with a TaskForge ID but no creation date gains and loses ✅', () {
      inbox.writeAsStringSync('- [ ] Facet timed 🎯 9:00AM ⏳ 2026-11-20 🆔 mwntjnel\n');
      final done = vault.setCompleted(vault.list().single.id, true, completedAt: DateTime(2026, 11, 19));
      expect(inbox.readAsStringSync(), '- [x] Facet timed 🎯 9:00AM ⏳ 2026-11-20 ✅ 2026-11-19 🆔 mwntjnel\n');
      vault.setCompleted(done.id, false);
      expect(inbox.readAsStringSync(), '- [ ] Facet timed 🎯 9:00AM ⏳ 2026-11-20 🆔 mwntjnel\n');
    });

    test('JSON reports status, priority, recurrence and schedule', () {
      inbox.writeAsStringSync('- [/] Ship ⏳ 2026-07-14 🔁 every week ⏫\n');
      expect(vault.list().single.toJson(), containsPair('status', 'inProgress'));
      expect(vault.list().single.toJson(), allOf(containsPair('priority', 'high'),
          containsPair('recurrence', 'every week'), containsPair('scheduled', '2026-07-14'),
          containsPair('completed', false)));
    });
  });

  test('an opening front matter line without a close is a thematic break', () {
    inbox.writeAsStringSync('---\ntitle: Draft\n- [ ] Visible\n');
    expect(vault.list().map((t) => t.task.title), ['Visible']);
    final added = vault.capture('Also visible');
    expect(added.task.title, 'Also visible');
    expect(inbox.readAsStringSync(), '---\ntitle: Draft\n- [ ] Visible\n- [ ] Also visible\n');
    expect(parseMarkdown('---\n- [ ] Hidden\n...\n- [ ] Shown\n').map((t) => t.title), ['Shown']);
  });

  test('a note that is not UTF-8 is skipped and the rest of the vault still lists', () {
    inbox.writeAsStringSync('- [ ] Readable\n');
    File('${root.path}/Latin-1.md').writeAsBytesSync([0x2d, 0x20, 0x5b, 0x20, 0x5d, 0x20, 0xe9, 0x0a]);
    expect(vault.list().map((t) => t.task.title), ['Readable']);
  });

  test('capture into a folder note creates it there and keeps other notes untouched', () {
    Directory('${root.path}/Clients').createSync();
    final added = vault.capture('Send the invoice', due: '2027-04-12', note: 'Clients/Inbox.md');
    expect(added.path, 'Clients/Inbox.md');
    expect(File('${root.path}/Clients/Inbox.md').readAsStringSync(), '- [ ] Send the invoice 📅 2027-04-12\n');
    expect(inbox.existsSync(), false);
    expect(vault.list().single.id, added.id);
    expect(() => vault.capture('x', note: 'Missing/Inbox.md'), throwsFormatException);
    expect(() => vault.capture('x', note: '../Inbox.md'), throwsFormatException);
    expect(() => vault.capture('x', note: '.obsidian/Inbox.md'), throwsFormatException);
    expect(() => vault.capture('x', note: 'Clients/notes.txt'), throwsFormatException);
  });

  test('edits are scoped to the exact revision, including identical task names', () {
    inbox.writeAsStringSync('- [ ] Call\n- [ ] Call\n');
    final tasks = vault.list();
    vault.setCompleted(tasks.last.id, true);
    expect(() => vault.setCompleted(tasks.first.id, true), throwsA(isA<VaultConflict>()));
    expect(inbox.readAsStringSync(), '- [ ] Call\n- [x] Call\n');
  });

  test('bad inputs and fenced captures leave the note intact', () {
    expect(() => vault.capture('two\nlines'), throwsFormatException);
    expect(() => vault.capture('test', due: '2027-02-29'), throwsFormatException);
    expect(inbox.existsSync(), false);
    inbox.writeAsStringSync('~~~md\n');
    expect(() => vault.capture('hidden'), throwsFormatException);
    expect(inbox.readAsStringSync(), '~~~md\n');
  });

  test('date-only and empty existing checkboxes stay editable', () {
    inbox.writeAsStringSync('- [ ] 📅 2027-04-01');
    final cleared = vault.reschedule(vault.list().single.id, null);
    expect(inbox.readAsStringSync(), '- [ ]');
    vault.reschedule(cleared.id, '2027-04-02');
    expect(inbox.readAsStringSync(), '- [ ] 📅 2027-04-02');
  });

  test('live sync observes external edits, removals and newly created notes', () async {
    vault.capture('First');
    final stream = StreamIterator(vault.watch(interval: const Duration(milliseconds: 20)));
    addTearDown(stream.cancel);
    Future<List<VaultTask>> next() async {
      expect(await stream.moveNext().timeout(const Duration(seconds: 5)), true);
      return stream.current;
    }
    expect((await next()).single.task.title, 'First');
    inbox.writeAsStringSync('- [x] Revised 📅 2027-04-12');
    expect((await next()).single.task.done, true);
    inbox.deleteSync();
    expect(await next(), isEmpty);
    File('${root.path}/Other.md').writeAsStringSync('- [ ] Next');
    expect((await next()).single.path, 'Other.md');
  });

  test('IDs cannot choose outside the vault', () {
    final id = base64Url.encode(utf8.encode(jsonEncode(['../foreign.md', 1, 'r'])));
    expect(() => vault.reschedule(id, null), throwsFormatException);
  });

  test('capture after a note without a final newline and index nested notes', () {
    final folder = Directory('${root.path}/Sprint 1')..createSync();
    File('${folder.path}/Plan.md').writeAsStringSync('- [ ] Nested');
    inbox.writeAsStringSync('# Inbox');
    vault.capture('Ship');
    expect(inbox.readAsStringSync(), '# Inbox\n- [ ] Ship\n');
    expect(vault.list().map((t) => t.path), ['Inbox.md', 'Sprint 1/Plan.md']);
  });
}
