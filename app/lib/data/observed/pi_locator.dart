import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
import '../services/remote_files.dart';
import 'session_log_locator.dart';

/// Finds the log of a pi pane.
///
/// pi tells herdr the path of its log (`kind: path`) once its integration is
/// installed (`herdr integration install pi`). Without a report the pane
/// cannot be linked: pi keeps no map from a process to its session.
class PiLocator implements SessionLogLocator {
  const PiLocator();

  /// Shown verbatim.
  static const unlinkedWhy =
      'herdr does not know which session this pi runs. Install herdr\'s hook (the terminal\'s ... menu has '
      '"Read as chat...", or run "herdr integration install pi" on the machine), then resume the session.';

  static const notYetWhy = 'pi has not written this session yet.';

  @override
  bool mayLocate(Pane pane) => FleetAgent.logPathOf(pane) != null;

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) => locateWith(machine.files, pane);

  /// The log of [pane] from what herdr reported: the path is named at session
  /// start, but pi writes the file with the first message.
  Future<LogLocation> locateWith(RemoteFiles files, Pane pane) async {
    final path = FleetAgent.logPathOf(pane);
    if (path == null || !isReadableLogPath(path)) return const Unlinked(unlinkedWhy);
    try {
      final stat = await files.stat(path);
      if (stat.kind == RemoteEntryKind.file) return Located(path);
    } on RemoteFileException catch (e) {
      if (_absent(e)) return const NotYet(notYetWhy);
      rethrow;
    }
    return const NotYet(notYetWhy);
  }

  /// A file or folder that is not there (or not for this user to read) is an
  /// answer; a dropped link is not.
  static bool _absent(RemoteFileException e) => switch (e.kind) {
    RemoteFileErrorKind.notFound ||
    RemoteFileErrorKind.permission ||
    RemoteFileErrorKind.notAFile ||
    RemoteFileErrorKind.notADirectory => true,
    _ => false,
  };
}
