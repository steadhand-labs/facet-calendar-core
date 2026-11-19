import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:facet_calendar_core/src/mcp.dart';

const usage = '''
facet VAULT list
facet VAULT add TITLE [YYYY-MM-DD]
facet VAULT due ID YYYY-MM-DD|none
facet VAULT due ID YYYY-MM-DD HH:MM|none
facet VAULT schedule ID YYYY-MM-DD|none [HH:MM[-HH:MM]]
facet VAULT complete ID true|false
facet VAULT mcp''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.first == '--help' || args.first == '-h')) {
    stdout.writeln(usage);
    return;
  }
  try {
    if (args.length < 2) throw const FormatException(usage);
    final vault = Vault(Directory(args.first));
    final command = args.sublist(1);
    Object result;
    switch (command) {
      case ['list']:
        result = vault.list().map((task) => task.toJson()).toList();
      case ['add', String title]:
        result = vault.capture(title).toJson();
      case ['add', String title, String due]:
        result = vault.capture(title, due: due).toJson();
      case ['due', String id, String date]:
        result = vault.reschedule(id, date == 'none' ? null : date).toJson();
      case ['due', String id, String date, String time] when date != 'none':
        result = vault.dueAt(id, date, time == 'none' ? null : parseClock(time)).toJson();
      case ['schedule', String id, String date]:
        result = vault.schedule(id, date == 'none' ? null : date).toJson();
      case ['schedule', String id, String date, String times] when date != 'none':
        final parts = times.split('-');
        if (parts.length > 2) throw const FormatException(usage);
        final range = clockRange(parts.first, parts.length == 2 ? parts.last : null);
        result = vault.schedule(id, date, start: range.start, end: range.end).toJson();
      case ['complete', String id, String value] when value == 'true' || value == 'false':
        result = vault.setCompleted(id, value == 'true').toJson();
      case ['mcp']:
        final server = FacetServer(vault);
        await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
          final response = server.handle(line);
          if (response != null) stdout.writeln(jsonEncode(response));
        }
        return;
      default:
        throw const FormatException(usage);
    }
    stdout.writeln(jsonEncode(result));
  } on Exception catch (e) {
    stderr.writeln(e);
    exitCode = e is FormatException ? 64 : 1;
  }
}
