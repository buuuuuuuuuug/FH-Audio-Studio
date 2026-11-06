import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_icon.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'speech_install_interaction_test.dart' show InstallSpeech;

final theme = buildAppTheme(
  brightness: Brightness.light,
  accent: AppAccent.lime,
);
Future<void> fonts() async {
  GoogleFonts.config.allowRuntimeFetching = false;
  final data = ByteData.sublistView(
    await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
  );
  for (final family in ['Noto Sans SC', 'Roboto', 'Cascadia Mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
  final icon = RmIcon.resolve('settings')!;
  await (FontLoader('packages/${icon.fontPackage}/${icon.fontFamily}')..addFont(
        rootBundle.load(
          'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w400.ttf',
        ),
      ))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

InstallSpeech installing() => InstallSpeech()
  ..state['jobs'] = [
    {
      'id': 'install',
      'kind': 'install',
      'status': 'running',
      'progress': '下载模型 25 / 100 MiB',
      'download': {'fraction': .25},
    },
  ];
void size(WidgetTester t, Size value) {
  t.view.physicalSize = value;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Future<void> capture(WidgetTester t, GlobalKey frame, String name) async {
  await t.runAsync(() async {
    final img =
        await (frame.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    await File(
      'D:/FH6_Music/outputs/gpt-sovits/revision-20261104-window-flow/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    img.dispose();
  });
}

void main() {
  setUpAll(fonts);
  testWidgets(
    'backdrop and escape use the same installation decision; background continues',
    (t) async {
      size(t, const Size(1400, 1100));
      final s = installing();
      addTearDown(s.dispose);
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: AudioEditorHost(
              child: Builder(
                builder: (context) => RmButton(
                  label: 'Open',
                  onPressed: () => showSpeechEngineDialog(context, s),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(find.text('Esc 关闭'), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('安装还在进行'), findsOneWidget);
      expect(s.actions, isNot(contains('pause-install')));
      await t.tap(find.text('继续查看'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('安装还在进行'), findsOneWidget);
      await t.tap(find.text('后台继续'));
      await t.pumpAndSettle();
      expect(find.text('安装与设置推理引擎'), findsNothing);
      expect(s.actions, isNot(contains('pause-install')));
      expect(s.installing, isTrue);
    },
  );
  testWidgets('application exit can cancel or pause before allowing close', (
    t,
  ) async {
    size(t, const Size(900, 700));
    final s = installing();
    addTearDown(s.dispose);
    bool? result;
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => RmButton(
              label: 'Exit',
              onPressed: () async {
                result = await confirmSpeechInstallationExit(
                  context,
                  session: s,
                );
              },
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Exit'));
    await t.pumpAndSettle();
    await t.tap(find.text('继续安装'));
    await t.pumpAndSettle();
    expect(result, isFalse);
    expect(s.installing, isTrue);
    await t.tap(find.text('Exit'));
    await t.pumpAndSettle();
    await t.tap(find.text('暂停并退出'));
    await t.pumpAndSettle();
    expect(result, isTrue);
    expect(s.installing, isFalse);
    expect(s.actions, contains('pause-install'));
  });
  testWidgets(
    'background installation shows live progress and opens existing workflow',
    (t) async {
      size(t, const Size(1400, 1100));
      final s = installing();
      addTearDown(s.dispose);
      SpeechGenerationSession.activeInstallation.value = s;
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: SpeechInstallIndicator()),
        ),
      );
      await t.pump();
      expect(find.text('引擎安装 25%'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('speech-background-install')));
      await t.pumpAndSettle();
      expect(find.text('下载模型 25 / 100 MiB'), findsOneWidget);
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      await t.tap(find.text('暂停并关闭'));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-background-install')),
        findsNothing,
      );
    },
  );
  for (final width in [780.0, 1400.0]) {
    testWidgets('installer uses shared controls at $width', (t) async {
      size(t, Size(width, 1100));
      final s = InstallSpeech();
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
                  label: 'Open',
                  onPressed: () => showSpeechEngineDialog(context, s),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byKey(const ValueKey('speech-auto-start')), findsOneWidget);
      expect(
        t.getSize(find.byKey(const ValueKey('speech-manual-install'))).height,
        32,
      );
      await capture(t, frame, 'installer-$width');
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('unconfigured guidance stays centered with a bounded width', (
    t,
  ) async {
    size(t, const Size(1400, 900));
    final s = InstallSpeech();
    addTearDown(s.dispose);
    s.state['engine']['installed'] = false;
    s.state['engine']['presets'] = [];
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
    expect(t.getTopLeft(find.text('先配置推理引擎')).dy, greaterThan(250));
    await capture(t, frame, 'setup-guidance');
    expect(t.takeException(), isNull);
  });
}
