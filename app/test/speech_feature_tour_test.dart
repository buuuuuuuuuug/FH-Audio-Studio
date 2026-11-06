import 'support/capture_output.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/speech_configuration_panel.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_window_flow_test.dart' show fonts;

class TourSpeech extends FakeSpeech {
  @override
  Future<void> checkApi({
    bool autoStart = false,
    bool background = false,
  }) async {}
}

Future<void> capture(GlobalKey frame, String name) async {
  final image =
      await (frame.currentContext!.findRenderObject() as RenderRepaintBoundary)
          .toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = captureOutputFile('gpt-sovits/tours-20261106/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
}

Widget app(SharedPreferences prefs, Widget page, GlobalKey frame) =>
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        automaticFeatureToursProvider.overrideWithValue(true),
      ],
      child: RepaintBoundary(
        key: frame,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(body: page),
        ),
      ),
    );

Future<void> steps(
  WidgetTester t,
  GlobalKey frame,
  List<(String, String)> steps,
  String prefix,
) async {
  for (var i = 0; i < steps.length; i++) {
    final (title, anchor) = steps[i];
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.semanticsLabel == '功能介绍：$title',
      ),
      findsOneWidget,
    );
    final target = find.byWidgetPredicate(
      (w) => w is TourAnchor && w.id == anchor,
    );
    expect(target, findsOneWidget);
    final dynamic painter = t
        .widget<CustomPaint>(
          find.byKey(const ValueKey('feature-tour-highlight')),
        )
        .painter;
    final rect = painter.rect as Rect;
    expect(rect.width, greaterThan(0));
    expect(rect.height, greaterThan(0));
    expect(rect.overlaps(t.getRect(target)), isTrue);
    // The card must stay separated from the highlighted target.
    final card = find
        .ancestor(of: find.text('跳过本页'), matching: find.byType(Container))
        .first;
    expect(t.getRect(card).overlaps(rect), isFalse);
    await t.runAsync(() => capture(frame, '$prefix-${i + 1}'));
    await t.tap(find.text(i == steps.length - 1 ? '知道了' : '下一步'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }
}

void main() {
  setUpAll(fonts);
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });
  for (final width in [1440.0, 960.0]) {
    testWidgets(
      'studio waits for configuration and API, shows five steps once at $width',
      (t) async {
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final prefs = await SharedPreferences.getInstance();
        final s = TourSpeech();
        addTearDown(s.dispose);
        final preset = {...s.presets.single};
        preset['prompt_text'] = 'テスト';
        s.state['engine']['presets'] = [];
        s.state['engine']['api'] = {'ready': false, 'state': 'stopped'};
        final frame = GlobalKey();
        await t.pumpWidget(
          app(
            prefs,
            SpeechStudioWorkbench(session: s, featureTour: true),
            frame,
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        // Files alone must not start the tour while the API is unavailable.
        s.state['engine']['presets'] = [preset];
        t
            .widget<SpeechConfigurationPanel>(
              find.byType(SpeechConfigurationPanel),
            )
            .configuration
            .load(preset);
        s.selectPreset('p');
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        s.state['engine']['api'] = {'ready': true, 'state': 'ready'};
        s.selectPreset('p');
        await t.pumpAndSettle();
        await steps(t, frame, [
          ('API 与推理引擎', 'speech-api'),
          ('模型与声音预设', 'speech-models'),
          ('语言与参考音频', 'speech-reference'),
          ('推理参数', 'speech-parameters'),
          ('生成文本与音频', 'speech-generate'),
        ], 'studio-$width');
        expect(prefs.getBool('rm.tour.v2.speech'), true);
        expect(s.submitted, isNull);
        expect(s.saved, isNull);
        // Returning to the page does not repeat the automatic tour.
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
        await t.pumpWidget(
          app(
            prefs,
            SpeechStudioWorkbench(session: s, featureTour: true),
            frame,
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }
  testWidgets('replacement generation introduces only its three modules once', (
    t,
  ) async {
    t.view.physicalSize = const Size(1100, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final s = TourSpeech();
    addTearDown(s.dispose);
    final prefs = await SharedPreferences.getInstance(), frame = GlobalKey();
    Widget panel() => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SpeechGenerationPanel(
        featureTour: true,
        session: s,
        entries: const [
          {
            'text': 'テスト',
            'name': '语音',
            'language': 'all_ja',
            'target': {'bank_id': 'b', 'index': 0},
          },
        ],
      ),
    );
    await t.pumpWidget(app(prefs, panel(), frame));
    await t.pumpAndSettle();
    await steps(t, frame, [
      ('文本与声音', 'generation-text'),
      ('生成与替换', 'generation-actions'),
      ('试听与简易编辑', 'generation-wave'),
    ], 'replacement');
    expect(prefs.getBool('rm.tour.v2.voiceGeneration'), true);
    expect(s.submitted, isNull);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    await t.pumpWidget(app(prefs, panel(), frame));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('feature-tour-highlight')), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
}
