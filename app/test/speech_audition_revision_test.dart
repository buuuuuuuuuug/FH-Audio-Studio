import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_preview_workflow_test.dart' show app;

class ProbeSpeech extends FakeSpeech {
  final gate = Completer<void>();
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (action == 'check-engine') await gate.future;
    return state;
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('a healthy API remains ready during a periodic health probe', () async {
    final session = ProbeSpeech();
    addTearDown(session.dispose);
    final states = <String>[];
    session.addListener(() => states.add(session.apiState));
    final checking = session.checkApi(background: true);
    expect(session.apiState, 'ready');
    session.gate.complete();
    await checking;
    expect(states, isNot(contains('checking')));
    session.state['engine']['api'] = {'state': 'error', 'ready': false};
    await session.checkApi(background: true);
    expect(session.apiState, 'error');
  });

  testWidgets('batch controls stay in one row and report the entire batch', (
    t,
  ) async {
    t.view.physicalSize = const Size(2400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final s = FakeSpeech();
    addTearDown(s.dispose);
    s.state['jobs'] = [
      for (var i = 0; i < 3; i++)
        {
          'id': 'j$i',
          'origin': 'replacement',
          'target': {'bank_id': 'b', 'index': i},
          'status': ['running', 'queued', 'ready'][i],
          'progress': '生成音频 1/1',
          'candidates': [],
        },
    ];
    s.composerDrafts['replacement-batch'] = {
      'ids': ['j0', 'j1', 'j2'],
    };
    await t.pumpWidget(
      app(
        SpeechGenerationPanel(
          session: s,
          entries: [
            for (var i = 0; i < 3; i++)
              {
                'name': '条目$i',
                'target': {'bank_id': 'b', 'index': i},
              },
          ],
        ),
      ),
    );
    await t.pump();
    final restore = find.byKey(const ValueKey('speech-generate'));
    final skip = find.byKey(const ValueKey('speech-skip-existing'));
    expect(t.getCenter(skip).dy, closeTo(t.getCenter(restore).dy, 1));
    expect(t.getCenter(skip).dx, greaterThan(t.getCenter(restore).dx));
    final status = find.byKey(const ValueKey('speech-generation-status'));
    expect(t.getSize(status).height, 32);
    expect(find.textContaining('完成 1/3 · 剩余 2 · 排队 1'), findsOneWidget);
    s.state['jobs'][0]['status'] = 'cancelled';
    s.state['jobs'][1]['status'] = 'failed';
    s.notifyListeners();
    await t.pump();
    expect(find.textContaining('剩余 0 · 失败 1 · 取消 1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
