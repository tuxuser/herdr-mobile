import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview.dart';

import '../support/fake_agent_session.dart';

void main() {
  AgentSessionState withModel() => const AgentSessionState(
    's1',
  ).apply(const SessionModelUpdate(provider: 'opencode-go', model: 'muse-spark-1.3-contributor', thinking: 'medium'));

  Future<void> pumpSheet(WidgetTester tester, AgentSessionState state) async {
    tester.view.physicalSize = const Size(412, 892) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SessionOverview(session: FakeAgentSession(state: state)),
      ),
    );
    await tester.pump();
  }

  testWidgets('a reported model and thinking show their facts', (tester) async {
    await pumpSheet(tester, withModel());

    expect(find.text('Model'), findsOneWidget);
    expect(find.text('muse-spark-1.3-contributor (opencode-go)'), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('medium'), findsOneWidget);
  });

  testWidgets('nothing reported, no model section', (tester) async {
    await pumpSheet(tester, const AgentSessionState('s1'));

    expect(find.text('Model'), findsNothing);
    expect(find.text('Thinking'), findsNothing);
  });

  testWidgets('unsized usage names what it used', (tester) async {
    final state = const AgentSessionState('s1').apply(const UsageUpdate(AcpUsage(used: 150, size: 0)));
    await pumpSheet(tester, state);

    expect(find.text('Used'), findsOneWidget);
    expect(find.textContaining('150'), findsOneWidget);
  });
}
