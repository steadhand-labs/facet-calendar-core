# Facet Calendar core

A pure Dart library and CLI for local Markdown task vaults. The package includes a stdio MCP server. It runs independently of Flutter.

Run `dart pub get`, `dart analyze` and `dart test` from this directory. The tests include a seeded byte-preservation fuzzer. Set `FACET_FUZZ_SEED` and `FACET_FUZZ_CASES` to replay a reported case or run more. Start with an existing UTF-8 Markdown folder.

```dart
import 'dart:io';
import 'package:facet_calendar_core/facet_calendar_core.dart';

void main(List<String> args) {
  final vault = Vault(Directory(args.single));
  final task = vault.capture('Review proofs');
  final dated = vault.reschedule(task.id, '2027-04-12');
  vault.setCompleted(dated.id, true);
}
```

This sequence creates `Inbox.md` with one line, `- [x] Review proofs 📅 2027-04-12`. To parse text without filesystem access, call `parseMarkdown(source)`. Each returned task includes its one-based line number, raw line, title, due date, and completion state.

Run `dart run bin/facet.dart --help` for the command reference. `written-dates` lists open tasks whose title opens with a date in words, such as `**Thu Nov 5** · Study`, with the date Facet reads from it; the weekday or a written year must pin it down. `written-dates apply` adds each one as `📅` and changes nothing else on the line. Use `dart run bin/facet.dart /path/to/vault mcp` to serve the same vault to a local MCP client. Its tools are `list_tasks`, `capture_task`, `reschedule_task` (with an optional `⏰` `time`), `schedule_task` (a `⏳` date with an optional `🎯` start and end) and `set_completion`. Times are 24-hour `HH:MM`, and an end at or before the start falls on the next day. The server implements initialization, ping, tool listing and tool calls for protocol version `2025-06-18`. Responses go to stdout and diagnostics go to stderr.

Task IDs expire when any byte of their note changes. Read the new list after a conflict and reapply the intended edit. New dates use a trailing `📅 YYYY-MM-DD` before an optional block ID. Clearing the date keeps the task in its original note. Standard Markdown bullets, nested tasks, uppercase completed checkboxes, CRLF and UTF-8 BOMs are supported. The parser skips fenced code and initial YAML front matter. An opening `---` without a closing line is read as a thematic break, so the note's tasks stay visible. Unicode line and paragraph separators stay inside a task title. Notes that are not valid UTF-8 are left out of the listing rather than failing it. `capture` adds to `Inbox.md` by default. Pass `note:` with another vault-relative Markdown path in an existing folder, such as `Clients/Inbox.md`.

Facet reads the TaskForge and Obsidian Tasks emoji format. All ten TaskForge checkbox statuses are tasks: `[ ]` todo, `[x]` or `[X]` done, `[-]` cancelled, `[/]` in progress, `[!]` on hold, `[>]` planned, `[~]` deferred, `[#]` blocked, `[?]` someday and `[*]` ready. `status.closed` covers done and cancelled. The fields at the end of a task may come in any order: `📅` due, `⏳` scheduled, `🛫` start, `✅` done, `❌` cancelled and `➕` created dates, `🎯` time, `⏰` due time, the priorities `🔺 ⏫ 🔼 🔽 ⏬`, `🔁` rules beginning with "every", `🔢` limits, `🆔` IDs, `⛔` dependencies, and Dataview fields such as `[due:: 2026-07-15]` or `(scheduled:: 2026-07-14)`. Tags such as `#work` may sit among the fields once one has started, as in `📅 2026-07-15 #work`. The title is the text before them, so a tag before the first field stays in the title. A Dataview field with a known meaning is also read inside the title and left out of the displayed title, as TaskForge does. New fields still go at the end. Edits keep each field in its own notation. A repeating task can be reopened and rescheduled, but completing it throws, because TaskForge must create the next occurrence. Listings report `status`, `scheduled`, `priority` and `recurrence` as well, plus `start`, `end` and `dueTime` as 24-hour `HH:MM`.

TaskForge stamps a `🆔` identifier on every task it indexes. Tasks with one keep it, and any `➕` creation date, when edited. Facet inserts the due date before the completion date or identifier. Completing a task that has a `🆔` writes `✅` with the local completion day before the identifier, as TaskForge does. Reopening it removes the completion date. Tasks without a `🆔` only change their checkbox. TaskForge's `⏳` scheduled date and `🎯` start time or time range survive these edits. TaskForge writes a `⏰` due time such as `⏰ 2:00PM` directly before `📅` when a task is dropped on a time slot in its Due view. `vault.dueAt` sets or moves both in place, and a null time removes only `⏰`. Rescheduling keeps the time, and clearing the due date removes it too. The displayed title excludes these fields, and only `📅` supplies the calendar due day.

Subscribe to `vault.watch()` for an initial listing and each later change, including external edits. It emits only when a task, its line or its note's revision changes. On macOS and Windows a recursive filesystem watcher rescans the vault once a burst of events has been quiet for 200 ms, and a full rescan every 30 seconds covers missed events. Events under hidden entries such as `.obsidian`, Facet's `.facet-calendar.lock` and `.facet-write-*` staging folders, sync conflicts and non-Markdown files are ignored. `dart:io` has no recursive watching on Linux, iOS or Android, so the vault is polled every 3 seconds there. Polling also applies with `fileEvents: false`, for example on network drives, and after the watcher fails. Pass `initial` with a listing you already hold to skip an unchanged first emission. The `debounce`, `rescan` and `interval` arguments tune these timings. Cancelling the subscription stops the watcher and its timers.

Licensed under the [MIT license](LICENSE).
