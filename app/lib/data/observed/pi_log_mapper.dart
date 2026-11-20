import 'dart:convert';

import '../acp/acp_models.dart';
import '../acp/background/background_work.dart';
import 'log_mapping.dart';
import 'observed_contracts.dart';

/// Maps the lines of a pi session log
/// (`~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<id>.jsonl`) to the updates
/// `AgentSessionState.apply` understands, so that a pi turn reads on the phone
/// the way the same turn of an ACP session does.
///
/// Entry kinds read (everything else, and anything malformed, maps to
/// nothing):
/// - `session` (the cwd, used to resolve relative paths);
/// - `message` with role `user`, `assistant` (text, thinking, `toolCall`
///   blocks, `stopReason: error`) and `toolResult` (`subagent` spawns and
///   `bg_wait` completions update the roster and the background tasks);
/// - `compaction` (one quiet note) and the `custom_message` notices of
///   finished subagents and runs that need attention (notes).
///
/// Idempotent: messages are whole-message upserts keyed by the entry id, tool
/// calls are keyed by their call id and patches replace, and an entry id this
/// mapper has already mapped yields nothing. The memory of seen ids lives in
/// the mapper: reset it together with the state it feeds.
class PiLogMapper implements SessionLogMapper {
  static const _titleChars = 120;
  static const _assignmentChars = 400;

  final _seen = <String>{};
  final _started = <String>{};
  final _open = <String, _OpenCall>{};

  PendingAsk? _ask;
  String? _cwd;
  var _turnEnded = false;

  final _subagents = <String, SubagentInfo>{};
  final _tasks = <String, BackgroundTask>{};
  List<BackgroundTask>? _taskView;

  @override
  PendingAsk? get pendingAsk => _ask;

  @override
  ProposedPlan? get proposedPlan => null;

  @override
  Set<String> get openToolCalls => Set.unmodifiable(_open.keys);

  @override
  List<SubagentInfo> get subagents => List.unmodifiable(_subagents.values);

  @override
  List<BackgroundTask> get backgroundTasks => _taskView ??= List.unmodifiable(_tasks.values);

  @override
  bool get turnEnded => _turnEnded;

  @override
  void reset() {
    _seen.clear();
    _started.clear();
    _open.clear();
    _subagents.clear();
    _tasks.clear();
    _taskView = null;
    _ask = null;
    _cwd = null;
    _turnEnded = false;
  }

  @override
  List<SessionUpdate> map(String line) {
    if (line.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    try {
      return _entry(decoded, line);
    } on Object {
      return const [];
    }
  }

  List<SessionUpdate> _entry(Json e, String line) {
    switch (e['type']) {
      case 'session':
        final cwd = e['cwd'];
        if (cwd is String && cwd.isNotEmpty) _cwd = cwd;
        return const [];
      case 'message':
        final m = e['message'];
        if (m is! Map<String, dynamic>) return const [];
        return _message(e, m, line);
      case 'compaction':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        return [messageUpsert(MessageRole.agent, key, 'Earlier messages were summarised')];
      case 'custom_message':
        return _notice(e, line);
      default:
        return const [];
    }
  }

  List<SessionUpdate> _message(Json e, Json m, String line) {
    switch (m['role']) {
      case 'user':
        final text = _userText(m['content']);
        if (text.trim().isEmpty) return const [];
        final key = _firstTime(e, line);
        if (key == null) return const [];
        _turnEnded = false;
        return [..._userClears(), messageUpsert(MessageRole.user, key, text)];
      case 'assistant':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        final out = _assistant(key, m);
        _turnEnded = _endsTurn(m['stopReason']) && _open.isEmpty;
        return out;
      case 'toolResult':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        _turnEnded = false;
        return _toolResult(m);
      default:
        return const [];
    }
  }

  List<SessionUpdate> _userClears() {
    final ask = _ask;
    if (ask == null) return const [];
    _ask = null;
    if (_open.remove(ask.toolCallId) == null) return const [];
    return [cancelledPatch(ask.toolCallId)];
  }

  List<SessionUpdate> _assistant(String key, Json m) {
    final out = <SessionUpdate>[];
    final content = m['content'];
    if (content is String) {
      if (content.trim().isNotEmpty) out.add(messageUpsert(MessageRole.agent, '$key:0', content));
    } else if (content is List) {
      for (var i = 0; i < content.length; i++) {
        final b = content[i];
        if (b is! Map<String, dynamic>) continue;
        switch (b['type']) {
          case 'text':
            final t = b['text'];
            if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.agent, '$key:$i', t));
          case 'thinking':
            final t = b['thinking'];
            if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.thought, '$key:$i', t));
          case 'toolCall':
            final start = _toolStart(b);
            if (start != null) out.add(start);
        }
      }
    }
    if (m['stopReason'] == 'error') {
      final err = m['errorMessage'];
      out.add(
        messageUpsert(
          MessageRole.agent,
          '$key:error',
          err is String && err.trim().isNotEmpty ? 'The turn failed: ${capText(err.trim())}' : 'The turn failed.',
        ),
      );
    }
    final stop = m['stopReason'];
    if (stop == 'error' || stop == 'aborted') out.addAll(_cancelOpen());
    return out;
  }

  /// A notice of a subagent that finished or needs attention: a visible note.
  /// Anything else the pi-subagents extension writes stays hidden.
  List<SessionUpdate> _notice(Json e, String line) {
    switch (e['customType']) {
      case 'subagent-notify' ||
          'subagent_control_notice' ||
          'subagent_supervisor_request' ||
          'subagent_supervisor_reply':
        break;
      default:
        return const [];
    }
    final text = _resultText(e['content']);
    if (text.trim().isEmpty) return const [];
    final key = _firstTime(e, line);
    if (key == null) return const [];
    _turnEnded = false;
    return [messageUpsert(MessageRole.agent, key, text)];
  }

  SessionUpdate? _toolStart(Json b) {
    final id = b['id'];
    if (id is! String || id.isEmpty) return null;
    final rawName = b['name'];
    final name = rawName is String && rawName.isNotEmpty ? rawName : 'tool';
    final args = _arguments(b['arguments']);
    _started.add(id);
    _open[id] = _OpenCall(name, args);
    if (name == 'ask_user_question') _ask = _parseAsk(id, args);
    return ToolCallStart(
      ToolCall(
        toolCallId: id,
        name: name,
        title: cutText(_toolTitle(name, args), _titleChars),
        kind: _kindOf(name),
        status: ToolStatus.inProgress,
        rawInput: args == null ? null : capJson(args),
        locations: _locationsOfCall(args),
      ),
    );
  }

  List<SessionUpdate> _toolResult(Json m) {
    final id = m['toolCallId'];
    if (id is! String || id.isEmpty) return const [];
    final open = _open.remove(id);
    final known = _started.contains(id);
    _started.add(id);
    final rawName = m['toolName'];
    final name = open?.name ?? (rawName is String && rawName.isNotEmpty ? rawName : 'tool');
    final isError = m['isError'] == true;
    final text = _resultText(m['content']);
    final fields = <String, Object?>{
      'toolCallId': id,
      if (!known) ...{'name': name, 'title': name, 'kind': kindWire(_kindOf(name))},
      'status': isError ? 'failed' : 'completed',
      'content': [ToolContentBlock(TextBlock(capText(text))).toJson()],
      if (text.isNotEmpty) 'rawOutput': capText(text),
    };
    if (_ask?.toolCallId == id) _ask = null;
    final out = <SessionUpdate>[ToolCallPatchUpdate(ToolCallPatch(id, fields))];
    if (!isError) {
      if (name == 'todo') {
        final plan = _plan((m['details'] as Map<String, dynamic>?)?['tasks']);
        if (plan != null) out.add(plan);
      } else if (name == 'subagent') {
        _noteSubagent(id, m, open);
      } else if (name == 'bg_wait') {
        final completions = (m['details'] as Map<String, dynamic>?)?['completions'];
        if (completions is List) {
          for (final c in completions) {
            if (c is! Map<String, dynamic>) continue;
            final target = c['runId'];
            if (target is! String || target.isEmpty) continue;
            _settle(target, c['success'] == false || c['state'] == 'failed', parseStamp(m));
          }
        }
      }
    }
    return out;
  }

  /// A `subagent` result: a spawn names its run, a status result settles it.
  /// A failed spawn names nothing and leaves no roster entry.
  void _noteSubagent(String callId, Json m, _OpenCall? open) {
    final target = open?.statusTarget;
    if (target != null) {
      final text = _resultText(m['content']);
      if (text.contains('State: complete')) {
        _settle(target, false, parseStamp(m));
      } else if (text.contains('State: failed')) {
        _settle(target, true, parseStamp(m));
      }
      return;
    }
    final details = m['details'];
    final runId = details is Map<String, dynamic> ? details['runId'] : null;
    final asyncId = details is Map<String, dynamic> ? details['asyncId'] : null;
    if (runId is! String || runId.isEmpty || asyncId is! String || asyncId.isEmpty) return;
    // A reprocessed spawn must not resurrect a settled run.
    if (_tasks[_key(runId)] case final done? when !done.isActive) return;
    final agentArg = open?.args?['agent'];
    final agent = agentArg is String && agentArg.isNotEmpty ? agentArg : 'subagent';
    final assignment = open?.args?['task'];
    final what = assignment is String ? cutText(assignment.trim(), _assignmentChars) : '';
    _subagents[runId] = SubagentInfo(
      name: _short(runId),
      agent: agent,
      status: 'running',
      assignment: what,
      callId: callId,
      logId: runId,
    );
    _put(
      BackgroundTask(
        id: runId,
        kind: BackgroundKind.agent,
        status: BackgroundStatus.running,
        title: agent,
        detail: what.isEmpty ? null : what,
        startedAt: parseStamp(m),
        toolCallId: callId,
      ),
    );
  }

  void _put(BackgroundTask task) {
    _tasks.remove(task.key);
    _tasks[task.key] = task;
    _taskView = null;
  }

  void _settle(String runId, bool failed, DateTime? at) {
    _finish(runId, failed ? BackgroundStatus.failed : BackgroundStatus.finished, at);
    _setStatus(runId, failed ? 'failed' : 'completed');
  }

  static String _key(String runId) => '0/$runId';

  void _finish(String runId, BackgroundStatus status, DateTime? at) {
    final task = _tasks[_key(runId)];
    if (task == null || !task.isActive) return;
    _tasks[task.key] = task.copyWith(status: status, endedAt: at);
    _taskView = null;
  }

  void _setStatus(String runId, String status) {
    final old = _subagents[runId];
    if (old == null) return;
    _subagents[runId] = SubagentInfo(
      name: old.name,
      agent: old.agent,
      status: status,
      assignment: old.assignment,
      toolCount: old.toolCount,
      recentTools: old.recentTools,
      logId: old.logId,
      callId: old.callId,
    );
  }

  static String _short(String runId) => runId.length <= 8 ? runId : runId.substring(0, 8);

  List<SessionUpdate> _cancelOpen() {
    if (_open.isEmpty) return const [];
    final out = [for (final id in _open.keys) cancelledPatch(id)];
    _open.clear();
    _ask = null;
    return out;
  }

  static bool _endsTurn(Object? stop) => stop == 'stop' || stop == 'error' || stop == 'aborted';

  static Json? _arguments(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.trimLeft().startsWith('{')) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) return d;
      } on Object {
        return null;
      }
    }
    return null;
  }

  static PendingAsk? _parseAsk(String id, Json? args) {
    final qs = args?['questions'];
    if (qs is! List || qs.isEmpty) return null;
    final out = <AskQuestion>[];
    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      if (q is! Map<String, dynamic>) continue;
      final options = <AskOption>[];
      final raw = q['options'];
      if (raw is List) {
        for (final o in raw) {
          if (o is String) {
            options.add(AskOption(label: cutText(o, 300)));
          } else if (o is Map<String, dynamic> && o['label'] is String) {
            final d = o['description'];
            options.add(
              AskOption(label: cutText(o['label'] as String, 300), description: d is String ? capText(d) : ''),
            );
          }
        }
      }
      final question = q['question'];
      final header = q['header'];
      out.add(
        AskQuestion(
          id: header is String && header.isNotEmpty ? header : 'q$i',
          question: question is String ? capText(question) : '',
          options: options,
        ),
      );
    }
    return out.isEmpty ? null : PendingAsk(toolCallId: id, questions: out);
  }

  static PlanUpdate? _plan(Object? tasks) {
    if (tasks is! List) return null;
    final entries = <PlanEntry>[];
    for (final t in tasks) {
      if (t is! Map<String, dynamic>) continue;
      final subject = t['subject'];
      if (subject is! String || subject.isEmpty) continue;
      entries.add(PlanEntry(content: cutText(subject, 300), status: _planStatus(t['status'])));
    }
    return entries.isEmpty ? null : PlanUpdate(entries);
  }

  static PlanStatus _planStatus(Object? s) => switch (s) {
    'in_progress' => PlanStatus.inProgress,
    'completed' => PlanStatus.completed,
    'deleted' => PlanStatus.cancelled,
    _ => PlanStatus.pending,
  };

  static String _userText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is! Map<String, dynamic>) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.isNotEmpty) parts.add(t);
        case 'image':
          parts.add('[image]');
      }
    }
    return parts.join('\n');
  }

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is! Map<String, dynamic>) continue;
      if (b['type'] == 'text') {
        final t = b['text'];
        if (t is String && t.isNotEmpty) parts.add(t);
      } else if (b['type'] == 'image') {
        parts.add('[image]');
      }
    }
    return parts.join('\n');
  }

  static ToolKind _kindOf(String name) {
    switch (name.toLowerCase()) {
      case 'bash':
        return ToolKind.execute;
      case 'read':
        return ToolKind.read;
      case 'edit' || 'write' || 'replace' || 'insert' || 'replace_match' || 'replace_within':
        return ToolKind.edit;
      case 'move':
        return ToolKind.move;
      case 'grep' || 'anchor_grep' || 'session_search':
        return ToolKind.search;
      case 'fetch_content' || 'web_search' || 'get_search_content':
        return ToolKind.fetch;
      case 'todo':
        return ToolKind.think;
      default:
        return ToolKind.other;
    }
  }

  static String _toolTitle(String name, Json? args) {
    String? str(String key) =>
        args?[key] is String && (args![key] as String).trim().isNotEmpty ? args[key] as String : null;
    if (name == 'ask_user_question') {
      final qs = args?['questions'];
      if (qs is List && qs.isNotEmpty && qs.first is Map && (qs.first as Map)['question'] is String) {
        return firstLine(((qs.first as Map)['question'] as String).trim());
      }
      return name;
    }
    if (name == 'todo') {
      final subject = str('subject');
      if (subject != null) return firstLine(subject.trim());
      final description = str('description');
      if (description != null) return firstLine(description.trim());
      return name;
    }
    if (name == 'subagent') {
      final agent = str('agent');
      final task = str('task');
      if (agent != null && task != null) return '$agent: ${firstLine(task.trim())}';
      if (agent != null) return agent;
      final target = str('id');
      if (target != null) return 'status ${_short(target)}';
      return name;
    }
    if (name == 'bg_wait') {
      final target = str('id');
      if (target != null) return 'wait ${_short(target)}';
      return name;
    }
    final command = str('command');
    if (command != null) return firstLine(command.trim());
    final subject = str('path') ?? str('pattern') ?? str('query');
    if (subject != null) return '$name: ${firstLine(subject.trim())}';
    return name;
  }

  String _abs(String path) {
    final cwd = _cwd;
    if (cwd == null || path.startsWith('/') || _scheme.hasMatch(path)) return path;
    final rel = path.startsWith('./') ? path.substring(2) : path;
    return cwd.endsWith('/') ? '$cwd$rel' : '$cwd/$rel';
  }

  List<ToolLocation> _locationsOfCall(Json? args) {
    if (args == null) return const [];
    final path = args['path'];
    if (path is! String || path.isEmpty || _scheme.hasMatch(path)) return const [];
    return [ToolLocation(path: _abs(path))];
  }

  String? _firstTime(Json e, String line) {
    final id = e['id'];
    final key = id is String && id.isNotEmpty ? id : 'h${fnv(line)}';
    return _seen.add(key) ? key : null;
  }

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
}

class _OpenCall {
  const _OpenCall(this.name, this.args);

  final String name;

  /// The call's arguments: a spawn's `agent` and `task`, or a status call's
  /// `id` that names the run its result settles.
  final Json? args;

  String? get statusTarget {
    final target = args?['id'];
    return name == 'subagent' && args?['action'] == 'status' && target is String && target.isNotEmpty ? target : null;
  }
}
