import '../models/remote_file.dart';
import '../repositories/agent_session.dart' show SubagentState;
import '../repositories/machine_connection.dart';
import 'observed_contracts.dart';
import 'observed_kind.dart';
import 'session_log_locator.dart';

/// Where the transcripts of a pi subagent are and whether it still writes.
///
/// A run the parent spawns writes
/// `<parent log minus .jsonl>/<runId>/run-0/session.jsonl`, in the same
/// session log format as the parent. A file written lately is running.
class PiSubagentLogs implements SubagentLogs {
  const PiSubagentLogs();

  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  @override
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info) async {
    final id = info.logId;
    if (id == null || !_safeId.hasMatch(id)) return null;
    if (!parentLogPath.endsWith('.jsonl')) return null;
    final dir = parentLogPath.substring(0, parentLogPath.length - '.jsonl'.length);
    final path = '$dir/$id/run-0/session.jsonl';
    if (!isReadableLogPath(path)) return null;
    try {
      final stat = await machine.files.stat(path);
      return stat.kind == RemoteEntryKind.file ? path : null;
    } on RemoteFileException {
      return null;
    }
  }

  @override
  Future<Map<String, SubagentState>?> refine(
    MachineConnection machine,
    String parentLogPath,
    List<SubagentInfo> infos, {
    required Duration running,
  }) async {
    final out = <String, SubagentState>{};
    final now = DateTime.now().toUtc();
    for (final info in infos) {
      final path = await pathOf(machine, parentLogPath, info);
      if (path == null) continue;
      try {
        final stat = await machine.files.stat(path);
        final at = stat.modified;
        out[info.name] = at != null && now.difference(at.toUtc()) <= running
            ? SubagentState.running
            : SubagentState.finished;
      } on RemoteFileException {
        continue;
      }
    }
    return out;
  }
}
