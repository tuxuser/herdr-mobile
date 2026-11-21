import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/pi_context.dart';
import 'package:herdr_mobile/data/observed/pi_kind.dart';
import 'package:herdr_mobile/data/observed/pi_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, EarlierHistory;
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

RemoteFiles _files(FakeFs fs) => RemoteFiles(FakeTransport()..fs = fs);

const _store = '{"opencode-go": {"models": [{"id": "a-model", "contextWindow": 1000000}, {"id": "broken"}]}}';

void main() {
  test('a catalog maps provider/model to its window', () async {
    final fs = FakeFs()
      ..addDir('/home/dev/.pi/agent')
      ..addFile('/home/dev/.pi/agent/models-store.json', _store);
    expect(await loadPiContextSizes(_files(fs)), {'opencode-go/a-model': 1000000});
  });

  test('a missing, malformed or empty catalog loads nothing', () async {
    expect(await loadPiContextSizes(_files(FakeFs())), isNull);
    for (final bad in ['not json', '{"a": 1}', '{"p": {"models": [{"id": "x"}]}}', '']) {
      final fs = FakeFs()
        ..addDir('/home/dev/.pi/agent')
        ..addFile('/home/dev/.pi/agent/models-store.json', bad);
      expect(await loadPiContextSizes(_files(fs)), isNull, reason: bad.isEmpty ? 'empty' : bad);
    }
  });

  group('a followed pi session', () {
    const log = '/home/dev/.pi/agent/sessions/--home-dev-work-app/2026-11-20T11-44-54-649Z_id.jsonl';
    const wideLog = '/home/dev/.pi/agent/sessions/--home-dev-work-app/2026-11-21T01-15-20-796Z_wide.jsonl';

    Future<ObservedAgentSession> openSession(FakeFs fs, List<String> lines) async {
      final rig = await ObservedRig.create(agent: 'pi', log: log);
      addTearDown(rig.dispose);
      rig.transport.fs = fs;
      rig.source.write(lines);
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: piKind,
        source: rig.source,
        mapper: PiLogMapper.new,
        previews: rig.previews,
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => session.link == AgentLink.live && session.state.items.isNotEmpty, reason: 'log followed');
      return session;
    }

    test('usage grows the window size from the host catalog', () async {
      final fs = FakeFs()
        ..addFile(log, '{}\n')
        ..addFile(
          '/home/dev/.pi/agent/models-store.json',
          '{"opencode-go": {"models": [{"id": "m", "contextWindow": 1000000}]}}',
        );
      final session = await openSession(fs, [
        '{"type":"model_change","id":"m1","provider":"opencode-go","modelId":"m"}',
        '{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stopReason":"stop","usage":{"input":400,"output":100}}}',
      ]);
      expect(session.state.model, 'm');
      expect(session.state.usage!.used, 500);
      expect(session.state.usage!.size, 1000000);
    });

    test('facts live at the head even when the follow starts at the tail', () async {
      const head =
          '{"type":"model_change","id":"m1","provider":"opencode-go","modelId":"m"}\n'
          '{"type":"thinking_level_change","id":"t1","thinkingLevel":"medium"}\n';
      const tail = '{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n';
      final fs = FakeFs()
        ..addFile(log, '$head$tail')
        ..addFile(
          '/home/dev/.pi/agent/models-store.json',
          '{"opencode-go": {"models": [{"id": "m", "contextWindow": 1000000}]}}',
        );
      final rig = await ObservedRig.create(agent: 'pi', log: log);
      addTearDown(rig.dispose);
      rig.transport.fs = fs;
      // The host's tail read sends only the end of the file.
      rig.source.write([tail]);
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: piKind,
        source: rig.source,
        mapper: PiLogMapper.new,
        previews: rig.previews,
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => session.link == AgentLink.live && session.state.items.isNotEmpty, reason: 'log followed');
      expect(session.state.model, 'm');
      expect(session.state.modelProvider, 'opencode-go');
      expect(session.state.thinking, 'medium');
    });

    test('model and sized usage survive loading earlier', () async {
      String line(String id, String role, String text, [Map<String, Object?>? extra]) => jsonEncode({
        'type': 'message',
        'id': id,
        'message': {
          'role': role,
          'content': [
            {'type': 'text', 'text': text},
          ],
          'stopReason': 'stop',
          ...?extra,
        },
      });
      String user(int i) => line('u$i', 'user', 'q $i');
      String answer(int i) => line('a$i', 'assistant', 'a $i ${'x' * 10000}');
      final lines = [
        '{"type":"model_change","id":"m1","provider":"opencode-go","modelId":"m"}',
        '{"type":"thinking_level_change","id":"t1","thinkingLevel":"medium"}',
        for (var i = 0; i < 25; i++) ...[user(i), answer(i)],
        // The newest turn carries usage; the table sizes it from the first open on.
        line('ux', 'user', 'hi'),
        line('ax', 'assistant', 'done', {
          'usage': {'input': 400, 'output': 100},
        }),
      ];
      final fs = FakeFs()
        ..addFile(wideLog, '${lines.join('\n')}\n')
        ..addFile(
          '/home/dev/.pi/agent/models-store.json',
          '{"opencode-go": {"models": [{"id": "m", "contextWindow": 1000000}]}}',
        );
      final rig = await ObservedRig.create(agent: 'pi', log: wideLog);
      addTearDown(rig.dispose);
      rig.transport.fs = fs;
      rig.source.write(lines);
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: piKind,
        source: rig.source,
        mapper: PiLogMapper.new,
        previews: rig.previews,
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => session.link == AgentLink.live && session.state.items.isNotEmpty, reason: 'log followed');
      expect(session.state.model, 'm', reason: 'head facts land on open');
      await eventually(() => session.state.usage != null, reason: 'tail followed');
      expect(session.state.usage!.used, 500);
      expect(session.state.usage!.size, 1000000);
      session.loadEarlier();
      await eventually(() => session.earlier == EarlierHistory.none, reason: 'start of the log reached');
      expect(session.state.model, 'm', reason: 'a wider read keeps the head facts');
      expect(session.state.usage!.size, 1000000, reason: 'and the window size with them');
    });

    test('usage without a catalog stays unsized', () async {
      final fs = FakeFs()..addFile(log, '{}\n');
      final session = await openSession(fs, [
        '{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stopReason":"stop","usage":{"input":400,"output":100}}}',
      ]);
      expect(session.state.usage!.used, 500);
      expect(session.state.usage!.size, 0);
    });
  });
}
