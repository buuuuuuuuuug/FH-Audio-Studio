import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/screens/voices/rvc_workbench.dart';
import 'package:fh_radio_studio/screens/voices/rvc_configuration.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'rvc_workbench_test.dart' show rvcSession;
import 'speech_feature_tour_test.dart' as guide;
import 'speech_window_flow_test.dart' show fonts, size, theme;

class ParameterSession extends FakeSpeech {
  ParameterSession() {
    state = rvcSession().state;
  }
  Map<String, dynamic>? parameters;
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (action == 'save-parameters') {
      parameters = input;
      state['engine']['parameters'] = input;
      notifyListeners();
    }
    return super.call(action, input);
  }
}

void main() {
  setUpAll(fonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [1440.0, 960.0]) {
    testWidgets(
      'RVC tour waits for engine and model, completes five steps once at $width',
      (t) async {
        size(t, Size(width, 950));
        final prefs = await SharedPreferences.getInstance();
        final s = rvcSession();
        addTearDown(s.dispose);
        s.state['engine']['installed'] = false;
        final frame = GlobalKey();
        Widget page() =>
            RvcWorkbench(session: s, featureTour: true, onTextMode: () {});
        await t.pumpWidget(guide.app(prefs, page(), frame));
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        s.state['engine']['installed'] = true;
        s.state['engine']['selection'] = {};
        s.notifyListeners();
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        s.state['engine']['selection'] = {'model_id': 'voice'};
        s.notifyListeners();
        await t.pumpAndSettle();
        await guide.steps(t, frame, [
          ('引擎与推理设备', 'rvc-engine'),
          ('音色模型与关联索引', 'rvc-models'),
          ('音色转换参数', 'rvc-parameters'),
          ('导入源音频', 'rvc-source'),
          ('转换结果与音频编辑', 'rvc-output'),
        ], 'rvc-$width');
        expect(prefs.getBool('rm.tour.v2.rvc'), true);
        expect(s.submitted, isNull);
        expect(find.text('保存参数'), findsNothing);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
        await t.pumpWidget(guide.app(prefs, page(), frame));
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        final context = t.element(find.byType(RvcWorkbench));
        unawaited(
          ProviderScope.containerOf(
            context,
          ).read(featureToursProvider).showCurrent(),
        );
        await t.pumpAndSettle();
        expect(find.text('跳过本页'), findsOneWidget);
        await t.tap(find.text('跳过本页'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
      },
    );
  }
  testWidgets('replacement RVC has its own three-step introduction', (t) async {
    size(t, const Size(1200, 850));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rm.tour.v2.voiceGeneration', true);
    final s = rvcSession();
    addTearDown(s.dispose);
    final frame = GlobalKey();
    Widget page() => SingleChildScrollView(
      child: SpeechGenerationPanel(
        session: s,
        featureTour: true,
        conversion: true,
        entries: const [
          {
            'name': '语音',
            'text': '原句内容',
            'voice_language': 'JP',
            'target': {'bank_id': 'b', 'index': 0},
          },
        ],
      ),
    );
    await t.pumpWidget(guide.app(prefs, page(), frame));
    await t.pumpAndSettle();
    await guide.steps(t, frame, [
      ('原音与目标音色', 'generation-text'),
      ('转换与自动替换', 'generation-actions'),
      ('试听转换结果', 'generation-wave'),
    ], 'rvc-replacement');
    expect(prefs.getBool('rm.tour.v2.voiceConversion'), true);
    expect(s.submitted, isNull);
    expect(t.widget<TextField>(find.byType(TextField).first).readOnly, isTrue);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();
    await t.pumpWidget(guide.app(prefs, page(), frame));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('feature-tour-highlight')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();
  });
  testWidgets(
    'RVC removes saved schemes while retaining automatic parameter persistence',
    (t) async {
      size(t, const Size(1000, 950));
      final s = ParameterSession();
      s.state['engine']['schemes'] = [
        {'name': '旧方案', 'parameters': s.engine['parameters']},
      ];
      addTearDown(s.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: RvcConfigurationPanel(session: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('保存参数'), findsNothing);
      expect(find.text('选择独立参数方案'), findsNothing);
      expect(find.text('旧方案'), findsNothing);
      final pitch = find.descendant(
        of: find.byType(RmNumberField).first,
        matching: find.byType(TextField),
      );
      await t.enterText(pitch, '4');
      await t.pumpAndSettle();
      expect(s.parameters?['pitch'], 4);
      expect(s.engine['selection']['model_id'], 'voice');
      expect(t.takeException(), isNull);
    },
  );
}
