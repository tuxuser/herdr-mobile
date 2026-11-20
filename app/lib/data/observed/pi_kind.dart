import 'observed_kind.dart';
import 'pi_locator.dart';
import 'pi_log_mapper.dart';
import 'pi_subagent_logs.dart';

/// pi: herdr's hook reports the path of its log once its integration is
/// installed (`herdr integration install pi`); without it the pane stays a
/// terminal. Its approvals and its question tool are answered in the terminal
/// (the prompt detector cards cover both), checked against the tool result in
/// the log. A spawned run is a roster entry and a background task; its
/// transcript is read from the run's own session file.
const piKind = ObservedKind(
  id: 'pi',
  label: 'pi',
  newMapper: PiLogMapper.new,
  newSubagentMapper: PiLogMapper.new,
  locator: PiLocator(),
  subagents: PiSubagentLogs(),
  integration: 'pi',
);
