import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/screens/voices/rvc_configuration.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'package:fh_radio_studio/widgets/speech_experiment_setting.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_install_interaction_test.dart' show InstallSpeech;
import 'rvc_workbench_test.dart' show rvcSession;
import 'speech_window_flow_test.dart' show fonts, size, theme;
import 'studio_v18_workflow_test.dart' as fixtures;
import 'support/capture_output.dart';

class RvcSettingsSession extends FakeSpeech {
  RvcSettingsSession() {
    state = rvcSession().state;
  }
  final changes = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (['configure-runtime', 'configure-downloads'].contains(action)) {
      changes[action] = input;
      state['engine'][action == 'configure-runtime' ? 'runtime' : 'downloads'] =
          input;
      notifyListeners();
    }
    return super.call(action, input);
  }
}

Future<void> capture(WidgetTester t, GlobalKey key, String name) => t.runAsync(
  () async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await captureOutputFile(
      'rvc/revision-20261114/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  },
);

void main() {
  setUpAll(fonts);
  testWidgets('RVC device and mirrors save without altering voice selection', (
    t,
  ) async {
    size(t, const Size(1500, 1100));
    final s = RvcSettingsSession();
    addTearDown(s.dispose);
    final frame = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AudioEditorHost(
              child: Builder(
                builder: (context) => RmButton(
                  label: 'Settings',
                  onPressed: () => showRvcConfigurationDialog(context, s),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rvc-inference-device')));
    await t.pumpAndSettle();
    await t.tap(find.text('CUDA · NVIDIA 显卡').last);
    await t.pumpAndSettle();
    expect(s.changes['configure-runtime']?['device'], 'cuda:0');
    expect(s.engine['selection']['model_id'], 'voice');
    await capture(t, frame, 'configuration-device');
    await t.tap(find.widgetWithText(RmButton, '推理引擎'));
    await t.pumpAndSettle();
    final profile = find.byKey(const ValueKey('rvc-download-profile'));
    final directory = find.widgetWithText(RmButton, '打开安装目录');
    expect(
      (t.getRect(profile).center.dy - t.getRect(directory).center.dy).abs(),
      lessThan(1),
    );
    await t.tap(profile);
    await t.pumpAndSettle();
    await t.tap(find.text('国内镜像').last);
    await t.pumpAndSettle();
    expect(
      s.changes['configure-downloads']?['rvc_torch'],
      'https://mirror.sjtu.edu.cn/pytorch-wheels',
    );
    expect(s.changes['configure-downloads']?['profile'], 'domestic');
    expect(find.text('清华大学'), findsOneWidget);
    await capture(t, frame, 'engine-mirrors');
    await t.tap(find.widgetWithText(RmButton, '完成'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
  for (final width in [780.0, 1500.0]) {
    testWidgets(
      'mode click preserves position and RVC folder action at $width',
      (t) async {
        size(t, Size(width, 950));
        final gpt = FakeSpeech(), rvc = rvcSession();
        addTearDown(gpt.dispose);
        addTearDown(rvc.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SpeechStudioWorkbench(session: gpt, conversionSession: rvc),
            ),
          ),
        );
        await t.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('speech-mode-switch'));
        final before = t.getRect(toggle);
        await t.tap(toggle);
        await t.pumpAndSettle();
        expect(t.getRect(toggle), before);
        expect(find.widgetWithText(RmButton, 'RVC'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('rvc-open-engine-directory')),
          findsOneWidget,
        );
        await t.tap(toggle);
        await t.pumpAndSettle();
        expect(t.getRect(toggle), before);
        expect(find.widgetWithText(RmButton, 'GPT-SoVITS'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }

  for (final tabs in [false, true]) {
    testWidgets(
      'RVC ${tabs ? 'tabs' : 'sidebar'} navigation closes idle and guards installation',
      (t) async {
        size(t, const Size(1550, 1000));
        final container = await fixtures.fixture();
        final s = InstallSpeech();
        s.state['engine'] = {
          ...rvcSession().engine,
          'components': [
            {'name': '推理源码', 'ready': true},
            {'name': '推理环境', 'ready': true},
            {'name': '特征与音高模型', 'ready': true},
          ],
        };
        addTearDown(s.dispose);
        final frame = GlobalKey();
        final router = GoRouter(
          initialLocation: '/speech',
          routes: [
            ShellRoute(
              builder: (_, _, child) => Scaffold(
                body: tabs
                    ? Column(
                        children: [
                          const TabsBar(activeId: 'speech'),
                          Expanded(child: child),
                        ],
                      )
                    : Row(
                        children: [
                          const Sidebar(activeId: 'speech'),
                          Expanded(child: child),
                        ],
                      ),
              ),
              routes: [
                GoRoute(
                  path: '/speech',
                  onExit: (_, _) => confirmAudioEditorNavigation(),
                  pageBuilder: (_, _) => NoTransitionPage(
                    child: AudioEditorHost(
                      child: Builder(
                        builder: (context) => Align(
                          alignment: Alignment.topLeft,
                          child: RmButton(
                            label: 'Engine',
                            onPressed: () => showRvcEngineDialog(context, s),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                for (final path in ['/voices', '/pool', '/playlist'])
                  GoRoute(
                    path: path,
                    pageBuilder: (_, _) =>
                        NoTransitionPage(child: Text('Page $path')),
                  ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await t.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(theme: theme, routerConfig: router),
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('Engine'));
        await t.pumpAndSettle();
        expect(find.text('安装与设置 RVC 引擎'), findsOneWidget);
        expect(find.byType(SpeechEngineConsole), findsOneWidget);
        final log = t.getRect(find.byKey(const ValueKey('speech-console-log')));
        final settings = t.getRect(
          find.byKey(const ValueKey('rvc-install-settings')),
        );
        expect((log.bottom - settings.bottom).abs(), lessThan(1));
        await capture(t, frame, tabs ? 'engine-tabs' : 'engine-sidebar');
        await t.tap(find.text('语音替换'));
        await t.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/voices');
        expect(find.text('安装与设置 RVC 引擎'), findsNothing);

        router.go('/speech');
        await t.pumpAndSettle();
        s.state['jobs'] = [
          {
            'id': 'install',
            'kind': 'install',
            'status': 'running',
            'progress': '下载模型',
          },
        ];
        await t.tap(find.text('Engine'));
        await t.pumpAndSettle();
        await t.tap(find.text('语音替换'));
        await t.pumpAndSettle();
        expect(find.text('安装还在进行'), findsOneWidget);
        await t.tap(find.text('继续查看'));
        await t.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/speech');
        await t.tap(find.text('自建歌曲'));
        await t.pumpAndSettle();
        await t.tap(find.text('后台继续'));
        await t.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/pool');
        expect(s.installing, isTrue);
        router.go('/speech');
        await t.pumpAndSettle();
        await t.tap(find.text('Engine'));
        await t.pumpAndSettle();
        await t.tapAt(const Offset(550, 950));
        await t.pumpAndSettle();
        expect(find.text('安装还在进行'), findsOneWidget);
        await t.tap(find.text('暂停并关闭'));
        await t.pumpAndSettle();
        expect(s.actions, contains('pause-install'));
        expect(find.text('安装与设置 RVC 引擎'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'feature switch hides immediately and saves without starting idle engines',
    (t) async {
      final c = await fixtures.fixture();
      final gpt = FakeSpeech(), rvc = FakeSpeech();
      addTearDown(gpt.dispose);
      addTearDown(rvc.dispose);
      final key = jsonEncode([
        c.read(studioProvider).repoRoot,
        c.read(studioProvider).projectDir,
      ]);
      final child = ProviderContainer(
        parent: c,
        overrides: [
          speechGenerationProvider(key).overrideWithValue(gpt),
          rvcGenerationProvider(key).overrideWithValue(rvc),
        ],
      );
      addTearDown(child.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: child,
          child: MaterialApp(
            theme: theme,
            home: const Scaffold(body: SpeechExperimentSetting()),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(child.read(editorOptionsProvider).speechEnabled, isFalse);
      expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(child.read(editorOptionsProvider).speechEnabled, isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('replacement model settings can open the guarded engine window', (
    t,
  ) async {
    size(t, const Size(1500, 1000));
    final session = rvcSession();
    addTearDown(session.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: AudioEditorHost(
            child: Builder(
              builder: (context) => RmButton(
                label: 'Model',
                onPressed: () => showRvcConfigurationDialog(context, session),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Model'));
    await t.pumpAndSettle();
    expect(find.text('RVC 音色与参数'), findsOneWidget);
    await t.tap(find.widgetWithText(RmButton, '推理引擎'));
    await t.pumpAndSettle();
    expect(find.text('RVC 音色与参数'), findsNothing);
    expect(find.text('安装与设置 RVC 引擎'), findsOneWidget);
    await t.tap(find.widgetWithText(RmButton, '完成'));
    await t.pumpAndSettle();
    expect(find.text('安装与设置 RVC 引擎'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('disabled duration uses muted text fill and border', (t) async {
    final controller = TextEditingController(text: '100');
    addTearDown(controller.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: RmNumberField(
                controller: controller,
                min: 1,
                max: 1000,
                step: 10,
                enabled: false,
                unit: 'ms',
              ),
            ),
          ),
        ),
      ),
    );
    final field = t.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(field.decoration!.disabledBorder, isA<OutlineInputBorder>());
    expect(
      (field.decoration!.disabledBorder! as OutlineInputBorder)
          .borderSide
          .color
          .a,
      lessThan(
        (field.decoration!.enabledBorder! as OutlineInputBorder)
            .borderSide
            .color
            .a,
      ),
    );
  });
}
