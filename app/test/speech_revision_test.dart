import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'studio_v18_workflow_test.dart' as fixtures;

Widget app(Widget child) => MaterialApp(
  theme: buildAppTheme(brightness: Brightness.light, accent: AppAccent.lime),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'experiment defaults on, saves per project and gates navigation',
    (t) async {
      final c = await fixtures.fixture();
      final project = c.read(studioProvider).projectDir;
      expect(c.read(editorOptionsProvider).speechEnabled, true);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: app(const Sidebar(activeId: 'dashboard')),
        ),
      );
      expect(find.text('语音生成'), findsOneWidget);
      c.read(editorOptionsProvider.notifier).update(speechEnabled: false);
      await t.pumpAndSettle();
      expect(find.text('语音生成'), findsNothing);
      c.read(editorOptionsProvider.notifier).update(speechEnabled: true);
      await t.pumpAndSettle();
      expect(find.text('语音生成'), findsOneWidget);
      expect(
        FhRadioStudioProject.readSettings(project)['speech_generation_enabled'],
        true,
      );
      c.read(editorOptionsProvider.notifier).update(speechEnabled: false);
      await t.pumpAndSettle();
      expect(find.text('语音生成'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'installed workspace retains generation area while voices are unconfigured',
    (t) async {
      final s = FakeSpeech();
      addTearDown(s.dispose);
      s.state['engine']['presets'] = [];
      s.state['engine']['api'] = {'state': 'unconfigured', 'ready': false};
      await t.pumpWidget(app(SpeechStudioWorkbench(session: s)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('speech-studio-text')), findsOneWidget);
      expect(find.text('声音配置'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      final configured = FakeSpeech();
      addTearDown(configured.dispose);
      await t.pumpWidget(app(SpeechStudioWorkbench(session: configured)));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('speech-studio-text')),
        'preserve this',
      );
      configured.state['engine']['api'] = {
        'state': 'error',
        'ready': false,
        'detail': 'Disconnected',
      };
      // Fake has no background timer; publish the same state change as a health check.
      configured.selectPreset('p');
      await t.pumpAndSettle();
      expect(find.text('preserve this'), findsOneWidget);
      expect(find.text('API 异常'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(SpeechStudioWorkbench(session: configured)));
      await t.pumpAndSettle();
      expect(find.text('preserve this'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'divider follows drag, persists ratio and double click restores',
    (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = FakeSpeech();
      addTearDown(s.dispose);
      await t.pumpWidget(
        app(SpeechStudioWorkbench(session: s, preferences: prefs)),
      );
      await t.pumpAndSettle();
      final divider = find.byKey(const ValueKey('speech-column-divider'));
      final before = t.getCenter(divider).dx;
      await t.drag(divider, const Offset(130, 0));
      await t.pumpAndSettle();
      expect(t.getCenter(divider).dx - before, closeTo(130, 3));
      expect(prefs.getDouble('speech.configurationRatio'), greaterThan(.32));
      await t.tap(divider);
      await t.pump(const Duration(milliseconds: 60));
      await t.tap(divider);
      await t.pumpAndSettle();
      expect(prefs.getDouble('speech.configurationRatio'), .32);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'text undo is local, sources and input restore after navigation',
    (t) async {
      final s = FakeSpeech();
      addTearDown(s.dispose);
      Widget page() => app(
        SingleChildScrollView(
          child: SpeechGenerationPanel(
            session: s,
            entries: [
              {
                'name': 'entry',
                'content': 'original',
                'translation': 'display',
                'target': {'bank_id': 'b', 'index': 0},
              },
            ],
          ),
        ),
      );
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      final input = find.byKey(const ValueKey('speech-text'));
      await t.tap(input);
      await t.pump(const Duration(milliseconds: 600));
      await t.enterText(input, 'edited draft');
      await t.pump(const Duration(milliseconds: 600));
      await t.enterText(input, 'edited draft two');
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      final undoText = t.widget<TextField>(input).controller!.text;
      expect(undoText, 'edited draft');
      await t.enterText(input, 'restored draft');
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(find.text('restored draft'), findsOneWidget);
      expect(find.text('原音作参考'), findsNothing);
      expect(find.text('手动输入'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  for (final width in [950.0, 520.0, 320.0]) {
    testWidgets('replacement generation controls align at $width', (t) async {
      t.view.physicalSize = Size(width + 20, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = FakeSpeech();
      addTearDown(s.dispose);
      await t.pumpWidget(
        app(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SpeechGenerationPanel(
                session: s,
                entries: [
                  {'name': 'entry', 'content': 'hello'},
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final generate = find.byKey(const ValueKey('speech-generate'));
      for (final label in ['语音语言', '模型设置', '取消应用', '删除文件']) {
        expect(t.getSize(find.widgetWithText(RmButton, label)).height, 32);
      }
      expect(t.getSize(generate).height, 32);
      final play = find.byKey(const ValueKey('speech-preview-play'));
      final edit = find.widgetWithText(RmButton, '取消应用');
      final clear = find.widgetWithText(RmButton, '删除文件');
      expect(t.getTopLeft(play).dx, greaterThanOrEqualTo(0));
      expect(t.getTopLeft(edit).dx, greaterThanOrEqualTo(0));
      expect(t.getTopLeft(clear).dx, greaterThanOrEqualTo(0));
      expect(find.text('声音预设'), findsNothing);
      expect(find.text('匹配原音时长'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
