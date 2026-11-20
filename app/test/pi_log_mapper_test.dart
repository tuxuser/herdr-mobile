import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/pi_log_mapper.dart';

String _entry(Json e) => jsonEncode(e);

String _user(String id, String text) => _entry({
  'type': 'message',
  'id': id,
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _assistant(String id, List<Json> content, {String stop = 'stop'}) => _entry({
  'type': 'message',
  'id': id,
  'message': {'role': 'assistant', 'content': content, 'stopReason': stop},
});

String _result(String id, String callId, String name, String text, {Json? details, bool error = false}) => _entry({
  'type': 'message',
  'id': id,
  'message': {
    'role': 'toolResult',
    'toolCallId': callId,
    'toolName': name,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'details': details ?? {},
    'isError': error,
  },
});

Json _call(String id, String name, Json args) => {'type': 'toolCall', 'id': id, 'name': name, 'arguments': args};

AgentSessionState _feed(PiLogMapper mapper, Iterable<String> lines, [AgentSessionState? from]) {
  var s = from ?? const AgentSessionState('s');
  for (final line in lines) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

List<TranscriptMessage> _messages(AgentSessionState s, [MessageRole? role]) => [
  for (final i in s.items)
    if (i is TranscriptMessage && (role == null || i.role == role)) i,
];

List<String> _texts(AgentSessionState s, MessageRole role) => [for (final m in _messages(s, role)) m.text];

String _toolText(ToolCall c) => [
  for (final x in c.content)
    if (x is ToolContentBlock && x.block is TextBlock) (x.block as TextBlock).text,
].join('\n');

void main() {
  group('pi transcript', () {
    test('user, thought, tool row with command and output, answer', () {
      final m = PiLogMapper();
      final s = _feed(m, [
        _entry({'type': 'session', 'id': 'sess', 'cwd': '/work/proj'}),
        _user('u1', 'list files'),
        _assistant('a1', [
          {'type': 'thinking', 'thinking': 'checking the dir'},
          _call('c1', 'bash', {'command': 'ls -la'}),
          {'type': 'text', 'text': 'running it'},
        ], stop: 'toolUse'),
        _result('r1', 'c1', 'bash', 'total 0\n'),
        _assistant('a2', [
          {'type': 'text', 'text': 'done'},
        ]),
      ]);

      expect(_texts(s, MessageRole.user), ['list files']);
      expect(_texts(s, MessageRole.thought), ['checking the dir']);
      expect(_texts(s, MessageRole.agent), ['running it', 'done']);

      final call = s.toolCall('c1')!;
      expect(call.name, 'bash');
      expect(call.kind, ToolKind.execute);
      expect(call.status, ToolStatus.completed);
      expect(call.title, contains('ls -la'));
      expect(_toolText(call), contains('total 0'));
      expect(m.openToolCalls, isEmpty);
      expect(m.turnEnded, isTrue);
    });

    test('a result for a call whose start was missed still names the call', () {
      final m = PiLogMapper();
      final s = _feed(m, [_result('r1', 'c9', 'read', 'file body')]);
      final c = s.toolCall('c9')!;
      expect((c.name, c.kind, c.status), ('read', ToolKind.read, ToolStatus.completed));
      expect(_toolText(c), 'file body');
    });

    test('the question tool stays pending until its result', () {
      final m = PiLogMapper();
      var s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'ask_user_question', {
            'questions': [
              {
                'header': 'short',
                'question': 'Keep it?',
                'options': [
                  {'label': 'Yes', 'description': 'keep'},
                  {'label': 'No', 'description': 'drop'},
                ],
              },
            ],
          }),
        ], stop: 'toolUse'),
      ]);
      expect(m.pendingAsk, isNotNull);
      expect(m.pendingAsk!.toolCallId, 'c1');
      expect(m.pendingAsk!.questions.single.question, 'Keep it?');
      expect(m.pendingAsk!.questions.single.options.map((o) => o.label), ['Yes', 'No']);
      expect(m.openToolCalls, {'c1'});

      s = _feed(m, [_result('r1', 'c1', 'ask_user_question', 'answered: Yes')], s);
      expect(m.pendingAsk, isNull);
      expect(s.toolCall('c1')!.status, ToolStatus.completed);
    });

    test('a later user message clears the open question and cancels its row', () {
      final m = PiLogMapper();
      var s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'ask_user_question', {
            'questions': [
              {
                'question': 'Sure?',
                'options': [
                  {'label': 'Yes'},
                ],
              },
            ],
          }),
        ], stop: 'toolUse'),
      ]);
      expect(m.pendingAsk, isNotNull);
      s = _feed(m, [_user('u9', 'answered in the terminal')], s);
      expect(m.pendingAsk, isNull);
      expect(s.toolCall('c1')!.status, ToolStatus.cancelled);
    });

    test('todo results become the plan; deleted maps to cancelled', () {
      final m = PiLogMapper();
      final s = _feed(m, [
        _result(
          'r1',
          'c1',
          'todo',
          'ok',
          details: {
            'tasks': [
              {'id': 1, 'subject': 'write code', 'status': 'completed'},
              {'id': 2, 'subject': 'run tests', 'status': 'in_progress'},
              {'id': 3, 'subject': 'old idea', 'status': 'deleted'},
            ],
          },
        ),
      ]);
      expect(s.plan.map((p) => (p.content, p.status)), [
        ('write code', PlanStatus.completed),
        ('run tests', PlanStatus.inProgress),
        ('old idea', PlanStatus.cancelled),
      ]);
    });

    test('compaction is a quiet note; a failed turn says so and cancels open calls', () {
      final m = PiLogMapper();
      final s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'bash', {'command': 'false'}),
        ], stop: 'toolUse'),
        _assistant('a2', [], stop: 'error'),
      ]);
      expect(_texts(s, MessageRole.agent).last, startsWith('The turn failed'));
      expect(s.toolCall('c1')!.status, ToolStatus.cancelled);
      expect(m.openToolCalls, isEmpty);
    });

    test('unknown and malformed lines give nothing and never throw', () {
      final m = PiLogMapper();
      for (final line in [
        '',
        'not json',
        '[1,2]',
        '{}',
        '{"type":"message"}',
        '{"type":"message","message":{"role":"assistant","content":7}}',
        '{"type":"future","id":"zz"}',
      ]) {
        expect(() => m.map(line), returnsNormally, reason: line.isEmpty ? 'empty' : line);
      }
      expect(m.openToolCalls, isEmpty);
      expect(m.pendingAsk, isNull);
    });

    test('a captured pi log maps: user, thought, tool row, answer', () {
      final lines = File('test/fixtures/pi_logs/basic.jsonl').readAsLinesSync().where((l) => l.isNotEmpty).toList();
      final m = PiLogMapper();
      final s = _feed(m, lines);
      expect(_texts(s, MessageRole.user), ['list files']);
      expect(_texts(s, MessageRole.thought), ['checking the dir']);
      expect(_texts(s, MessageRole.agent), ['done']);
      final call = s.toolCall('c1')!;
      expect((call.name, call.kind, call.status), ('bash', ToolKind.execute, ToolStatus.completed));
      expect(_toolText(call), contains('total 0'));
      expect(m.openToolCalls, isEmpty);
      expect(m.turnEnded, isTrue);
    });

    group('subagents and background work', () {
      const run = '7ecf2c60-7cd3-4081-9699-4d56f94c9e89';

      List<String> spawnLines(String callId) => [
        _assistant('a1', [
          _call(callId, 'subagent', {'agent': 'worker', 'task': 'Write the parser.'}),
        ], stop: 'toolUse'),
        _result(
          'r1',
          callId,
          'subagent',
          'Async: worker [$run]',
          details: {'mode': 'single', 'runId': run, 'asyncId': run},
        ),
      ];

      test('a spawn is a running roster entry and a running background task', () {
        final m = PiLogMapper();
        final s = _feed(m, spawnLines('c1'));
        final info = m.subagents.single;
        expect(info.agent, 'worker');
        expect(info.status, 'running');
        expect(info.assignment, 'Write the parser.');
        expect(info.logId, run);
        expect(info.callId, 'c1');
        final task = m.backgroundTasks.single;
        expect((task.id, task.kind, task.status), (run, BackgroundKind.agent, BackgroundStatus.running));
        expect(task.toolCallId, 'c1');
        expect(m.openToolCalls, isEmpty);
        expect(m.turnEnded, isFalse);
        expect(s.toolCall('c1')!.status, ToolStatus.completed);
      });

      test('a bg_wait completion finishes the task and the roster entry', () {
        final m = PiLogMapper();
        _feed(m, spawnLines('c1'));
        final s = _feed(m, [
          _assistant('a2', [
            _call('c2', 'bg_wait', {'id': run}),
          ], stop: 'toolUse'),
          _result(
            'r2',
            'c2',
            'bg_wait',
            'Waited 2m12s for run "$run"; done.',
            details: {
              'completions': [
                {'runId': run, 'agent': 'worker', 'state': 'complete', 'success': true},
              ],
            },
          ),
        ]);
        expect(m.backgroundTasks.single.status, BackgroundStatus.finished);
        expect(m.subagents.single.status, 'completed');
        expect(s.toolCall('c2')!.status, ToolStatus.completed);
      });

      test('a failed completion fails the task and the roster entry', () {
        final m = PiLogMapper();
        _feed(m, spawnLines('c1'));
        _feed(m, [
          _result(
            'r2',
            'c2',
            'bg_wait',
            'Waited 10s; failed.',
            details: {
              'completions': [
                {'runId': run, 'agent': 'worker', 'state': 'failed', 'success': false},
              ],
            },
          ),
        ]);
        expect(m.backgroundTasks.single.status, BackgroundStatus.failed);
        expect(m.subagents.single.status, 'failed');
      });

      test('a status result of complete finishes it; running leaves it alone', () {
        final m = PiLogMapper();
        _feed(m, spawnLines('c1'));
        String statusCall(String id) => _assistant(id, [
          _call(id, 'subagent', {'action': 'status', 'id': run}),
        ], stop: 'toolUse');
        _feed(m, [
          statusCall('c3'),
          _result('r2', 'c3', 'subagent', 'State: running', details: {'mode': 'single'}),
        ]);
        expect(m.backgroundTasks.single.status, BackgroundStatus.running);
        _feed(m, [
          statusCall('c4'),
          _result('r3', 'c4', 'subagent', 'State: complete', details: {'mode': 'single'}),
        ]);
        expect(m.backgroundTasks.single.status, BackgroundStatus.finished);
        expect(m.subagents.single.status, 'completed');
      });

      test('a failed spawn keeps no roster entry and no task', () {
        final m = PiLogMapper();
        final s = _feed(m, [
          _assistant('a1', [
            _call('c1', 'subagent', {'agent': 'worker', 'task': 'Write the parser.'}),
          ], stop: 'toolUse'),
          _result('r1', 'c1', 'subagent', 'no such agent', error: true),
        ]);
        expect(m.subagents, isEmpty);
        expect(m.backgroundTasks, isEmpty);
        expect(s.toolCall('c1')!.status, ToolStatus.failed);
      });

      test('a completion notice is an agent note and starts a turn', () {
        final m = PiLogMapper();
        final s = _feed(m, [
          _entry({
            'type': 'custom_message',
            'id': 'n1',
            'customType': 'subagent-notify',
            'content': 'Background task completed: **worker**\n\nworker:\nDid the thing.',
          }),
        ]);
        expect(_texts(s, MessageRole.agent).single, contains('Background task completed'));
        expect(m.turnEnded, isFalse);
      });

      test('a notice of a run that needs attention is an agent note', () {
        final m = PiLogMapper();
        final s = _feed(m, [
          _entry({
            'type': 'custom_message',
            'id': 'n1',
            'customType': 'subagent_control_notice',
            'content': 'Subagent needs attention: delegate\nRun: $run step 1',
          }),
        ]);
        expect(_texts(s, MessageRole.agent).single, contains('needs attention'));
      });

      test('a supervisor request is an agent note', () {
        final m = PiLogMapper();
        final s = _feed(m, [
          _entry({
            'type': 'custom_message',
            'id': 'n1',
            'customType': 'subagent_supervisor_request',
            'content': 'Subagent needs a supervisor decision.\nRun: $run',
          }),
        ]);
        expect(_texts(s, MessageRole.agent).single, contains('needs a supervisor decision'));
      });

      test('replayed spawn and completion lines change nothing, reset forgets all', () {
        final m = PiLogMapper();
        final lines = [
          ...spawnLines('c1'),
          _result(
            'r2',
            'c2',
            'bg_wait',
            'done',
            details: {
              'completions': [
                {'runId': run, 'state': 'complete', 'success': true},
              ],
            },
          ),
        ];
        _feed(m, lines);
        final once = (m.subagents.single.status, m.backgroundTasks.single.status);
        _feed(m, lines);
        expect((m.subagents.single.status, m.backgroundTasks.single.status), once);
        m.reset();
        expect(m.subagents, isEmpty);
        expect(m.backgroundTasks, isEmpty);
      });
    });

    test('the whole log fed twice changes nothing', () {
      final lines = [
        _user('u1', 'hi'),
        _assistant('a1', [
          {'type': 'text', 'text': 'hello'},
        ]),
      ];
      final m = PiLogMapper();
      final once = _feed(m, lines);
      final twice = _feed(m, lines, once);
      expect(twice.items.length, once.items.length);
      expect(_texts(twice, MessageRole.agent), ['hello']);
    });
  });
}
