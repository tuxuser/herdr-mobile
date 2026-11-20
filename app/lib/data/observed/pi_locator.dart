import '../models/herdr_models.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
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

  @override
  bool mayLocate(Pane pane) => FleetAgent.logPathOf(pane) != null;

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) async => locatePane(pane);

  /// The log of [pane] from what herdr reported, without touching the host.
  LogLocation locatePane(Pane pane) {
    final path = FleetAgent.logPathOf(pane);
    if (path == null || !isReadableLogPath(path)) return const Unlinked(unlinkedWhy);
    return Located(path);
  }
}
