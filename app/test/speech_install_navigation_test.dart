import 'support/capture_output.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/widgets/rm_chip.dart';
import 'speech_window_flow_test.dart' show fonts, size, theme;
import 'speech_install_interaction_test.dart' show InstallSpeech;
import 'studio_v18_workflow_test.dart' as fixtures;

InstallSpeech installation() => InstallSpeech()
  ..state['engine']['installed'] = false
  ..state['engine']['presets'] = []
  ..state['engine']['api'] = {'ready': false, 'state': 'stopped'}
  ..state['jobs'] = [
    {
      'id': 'install',
      'kind': 'install',
      'status': 'running',
      'progress': '下载基础模型 · 128.0 MiB / 621.1 MiB',
      'download': {
        'received': 134217728,
        'total': 651270553,
        'fraction': .206,
        'bytes_per_second': 1572864,
      },
      'installation': {'completed': 5, 'total': 14, 'fraction': 5.206 / 14},
    },
  ];
Future<void> screenshot(WidgetTester t, GlobalKey frame, String name) async {
  await t.runAsync(() async {
    final image =
        await (frame.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await captureOutputFile(
      'gpt-sovits/revision-20261104-install-navigation/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(fonts);
  for (final tabs in [false, true]) {
    testWidgets(
      'real ${tabs ? 'tab' : 'sidebar'} navigation waits for installation choice',
      (t) async {
        size(t, const Size(1500, 1100));
        final container = await fixtures.fixture();
        addTearDown(container.dispose);
        final s = installation();
        addTearDown(s.dispose);
        final router = GoRouter(
          initialLocation: '/speech',
          routes: [
            ShellRoute(
              builder: (context, state, child) => Scaffold(
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
                            onPressed: () => showSpeechEngineDialog(context, s),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                for (final path in ['/pool', '/playlist', '/dashboard'])
                  GoRoute(
                    path: path,
                    onExit: (_, _) => confirmAudioEditorNavigation(),
                    pageBuilder: (_, _) => NoTransitionPage(
                      child: Center(child: Text('Page $path')),
                    ),
                  ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              debugShowCheckedModeBanner: false,
              theme: theme,
              routerConfig: router,
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('Engine'));
        await t.pumpAndSettle();
        if (!tabs) {
          final overview = t.getRect(find.text('概览'));
          final toggle = t.getRect(
            find.byKey(const ValueKey('sidebar-toggle')),
          );
          expect((overview.center.dy - toggle.center.dy).abs(), lessThan(1));
          expect(toggle.height, 26);
        }
        await t.tap(find.text('自建歌曲'));
        await t.pumpAndSettle();
        expect(find.text('安装还在进行'), findsOneWidget);
        expect(router.routerDelegate.currentConfiguration.uri.path, '/speech');
        await t.tap(find.text('继续查看'));
        await t.pumpAndSettle();
        expect(find.text('安装与设置推理引擎'), findsOneWidget);
        expect(s.actions, isNot(contains('pause-install')));
        await t.tap(find.byKey(const ValueKey('speech-manual-install')));
        await t.pumpAndSettle();
        expect(find.text('手动准备推理引擎'), findsOneWidget);
        await t.tap(find.text('播放列表'));
        await t.pumpAndSettle();
        await t.tap(find.text('后台继续'));
        await t.pumpAndSettle();
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/playlist',
        );
        expect(s.installing, true);
        expect(find.text('安装与设置推理引擎'), findsNothing);
        router.go('/speech');
        await t.pumpAndSettle();
        await t.tap(find.text('Engine'));
        await t.pumpAndSettle();
        await t.tap(find.text('概览'));
        await t.pumpAndSettle();
        await t.tap(find.text('暂停并关闭'));
        await t.pumpAndSettle();
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/dashboard',
        );
        expect(s.installing, false);
        expect(t.takeException(), isNull);
      },
    );
  }
  for (final width in [780.0, 1400.0]) {
    testWidgets('installer speed, total and manual popup fit $width', (
      t,
    ) async {
      size(t, Size(width, 1100));
      final s = installation();
      addTearDown(s.dispose);
      final frame = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(
              body: Builder(
                builder: (context) => RmButton(
                  label: 'Engine',
                  onPressed: () => showSpeechEngineDialog(context, s),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Engine'));
      await t.pumpAndSettle();
      expect(find.text('1. 安装组件 → 2. 配置声音模型和参考音频 → 3. 启动 API'), findsNothing);
      expect(find.text('1.5 MiB/s'), findsOneWidget);
      expect(find.text('总进度 · 5/14 个步骤'), findsOneWidget);
      final manual = t.getRect(
        find.byKey(const ValueKey('speech-manual-install')),
      );
      final folder = t.getRect(find.widgetWithText(RmButton, '打开安装目录'));
      expect(manual.center.dy, folder.center.dy);
      expect(manual.right, lessThan(folder.left));
      expect(find.byType(Switch), findsNothing);
      await screenshot(t, frame, 'installer-$width');
      await t.tap(find.byKey(const ValueKey('speech-manual-install')));
      await t.pumpAndSettle();
      expect(find.text('手动准备推理引擎'), findsOneWidget);
      expect(find.text('复制地址'), findsOneWidget);
      await screenshot(t, frame, 'manual-$width');
      expect(t.takeException(), isNull);
    });
  }
  for (final width in [780.0, 1400.0]) {
    testWidgets(
      'setup card header stays on one row and action is on the right at $width',
      (t) async {
        size(t, Size(width, 900));
        final s = InstallSpeech();
        addTearDown(s.dispose);
        s.state['engine']['installed'] = false;
        s.state['engine']['presets'] = [];
        s.state['engine']['api'] = {'ready': false, 'state': 'unconfigured'};
        final frame = GlobalKey();
        await t.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: Scaffold(body: SpeechStudioWorkbench(session: s)),
            ),
          ),
        );
        await t.pumpAndSettle();
        final title = t.getRect(find.text('先配置推理引擎'));
        final status = t.getRect(find.byType(RmChip));
        expect((title.top - status.top).abs(), lessThan(3));
        final card = t.getRect(
          find
              .ancestor(
                of: find.text('先配置推理引擎'),
                matching: find.byType(Container),
              )
              .first,
        );
        final button = t.getRect(find.widgetWithText(RmButton, '安装与设置推理引擎'));
        expect(button.right, closeTo(card.right - 16, 1));
        expect(card.center.dx, closeTo(width / 2, 1));
        await screenshot(t, frame, 'guidance-$width');
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'installed engine keeps generation workspace visible before voice configuration',
    (t) async {
      size(t, const Size(1400, 1000));
      final s = InstallSpeech();
      addTearDown(s.dispose);
      s.state['engine']['installed'] = true;
      s.state['engine']['presets'] = [];
      s.state['engine']['api'] = {'ready': false, 'state': 'stopped'};
      final frame = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(body: SpeechStudioWorkbench(session: s)),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('声音配置'), findsOneWidget);
      expect(find.text('生成文本'), findsOneWidget);
      expect(find.text('导入'), findsNWidgets(3));
      expect(find.text('先配置推理引擎'), findsNothing);
      await screenshot(t, frame, 'installed-unconfigured');
      expect(t.takeException(), isNull);
    },
  );
}
