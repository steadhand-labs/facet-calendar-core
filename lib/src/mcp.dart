import 'dart:convert';

import 'vault.dart';

typedef Json = Map<String, dynamic>;

const _string = {'type': 'string'};
const _tools = [
  {
    'name': 'list_tasks',
    'description': 'Read Markdown tasks and their current revision-bound IDs.',
    'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': false},
  },
  {
    'name': 'capture_task',
    'description': 'Append a checkbox to Inbox.md.',
    'inputSchema': {
      'type': 'object', 'properties': {'title': _string, 'due': _string},
      'required': ['title'], 'additionalProperties': false,
    },
  },
  {
    'name': 'reschedule_task',
    'description': 'Set a YYYY-MM-DD due date. Pass null to clear it.',
    'inputSchema': {
      'type': 'object', 'properties': {'id': _string, 'due': {'type': ['string', 'null']}},
      'required': ['id', 'due'], 'additionalProperties': false,
    },
  },
  {
    'name': 'set_completion',
    'description': 'Complete or reopen a task.',
    'inputSchema': {
      'type': 'object', 'properties': {'id': _string, 'completed': {'type': 'boolean'}},
      'required': ['id', 'completed'], 'additionalProperties': false,
    },
  },
];

class FacetServer {
  FacetServer(this.vault);
  final Vault vault;
  bool _negotiated = false;
  bool _ready = false;

  Json? handle(String line) {
    Object? request;
    try {
      request = jsonDecode(line);
    } on FormatException {
      return _error(null, -32700, 'Invalid JSON.');
    }
    if (request is! Json || request['jsonrpc'] != '2.0' || request['method'] is! String) {
      return _error(null, -32600, 'Invalid request.');
    }
    final id = request['id'];
    final method = request['method'];
    if (!request.containsKey('id')) {
      if (method == 'notifications/initialized' && _negotiated) _ready = true;
      return null;
    }
    if (id is! String && id is! int) return _error(null, -32600, 'Invalid request ID.');
    final params = request['params'] ?? <String, dynamic>{};
    if (params is! Json) return _error(id, -32602, 'Expected an object for params.');
    Object result;
    switch (method) {
      case 'initialize':
        if (params['protocolVersion'] is! String || params['clientInfo'] is! Map ||
            params['capabilities'] is! Map) {
          return _error(id, -32602, 'Missing initialization parameters.');
        }
        _negotiated = true;
        _ready = false;
        result = {
          'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}},
          'serverInfo': {'name': 'facet-calendar', 'version': '0.1.0'},
        };
      case 'ping':
        result = {};
      default:
        if (!_ready) return _error(id, -32002, 'Initialize the session first.');
        if (method == 'tools/list') {
          result = {'tools': _tools};
        } else if (method == 'tools/call') {
          final name = params['name'];
          final args = params['arguments'] ?? <String, dynamic>{};
          if (args is! Json || !_tools.any((s) => s['name'] == name)) {
            return _error(id, -32602, 'Unknown tool or invalid arguments.');
          }
          try {
            final value = _call(name as String, args);
            result = {'content': [{'type': 'text', 'text': jsonEncode(value)}]};
          } on ArgumentError catch (e) {
            return _error(id, -32602, e.message.toString());
          } on Exception catch (e) {
            result = {'isError': true, 'content': [{'type': 'text', 'text': e.toString()}]};
          }
        } else {
          return _error(id, -32601, 'Unknown method.');
        }
    }
    return {'jsonrpc': '2.0', 'id': id, 'result': result};
  }

  Object _call(String name, Json args) {
    final schema = _tools.firstWhere((tool) => tool['name'] == name)['inputSchema'] as Map;
    final properties = schema['properties'] as Map;
    final requiredKeys = schema['required'] as List? ?? [];
    if (args.keys.any((k) => !properties.containsKey(k)) ||
        requiredKeys.any((k) => !args.containsKey(k))) {
      throw ArgumentError('Check the required arguments and property names.');
    }
    switch (name) {
      case 'list_tasks':
        return vault.list().map((t) => t.toJson()).toList();
      case 'capture_task':
        if (args['title'] is String && (!args.containsKey('due') || args['due'] is String)) {
          return vault.capture(args['title'], due: args['due']).toJson();
        }
      case 'reschedule_task':
        if (args['id'] is String && (args['due'] == null || args['due'] is String)) {
          return vault.reschedule(args['id'], args['due']).toJson();
        }
      case 'set_completion':
        if (args['id'] is String && args['completed'] is bool) {
          return vault.setCompleted(args['id'], args['completed']).toJson();
        }
    }
    throw ArgumentError('One or more tool arguments has an invalid type.');
  }

  Json _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message},
  };
}
