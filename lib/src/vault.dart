import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'markdown.dart';

class VaultConflict implements Exception {
  @override
  String toString() => 'This note changed. Refresh and retry your edit.';
}

class VaultTask {
  const VaultTask(this.path, this.revision, this.task);
  final String path;
  final String revision;
  final MarkdownTask task;

  String get id => base64Url.encode(utf8.encode(jsonEncode([path, task.line, revision])));
  Map<String, Object?> toJson() => {
    'id': id, 'file': path, 'line': task.line,
    'title': task.title, 'completed': task.done, 'due': task.due,
    'status': task.status.name, 'scheduled': task.scheduled,
    'priority': task.priority, 'recurrence': task.recurrence,
  };
}

class _Note {
  _Note(this.bytes, this.exists)
      : text = (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf
            ? '\uFEFF' : '') + utf8.decode(bytes),
        revision = sha256.convert(bytes).toString();
  factory _Note.read(File file) =>
      file.existsSync() ? _Note(file.readAsBytesSync(), true) : _Note([], false);
  final List<int> bytes;
  final bool exists;
  final String text;
  final String revision;
}

/// A vault is an existing directory. IDs expire when their source note changes.
class Vault {
  Vault(Directory directory) : root = Directory(directory.resolveSymbolicLinksSync());
  final Directory root;

  bool _visible(String name) => !name.startsWith('.') &&
      !name.toLowerCase().contains('sync-conflict');

  Iterable<(File, String)> _notes(Directory directory, String prefix) sync* {
    for (final entry in directory.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!_visible(name)) continue;
      final relative = '$prefix$name';
      if (entry is Directory) {
        yield* _notes(entry, '$relative/');
      } else if (entry is File && name.toLowerCase().endsWith('.md')) {
        yield (entry, relative);
      }
    }
  }

  List<VaultTask> list() {
    final result = <VaultTask>[];
    for (final (file, path) in _notes(root, '')) {
      final _Note note;
      try {
        note = _Note.read(file);
      } on FormatException {
        continue; // Not UTF-8. Skip this note rather than hide the whole vault.
      }
      for (final task in parseMarkdown(note.text)) {
        result.add(VaultTask(path, note.revision, task));
      }
    }
    result.sort((a, b) {
      final order = a.path.compareTo(b.path);
      return order == 0 ? a.task.line.compareTo(b.task.line) : order;
    });
    return result;
  }

  /// Emits an initial listing, then each listing in which a task, its line or
  /// its note revision changed, including external edits.
  ///
  /// On macOS and Windows a recursive filesystem watcher triggers a rescan
  /// once events pause for [debounce]. Events under hidden entries (including
  /// Facet's lock and staging folders), sync conflicts and other file types
  /// are ignored, and a full rescan every [rescan] covers missed events. On
  /// other platforms, with [fileEvents] false, or after the watcher fails,
  /// the vault is polled every [interval]. Supplying the current listing as
  /// [initial] skips the first emission unless the vault changed since.
  Stream<List<VaultTask>> watch({
    Duration interval = const Duration(seconds: 3),
    List<VaultTask>? initial,
    Duration rescan = const Duration(seconds: 30),
    Duration debounce = const Duration(milliseconds: 200),
    bool fileEvents = true,
  }) {
    if (interval <= Duration.zero) throw ArgumentError.value(interval, 'interval');
    if (rescan <= Duration.zero) throw ArgumentError.value(rescan, 'rescan');
    if (debounce < Duration.zero) throw ArgumentError.value(debounce, 'debounce');
    final path = root.path;
    var previous = initial;
    var reading = false, again = false;
    String? lastError;
    Timer? timer, quiet;
    Stopwatch? burst;
    StreamSubscription<FileSystemEvent>? events;
    late final StreamController<List<VaultTask>> controller;

    Future<void> scan() async {
      if (!controller.hasListener || controller.isPaused) return;
      if (reading) {
        again = true; // Rescan after this pass so a mid-scan edit is not lost.
        return;
      }
      reading = true;
      try {
        do {
          again = false;
          try {
            final next = await _backgroundList(path);
            if (!controller.hasListener) return;
            if (lastError != null || !_sameListing(previous, next)) {
              controller.add(next);
              previous = next;
            }
            lastError = null;
          } on Exception catch (e, stack) {
            if (controller.hasListener && e.toString() != lastError) {
              lastError = e.toString();
              controller.addError(e, stack);
            }
          }
        } while (again && controller.hasListener && !controller.isPaused);
      } finally {
        reading = false;
      }
    }

    void poll(Duration every) {
      timer?.cancel();
      timer = Timer.periodic(every, (_) => scan());
    }

    void changed() {
      final started = burst ??= Stopwatch()..start();
      // Each event restarts the quiet period, but a burst that never pauses
      // still rescans once it has lasted five quiet periods.
      if (quiet != null && started.elapsed >= debounce * 5) return;
      quiet?.cancel();
      quiet = Timer(debounce, () {
        quiet = null;
        burst = null;
        scan();
      });
    }

    void fallBack() {
      final watcher = events;
      if (watcher == null || !controller.hasListener) return;
      events = null;
      watcher.cancel();
      poll(interval);
      scan();
    }

    bool listenForEvents() {
      // dart:io only watches recursively on macOS and Windows.
      if (!fileEvents || !(Platform.isMacOS || Platform.isWindows) ||
          !FileSystemEntity.isWatchSupported) {
        return false;
      }
      try {
        events = root.watch(recursive: true).listen((event) {
          if (_affectsListing(event)) changed();
        }, onError: (Object _) => fallBack(), onDone: fallBack);
        return true;
      } on FileSystemException {
        return false;
      }
    }

    controller = StreamController(
      onListen: () {
        final watching = listenForEvents();
        poll(watching ? rescan : interval);
        if (initial == null) {
          scan();
        } else if (watching) {
          changed(); // Catch edits made after `initial` was read but before the watcher started.
        }
      },
      onResume: scan,
      onCancel: () {
        timer?.cancel();
        quiet?.cancel();
        final watcher = events;
        events = null;
        return watcher?.cancel();
      },
    );
    return controller.stream;
  }

  bool _affectsListing(FileSystemEvent event) {
    bool affects(String path) {
      if (!path.startsWith(root.path)) return true;
      final parts = path.substring(root.path.length).split(_separator)
        ..removeWhere((s) => s.isEmpty);
      if (parts.any((s) => !_visible(s))) return false;
      final name = parts.isEmpty ? '' : parts.last.toLowerCase();
      // Windows reports deletions without a type, so a dotless name may be a folder.
      return event.isDirectory || name.endsWith('.md') || !name.contains('.');
    }
    final destination = event is FileSystemMoveEvent ? event.destination : null;
    return affects(event.path) || (destination != null && affects(destination));
  }

  File _file(String relative) {
    final parts = relative.split('/');
    if (!relative.toLowerCase().endsWith('.md') ||
        parts.any((s) => s.isEmpty || !_visible(s) || s.contains(RegExp(r'[\\:\x00]')))) {
      throw const FormatException('Expected a relative Markdown note path.');
    }
    var path = root.path;
    for (final part in parts) {
      path = '$path${Platform.pathSeparator}$part';
      if (FileSystemEntity.isLinkSync(path)) {
        throw const FormatException('Choose a note inside the vault.');
      }
    }
    return File(path);
  }

  T _locked<T>(T Function() action) {
    final lock = File('${root.path}/.facet-calendar.lock');
    if (FileSystemEntity.isLinkSync(lock.path)) {
      throw const FormatException('The vault lock must be a regular file.');
    }
    final handle = lock.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.blockingExclusive);
      return action();
    } finally {
      handle.closeSync();
    }
  }

  void _save(File file, _Note before, String next) {
    final temp = file.parent.createTempSync('.facet-write-');
    try {
      final staged = File('${temp.path}/note');
      if (before.exists) file.copySync(staged.path);
      staged.writeAsBytesSync(utf8.encode(next), flush: true);
      final current = _Note.read(file);
      if (current.exists != before.exists || current.revision != before.revision) {
        throw VaultConflict();
      }
      staged.renameSync(file.path);
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  /// Appends an open task to [note], a vault-relative Markdown path whose
  /// folder already exists. The note is created when missing.
  VaultTask capture(String title, {String? due, String note = 'Inbox.md'}) {
    if (title.trim().isEmpty || title.contains(lineBreak) || title.contains('\u0000')) {
      throw const FormatException('Enter a task title on one line.');
    }
    if (due != null) validateDate(due);
    final file = _file(note);
    if (!file.parent.existsSync()) {
      throw const FormatException('Choose a note in an existing folder.');
    }
    return _locked(() {
      final path = note;
      final before = _Note.read(file);
      final ending = lineBreak.firstMatch(before.text)?.group(0) ?? '\n';
      final needsBreak = before.text.isNotEmpty && before.text != '\uFEFF' &&
          !before.text.endsWith('\n') && !before.text.endsWith('\r');
      final row = '- [ ] ${title.trim()}${due == null ? '' : ' 📅 $due'}';
      final next = '${before.text}${needsBreak ? ending : ''}$row$ending';
      final tasks = parseMarkdown(next);
      if (tasks.isEmpty || tasks.last.line != lineBreak.allMatches(next).length) {
        throw FormatException('Close the code fence in $path first.');
      }
      _save(file, before, next);
      return VaultTask(path, sha256.convert(utf8.encode(next)).toString(), tasks.last);
    });
  }

  VaultTask reschedule(String id, String? due) =>
      _update(id, (task) => task.withDue(due));

  /// Sets the work date and an optional start and end in minutes after
  /// midnight. A null date clears the schedule.
  VaultTask schedule(String id, String? date, {int? start, int? end}) =>
      _update(id, (task) => task.withSchedule(date, start: start, end: end));

  VaultTask setCompleted(String id, bool done, {DateTime? completedAt}) =>
      _update(id, (task) => task.withCompletion(done, completedAt: completedAt));

  VaultTask _update(String id, String Function(MarkdownTask) edit) {
    final Object? key = jsonDecode(utf8.decode(base64Url.decode(id)));
    if (key is! List || key.length != 3 || key[0] is! String ||
        key[1] is! int || key[2] is! String) {
      throw const FormatException('Invalid task ID.');
    }
    final path = key[0] as String;
    return _locked(() {
      final file = _file(path);
      final before = _Note.read(file);
      if (!before.exists || before.revision != key[2]) throw VaultConflict();
      final tasks = parseMarkdown(before.text);
      final index = tasks.indexWhere((t) => t.line == key[1]);
      if (index == -1) throw VaultConflict();
      final task = tasks[index];
      final replacement = edit(task);
      if (replacement == task.raw) return VaultTask(path, before.revision, task);
      var offset = task.line == 1 ? 0 :
          lineBreak.allMatches(before.text).elementAt(task.line - 2).end;
      if (offset == 0 && before.text.startsWith('\uFEFF')) offset++;
      final next = before.text.replaceRange(offset, offset + task.raw.length, replacement);
      final updated = parseMarkdown(next).singleWhere((t) => t.line == task.line);
      _save(file, before, next);
      return VaultTask(path, sha256.convert(utf8.encode(next)).toString(), updated);
    });
  }
}

final _separator = RegExp(r'[\\/]');

Future<List<VaultTask>> _backgroundList(String path) =>
    Isolate.run(() => Vault(Directory(path)).list());

bool _sameListing(List<VaultTask>? previous, List<VaultTask> next) {
  if (previous == null || previous.length != next.length) return false;
  for (var i = 0; i < next.length; i++) {
    if (previous[i].path != next[i].path || previous[i].revision != next[i].revision ||
        previous[i].task.line != next[i].task.line) return false;
  }
  return true;
}
