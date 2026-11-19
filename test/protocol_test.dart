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
    expect(request('tools/list')['result']['tools'], hasLength(4));
    final created = payload(call('capture_task', {'title': 'Proof'}));
    final dated = payload(call('reschedule_task', {'id': created['id'], 'due': '2027-04-02'}));
    final done = payload(call('set_completion', {'id': dated['id'], 'completed': true}));
    expect(done['completed'], true);
    expect(payload(call('list_tasks', {})).single['id'], done['id']);
    expect(call('reschedule_task', {'id': created['id'], 'due': null})['result']['isError'], true);
    expect(call('set_completion', {'id': done['id'], 'completed': 'yes'})['error']['code'], -32602);
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
    final process = await Process.start(Platform.resolvedExecutable, ['run', 'bin/facet.dart', root.path, 'mcp']);
    process.stdin.writeln('{"jsonrpc":"2.0","id":17,"method":"ping"}');
    await process.stdin.close();
    final output = await process.stdout.transform(utf8.decoder).join();
    expect(await process.exitCode, 0);
    expect(jsonDecode(output), {'jsonrpc': '2.0', 'id': 17, 'result': {}});
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
