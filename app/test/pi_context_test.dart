import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/pi_context.dart';
import 'package:herdr_mobile/data/observed/pi_kind.dart';
import 'package:herdr_mobile/data/observed/pi_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
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
