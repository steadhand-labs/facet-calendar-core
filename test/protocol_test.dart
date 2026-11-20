import 'dart:convert';
import 'dart:io';

import 'package:facet_calendar_core/facet_calendar_core.dart';
import 'package:facet_calendar_core/src/mcp.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('facet-protocol-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('MCP initialization, notifications, discovery and revision-bound tools', () {
    final server = FacetServer(Vault(root));
    Json request(String method, [Json params = const {}]) => server.handle(
      jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
    )!;
    Json call(String name, Json args) => request('tools/call', {'name': name, 'arguments': args});
    dynamic payload(Json r) => jsonDecode(r['result']['content'][0]['text'] as String);
    expect(server.handle('{')!['error']['code'], -32700);
    expect(request('tools/list')['error']['code'], -32002);
    final init = request('initialize', {
      'clientInfo': {'name': 'test', 'version': '1'}, 'capabilities': {},
      'protocolVersion': '2025-06-18',
    });
    expect(init['result']['protocolVersion'], '2025-06-18');
    expect(server.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}'), isNull);
    expect(request('tools/list')['result']['tools'], hasLength(5));
    final created = payload(call('capture_task', {'title': 'Proof'}));
    final dated = payload(call('reschedule_task', {'id': created['id'], 'due': '2027-04-02'}));
    final done = payload(call('set_completion', {'id': dated['id'], 'completed': true}));
    expect(done['completed'], true);
    expect(payload(call('list_tasks', {})).single['id'], done['id']);
    expect(call('reschedule_task', {'id': created['id'], 'due': null})['result']['isError'], true);
    expect(call('set_completion', {'id': done['id'], 'completed': 'yes'})['error']['code'], -32602);
  });

  test('MCP tools set a schedule, a range past midnight and a TaskForge due time', () {
    final server = FacetServer(Vault(root));
    Json request(String method, [Json params = const {}]) => server.handle(
      jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
    )!;
    Json call(String name, Json args) => request('tools/call', {'name': name, 'arguments': args});
    dynamic payload(Json r) => jsonDecode(r['result']['content'][0]['text'] as String);
    request('initialize', {
      'clientInfo': {'name': 'test', 'version': '1'}, 'capabilities': {}, 'protocolVersion': '2025-06-18',
    });
    server.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}');
    final inbox = File('${root.path}/Inbox.md');

    final task = payload(call('capture_task', {'title': 'Pack the proofs', 'due': '2027-04-16'}));
    final timed = payload(call('schedule_task',
        {'id': task['id'], 'date': '2027-04-13', 'start': '14:00', 'end': '15:30'}));
    expect(inbox.readAsStringSync(), '- [ ] Pack the proofs 🎯 2:00PM-3:30PM ⏳ 2027-04-13 📅 2027-04-16\n');
    expect(timed, allOf(containsPair('scheduled', '2027-04-13'), containsPair('start', '14:00'),
        containsPair('end', '15:30'), containsPair('dueTime', null)));
    final late = payload(call('schedule_task', {'id': timed['id'], 'date': '2027-04-13', 'start': '23:00', 'end': '01:00'}));
    expect(inbox.readAsStringSync(), '- [ ] Pack the proofs 🎯 11:00PM-1:00AM ⏳ 2027-04-13 📅 2027-04-16\n');
    expect((late['start'], late['end']), ('23:00', '01:00'));

    final due = payload(call('reschedule_task', {'id': late['id'], 'due': '2027-04-17', 'time': '09:30'}));
    expect(inbox.readAsStringSync(), '- [ ] Pack the proofs 🎯 11:00PM-1:00AM ⏳ 2027-04-13 ⏰ 9:30AM 📅 2027-04-17\n');
    expect(due['dueTime'], '09:30');
    final kept = payload(call('reschedule_task', {'id': due['id'], 'due': '2027-04-18'}));
    expect(kept['dueTime'], '09:30');
    final untimed = payload(call('reschedule_task', {'id': kept['id'], 'due': '2027-04-18', 'time': null}));
    final cleared = payload(call('schedule_task', {'id': untimed['id'], 'date': null}));
    expect(inbox.readAsStringSync(), '- [ ] Pack the proofs 📅 2027-04-18\n');
    expect((cleared['start'], cleared['end'], cleared['dueTime']), (null, null, null));

    // Bad clocks fail as tool errors and leave the note alone; wrong types are protocol errors.
    expect(call('schedule_task', {'id': cleared['id'], 'date': '2027-04-13', 'start': '9:00'})['result']['isError'], true);
    expect(call('schedule_task', {'id': cleared['id'], 'date': '2027-04-13', 'start': '24:00'})['result']['isError'], true);
    expect(call('reschedule_task', {'id': cleared['id'], 'due': null, 'time': '10:00'})['result']['isError'], true);
    expect(call('schedule_task', {'id': cleared['id'], 'date': '2027-04-13', 'start': 900})['error']['code'], -32602);
    expect(inbox.readAsStringSync(), '- [ ] Pack the proofs 📅 2027-04-18\n');
  });

  test('CLI commands and MCP line framing through the executable entry point', () async {
    Future<ProcessResult> cli(List<String> args) =>
        Process.run(Platform.resolvedExecutable, ['run', 'bin/facet.dart', root.path, ...args]);
    final created = await cli(['add', 'Ship maps', '2027-10-17']);
    expect(created.exitCode, 0, reason: created.stderr.toString());
    final id = jsonDecode(created.stdout)['id'] as String;
    expect((await cli(['complete', id, 'true'])).exitCode, 0);
    expect(jsonDecode((await cli(['list'])).stdout).single['completed'], true);
    expect((await cli(['due', id, 'none'])).exitCode, 1);
    final fresh = jsonDecode((await cli(['add', 'Pack the proofs'])).stdout)['id'] as String;
    final scheduled = await cli(['schedule', fresh, '2027-10-18', '09:00-10:30']);
    expect(scheduled.exitCode, 0, reason: scheduled.stderr.toString());
    expect(jsonDecode(scheduled.stdout), allOf(containsPair('start', '09:00'), containsPair('end', '10:30')));
    final dueAt = await cli(['due', jsonDecode(scheduled.stdout)['id'], '2027-10-19', '17:00']);
    expect(jsonDecode(dueAt.stdout)['dueTime'], '17:00');
    expect(File('${root.path}/Inbox.md').readAsStringSync(),
        endsWith('- [ ] Pack the proofs 🎯 9:00AM-10:30AM ⏳ 2027-10-18 ⏰ 5:00PM 📅 2027-10-19\n'));
    expect((await cli(['schedule', fresh, '2027-10-18', '9am'])).exitCode, 64);
    final process = await Process.start(Platform.resolvedExecutable, ['run', 'bin/facet.dart', root.path, 'mcp']);
    process.stdin.writeln('{"jsonrpc":"2.0","id":17,"method":"ping"}');
    await process.stdin.close();
    final output = await process.stdout.transform(utf8.decoder).join();
    expect(await process.exitCode, 0);
    expect(jsonDecode(output), {'jsonrpc': '2.0', 'id': 17, 'result': {}});
  });
  test('CLI previews written dates, then adds them', () async {
    Future<ProcessResult> cli(List<String> args) =>
        Process.run(Platform.resolvedExecutable, ['run', 'bin/facet.dart', root.path, ...args]);
    // The CLI reads today's date, so the line names a day three days ahead.
    final soon = DateTime.now().add(const Duration(days: 3));
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final iso = DateTime.utc(soon.year, soon.month, soon.day).toIso8601String().split('T').first;
    final line = '- [ ] **${days[soon.weekday - 1]} ${months[soon.month - 1]} ${soon.day}** · Study';
    final note = File('${root.path}/Plan.md')..writeAsStringSync('$line\n');

    final preview = await cli(['written-dates']);
    expect(preview.exitCode, 0, reason: preview.stderr.toString());
    expect(jsonDecode(preview.stdout), [
      allOf(containsPair('file', 'Plan.md'), containsPair('line', 1), containsPair('date', iso)),
    ]);
    expect(note.readAsStringSync(), '$line\n');

    final applied = await cli(['written-dates', 'apply']);
    expect(applied.exitCode, 0, reason: applied.stderr.toString());
    expect((jsonDecode(applied.stdout) as List).single['due'], iso);
    expect(note.readAsStringSync(), '$line 📅 $iso\n');
    expect(jsonDecode((await cli(['written-dates'])).stdout), isEmpty);
  });

  test('two CLI writers preserve both captures', () async {
    final results = await Future.wait(['First writer', 'Second writer'].map((title) =>
        Process.run(Platform.resolvedExecutable,
            ['run', 'bin/facet.dart', root.path, 'add', title])));
    for (final result in results) {
      expect(result.exitCode, 0, reason: result.stderr.toString());
    }
    expect(Vault(root).list().map((t) => t.task.title),
        unorderedEquals(['First writer', 'Second writer']));
  });

}
