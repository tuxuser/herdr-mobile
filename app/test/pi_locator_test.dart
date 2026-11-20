import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/observed/pi_locator.dart';
import 'package:herdr_mobile/data/observed/session_log_locator.dart';

Pane _pane({String agent = 'pi', AgentSessionRef? session, String cwd = '/work/app'}) => Pane(
  id: 'w1:p1',
  workspaceId: 'w1',
  tabId: 'w1:t1',
  focused: false,
  cwd: cwd,
  title: '',
  agent: agent,
  status: AgentStatus.idle,
  session: session,
);

AgentSessionRef _ref(String agent, String kind, String value) =>
    AgentSessionRef(agent: agent, kind: kind, value: value);

void main() {
  group('Pi', () {
    const locator = PiLocator();
    const path =
        '/home/dev/.pi/agent/sessions/--home-dev-work-app/2026-11-20T11-44-54-649Z_01a1f8c6-1976-721f-af3d-d7d3fe856a29.jsonl';

    test('a path from herdr is the log', () {
      expect((locator.locatePane(_pane(session: _ref('pi', 'path', path))) as Located).path, path);
    });

    test('a path with .. or a control character is refused, not followed', () {
      for (final bad in ['/home/dev/../etc/x.jsonl', '/home/dev/a\nb.jsonl', 'relative.jsonl']) {
        expect(locator.locatePane(_pane(session: _ref('pi', 'path', bad))), isA<Unlinked>(), reason: bad);
      }
    });

    test('no reported path cannot be linked', () {
      expect(locator.locatePane(_pane()), isA<Unlinked>());
    });

    test('the board offers the chat for a pi pane that names its log', () {
      expect(locator.mayLocate(_pane(session: _ref('pi', 'path', path))), isTrue);
      expect(locator.mayLocate(_pane()), isFalse);
    });
  });
}
