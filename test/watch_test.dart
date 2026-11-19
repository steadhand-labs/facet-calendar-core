import 'dart:async';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:test/test.dart';

final _events = Platform.isMacOS || Platform.isWindows;
final Object _needsEvents = _events ? false : 'dart:io watches recursively only on macOS and Windows';

/// Listens to a watch stream inside a zone that records every timer it creates.
class _Recorder {
  _Recorder(Stream<List<VaultTask>> Function() watch) {
    Timer track(Timer timer) {
      timers.add(timer);
      return timer;
    }

    subscription = runZoned(
      () => watch().listen((tasks) {
        emissions.add(tasks);
        stamps.add(clock.elapsed);
      }, onError: (Object error) => errors.add(error)),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) =>
            track(parent.createTimer(zone, duration, callback)),
        createPeriodicTimer: (self, parent, zone, duration, callback) =>
            track(parent.createPeriodicTimer(zone, duration, callback)),
      ),
    );
  }
  final clock = Stopwatch()..start();
  final timers = <Timer>[];
  final emissions = <List<VaultTask>>[];
  final stamps = <Duration>[];
  final errors = <Object>[];
  late final StreamSubscription<List<VaultTask>> subscription;
  var _checked = 0;

  /// Waits for an emission, newer than any already checked, that passes [test].
  Future<List<VaultTask>> until(bool Function(List<VaultTask>) test,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final start = clock.elapsed;
    for (;; await Future<void>.delayed(const Duration(milliseconds: 5))) {
      while (_checked < emissions.length) {
        final tasks = emissions[_checked++];
        if (test(tasks)) return tasks;
      }
      if (clock.elapsed - start > timeout) {
        throw TimeoutException('No matching listing among ${emissions.length} emissions', timeout);
      }
    }
  }
}

void main() {
  late Directory root;
  late Vault vault;
  late File inbox;
  setUp(() {
    root = Directory.systemTemp.createTempSync('facet-watch-');
    vault = Vault(root);
    inbox = File('${vault.root.path}/Inbox.md');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File note(String relative) => File('${vault.root.path}/$relative')..parent.createSync(recursive: true);

  // On Linux both variants poll; on macOS and Windows the first uses events.
  for (final fileEvents in [true, false]) {
    group('fileEvents: $fileEvents', () {
      test('emits the listing, edits, removals and new nested notes', () async {
        inbox.writeAsStringSync('- [ ] First\n');
        final recorder = _Recorder(() =>
            vault.watch(interval: const Duration(milliseconds: 20), fileEvents: fileEvents));
        addTearDown(recorder.subscription.cancel);
        expect((await recorder.until((t) => t.isNotEmpty)).single.task.title, 'First');
        inbox.writeAsStringSync('- [x] Revised 📅 2027-04-12');
        await recorder.until((t) => t.length == 1 && t.single.task.done);
        inbox.deleteSync();
        await recorder.until((t) => t.isEmpty);
        note('Area/Deep/Other.md').writeAsStringSync('- [ ] Next');
        expect((await recorder.until((t) => t.isNotEmpty)).single.path, 'Area/Deep/Other.md');
        expect(recorder.errors, isEmpty);
      });

      test('a burst of writes yields a bounded number of emissions', () async {
        const interval = Duration(milliseconds: 250);
        final recorder = _Recorder(() => vault.watch(interval: interval, fileEvents: fileEvents));
        addTearDown(recorder.subscription.cancel);
        await recorder.until((t) => t.isEmpty);
        final burst = Stopwatch()..start();
        for (var i = 0; i < 30; i++) {
          note('Burst/Note $i.md').writeAsStringSync('- [ ] Task $i\n');
          inbox.writeAsStringSync('- [ ] Inbox revision $i\n');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final duration = burst.elapsed;
        await recorder.until((t) => t.length == 31 && t.any((v) => v.task.title == 'Inbox revision 29'),
            timeout: const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final changes = recorder.emissions.length - 1;
        // Events are debounced into one rescan, plus one per second of a burst that never pauses.
        final bound = fileEvents && _events ? 3 : (duration.inMicroseconds / interval.inMicroseconds).ceil() + 2;
        print('A ${duration.inMilliseconds} ms burst of 60 writes produced $changes emissions '
            '(bound $bound, ${fileEvents && _events ? 'events' : 'polling'}).');
        expect(changes, inInclusiveRange(1, bound));
        expect(recorder.emissions.last, hasLength(31));
      });

      test('cancelling stops the watcher, the debounce and every timer', () async {
        inbox.writeAsStringSync('- [ ] Before\n');
        final recorder = _Recorder(() => vault.watch(interval: const Duration(milliseconds: 50),
            debounce: const Duration(milliseconds: 100), fileEvents: fileEvents));
        await recorder.until((t) => t.isNotEmpty);
        inbox.writeAsStringSync('- [ ] Pending\n');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await recorder.subscription.cancel();
        expect(recorder.timers, isNotEmpty);
        expect(recorder.timers.where((t) => t.isActive), isEmpty);

        final timers = recorder.timers.length, emissions = recorder.emissions.length;
        inbox.writeAsStringSync('- [ ] After\n');
        note('Later/Note.md').writeAsStringSync('- [ ] Later');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(recorder.timers, hasLength(timers), reason: 'No event may schedule a rescan after cancel.');
        expect(recorder.timers.where((t) => t.isActive), isEmpty);
        expect(recorder.emissions, hasLength(emissions));
      });

      test('a removed vault folder reports an error, then recovers when it returns', () async {
        inbox.writeAsStringSync('- [ ] Task\n');
        final recorder = _Recorder(() =>
            vault.watch(interval: const Duration(milliseconds: 50), fileEvents: fileEvents));
        addTearDown(recorder.subscription.cancel);
        await recorder.until((t) => t.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        root.deleteSync(recursive: true);
        for (var i = 0; recorder.errors.isEmpty; i++) {
          expect(i, lessThan(1000), reason: 'The missing folder must be reported.');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        root.createSync();
        inbox.writeAsStringSync('- [ ] Back\n');
        await recorder.until((t) => t.isNotEmpty && t.single.task.title == 'Back');
        // A scan racing the deletion may fail differently once; repeats are not re-emitted.
        expect(recorder.errors.length, inInclusiveRange(1, 2));
        expect(recorder.errors, everyElement(isA<FileSystemException>()));
      });
    });
  }

  test('an external edit arrives well before the polling and safety-net intervals', () async {
    final plan = note('Area/Project/Plan.md')..writeAsStringSync('- [ ] Plan\n');
    final recorder = _Recorder(() => vault.watch(initial: vault.list(), rescan: const Duration(minutes: 5)));
    addTearDown(recorder.subscription.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(recorder.emissions, isEmpty, reason: 'An unchanged vault emits nothing after `initial`.');

    final edited = recorder.clock.elapsed;
    plan.writeAsStringSync('- [x] Plan 📅 2027-04-12\n');
    await recorder.until((t) => t.single.task.done);
    final edit = recorder.stamps.last - edited;
    final created = recorder.clock.elapsed;
    note('New folder/Sub/Fresh.md').writeAsStringSync('- [ ] Fresh');
    await recorder.until((t) => t.length == 2);
    final folder = recorder.stamps.last - created;
    print('Edit seen after ${edit.inMilliseconds} ms, new nested folder after ${folder.inMilliseconds} ms '
        '(polling interval 3 s, safety net 5 min).');
    expect(edit, lessThan(const Duration(milliseconds: 1500)));
    expect(folder, lessThan(const Duration(milliseconds: 1500)));
  }, skip: _needsEvents);

  test('an edit made after reading `initial` but before listening is not left to the safety net', () async {
    inbox.writeAsStringSync('- [ ] Task\n');
    final initial = vault.list();
    inbox.writeAsStringSync('- [x] Task\n');
    await Future<void>.delayed(const Duration(seconds: 1));
    final recorder = _Recorder(() => vault.watch(initial: initial, rescan: const Duration(minutes: 5)));
    addTearDown(recorder.subscription.cancel);
    await recorder.until((t) => t.single.task.done, timeout: const Duration(seconds: 2));
  }, skip: _needsEvents);

  test('hidden entries, Facet staging files, conflicts and attachments do not trigger rescans', () async {
    inbox.writeAsStringSync('- [ ] Task\n');
    final recorder = _Recorder(() =>
        vault.watch(initial: vault.list(), debounce: const Duration(milliseconds: 50)));
    addTearDown(recorder.subscription.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final settled = recorder.timers.length;

    note('.obsidian/workspace.json').writeAsStringSync('{}');
    note('.facet-write-test/note').writeAsStringSync('- [ ] Staged');
    File('${vault.root.path}/.facet-calendar.lock').writeAsStringSync('');
    note('Inbox.sync-conflict-20261119.md').writeAsStringSync('- [ ] Conflict');
    note('diagram.png').writeAsBytesSync([0x89, 0x50]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(recorder.timers, hasLength(settled), reason: 'Ignored paths must not schedule a rescan.');
    expect(recorder.emissions, isEmpty);

    inbox.writeAsStringSync('- [x] Task\n');
    await recorder.until((t) => t.single.task.done);
    expect(recorder.timers.length, greaterThan(settled));
  }, skip: _needsEvents);

  test('invalid intervals are rejected', () {
    expect(() => vault.watch(interval: Duration.zero), throwsArgumentError);
    expect(() => vault.watch(rescan: Duration.zero), throwsArgumentError);
    expect(() => vault.watch(debounce: const Duration(milliseconds: -1)), throwsArgumentError);
  });
}
