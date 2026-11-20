import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/observed/pi_subagent_logs.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show SubagentState;

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';

const _parentLog =
    '/home/u/.pi/agent/sessions/--home-u-work-app/2026-11-20T11-44-54-649Z_01a1f8c6-1976-721f-af3d-d7d3fe856a29.jsonl';
const _dir =
    '/home/u/.pi/agent/sessions/--home-u-work-app/2026-11-20T11-44-54-649Z_01a1f8c6-1976-721f-af3d-d7d3fe856a29';
const _run = '7ecf2c60-7cd3-4081-9699-4d56f94c9e89';
const _child = '$_dir/$_run/run-0/session.jsonl';

Future<ObservedRig> _rig(FakeFs fs) async {
  final rig = await ObservedRig.create(agent: 'pi', log: _parentLog);
  addTearDown(rig.dispose);
  rig.transport.fs = fs;
  return rig;
}

void main() {
  final logs = PiSubagentLogs();

  test('the transcript is under the parent file, by run id', () async {
    final fs = FakeFs()..addFile(_child, '{}\n');
    final rig = await _rig(fs);

    expect(await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: '7ecf2c60', logId: _run)), _child);
  });

  test('a file that does not exist yet is not followed', () async {
    final fs = FakeFs()..addDir(_dir);
    final rig = await _rig(fs);
    expect(await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: 'x', logId: _run)), isNull);
  });

  test('a run id from a log never becomes a path outside the folder', () async {
    final fs = FakeFs();
    final rig = await _rig(fs);

    for (final bad in ['../../../../etc/passwd', 'a/b', 'a b', 'x' * 65, '']) {
      expect(
        await logs.pathOf(rig.machine, _parentLog, SubagentInfo(name: 'x', logId: bad)),
        isNull,
        reason: bad,
      );
    }
    expect(fs.calls, isEmpty);
  });

  test('running while its file was written lately, finished otherwise', () async {
    final fs = FakeFs()
      ..addFile(_child, '{}\n', modified: DateTime.now().toUtc())
      ..addFile(
        '$_dir/aaaaaaaa-0000-4000-8000-000000000001/run-0/session.jsonl',
        '{}\n',
        modified: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      );
    final rig = await _rig(fs);

    final states = await logs.refine(rig.machine, _parentLog, const [
      SubagentInfo(name: 'fresh', logId: _run),
      SubagentInfo(name: 'old', logId: 'aaaaaaaa-0000-4000-8000-000000000001'),
    ], running: const Duration(seconds: 32));

    expect(states, {'fresh': SubagentState.running, 'old': SubagentState.finished});
  });
}
