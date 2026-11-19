import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:test/test.dart';

import 'support/notes.dart';

String _ms(Duration d) => '${d.inMicroseconds / 1000} ms';

void main() {
  test('a 2,000-note vault lists, edits and starts watching within generous budgets', () async {
    final root = Directory.systemTemp.createTempSync('facet-large-');
    addTearDown(() => root.deleteSync(recursive: true));
    final generator = NoteGenerator(20261119);
    final clock = Stopwatch()..start();
    var tasks = 0, bytes = 0;
    for (var n = 0; n < 2000; n++) {
      final note = generator.withTasks(9);
      tasks += note.lines.where((l) => l.task != null).length;
      final data = utf8.encode(note.text);
      bytes += data.length;
      File('${root.path}/Area ${n % 10}/Project ${n ~/ 10 % 20}/${n.isEven ? 'Notes/' : ''}Note $n.md')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(data);
    }
    final written = clock.elapsed;
    final vault = Vault(root);

    clock.reset();
    final listing = vault.list();
    final cold = clock.elapsed;
    clock.reset();
    vault.list();
    final warm = clock.elapsed;
    expect(listing, hasLength(tasks));

    final target = listing.last;
    clock.reset();
    final moved = vault.reschedule(target.id, '2031-01-02');
    final reschedule = clock.elapsed;
    expect(moved.task.due, '2031-01-02');

    clock.reset();
    final first = await vault.watch().first;
    final watchFirst = clock.elapsed;
    expect(first, hasLength(tasks));

    // An external edit in a nested note: events where available, else a 500 ms poll.
    final updates = StreamIterator(
        vault.watch(initial: vault.list(), interval: const Duration(milliseconds: 500)));
    addTearDown(updates.cancel);
    final next = updates.moveNext(); // Starts listening before the edit.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    clock.reset();
    File('${root.path}/${listing.first.path}')
        .writeAsStringSync('- [ ] Appended externally\n', mode: FileMode.append);
    expect(await next.timeout(const Duration(seconds: 20)), true);
    final external = clock.elapsed;
    expect(updates.current, hasLength(tasks + 1));

    print('Large vault: 2000 notes, $tasks tasks, ${(bytes / 1e6).toStringAsFixed(1)} MB written in '
        '${_ms(written)}. list ${_ms(cold)} (warm ${_ms(warm)}), reschedule ${_ms(reschedule)}, '
        'first watch() emission ${_ms(watchFirst)}, external edit emitted after ${_ms(external)}.');
    expect(cold, lessThan(const Duration(seconds: 5)));
    expect(warm, lessThan(const Duration(seconds: 5)));
    // Shared CI runners (especially Windows) can stall on a single write; keep this
    // in the same "generous" band as cold list, not a laptop micro-benchmark.
    expect(reschedule, lessThan(const Duration(seconds: 5)));
    expect(watchFirst, lessThan(const Duration(seconds: 10)));
    expect(external, lessThan(const Duration(seconds: 10)));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a long whitespace run parses in linear time', () {
    final clock = Stopwatch()..start();
    expect(parseMarkdown('- [ ] a${' ' * 64000}b').single.title, 'a${' ' * 64000}b');
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
  });
}
