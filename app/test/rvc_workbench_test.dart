import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/rvc_workbench.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_icon.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'support/capture_output.dart';

FakeSpeech rvcSession() {
  final s = FakeSpeech();
  s.state['inputs'] = [
    {'name': '原始播报', 'path': 'original.wav', 'duration': 2.5},
  ];
  s.state['engine'] = {
    'installed': true,
    'api': {'ready': false, 'state': 'stopped'},
    'selection': {'model_id': 'voice'},
    'parameters': {
      'pitch': 0,
      'speaker_id': 0,
      'f0_method': 'rmvpe',
      'index_rate': .75,
      'protect': .33,
      'rms_mix_rate': .25,
      'filter_radius': 3,
    },
    'files': [
      {'id': 'voice', 'filename': '测试音色.pth', 'kind': 'model'},
    ],
    'presets': <Map<String, dynamic>>[],
  };
  return s;
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    if (Platform.isWindows &&
        await File('C:/Windows/Fonts/msyh.ttc').exists()) {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      for (final family in [
        'Noto Sans SC',
        'Microsoft YaHei UI',
        'Cascadia Mono',
      ]) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
    final glyph = RmIcon.resolve('settings')!;
    final icon = FontLoader('packages/${glyph.fontPackage}/${glyph.fontFamily}')
      ..addFont(
        rootBundle.load(
          'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w400.ttf',
        ),
      );
    await icon.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [720.0, 1100.0, 1700.0]) {
    testWidgets('RVC shared workbench adapts and submits source at $width', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = rvcSession();
      addTearDown(session.dispose);
      final frame = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: RvcWorkbench(session: session, onTextMode: () {}),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('测试音色.pth'), findsOneWidget);
      expect(find.text('参考音频对应文本'), findsNothing);
      await t.tap(find.widgetWithText(RmButton, '转换音色'));
      await t.pumpAndSettle();
      expect(session.submitted?['entries'][0]['path'], 'original.wav');
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (frame.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await captureOutputFile(
          'rvc/workbench-$width.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
  testWidgets(
    'replacement conversion uses original target without GPT preset',
    (t) async {
      final s = rvcSession();
      addTearDown(s.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpeechGenerationPanel(
                session: s,
                conversion: true,
                entries: const [
                  {
                    'name': '语音1',
                    'text': '原音文本',
                    'voice_language': 'JP',
                    'target': {
                      'bank_id': 'bank',
                      'sha256': 'hash',
                      'index': 3,
                      'expected': null,
                    },
                  },
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(RmButton, '转换音色'));
      await t.pumpAndSettle();
      expect(s.submitted?['entries'][0]['target']['index'], 3);
      expect(s.submitted?['entries'][0]['voice_language'], 'JP');
      expect(t.takeException(), isNull);
    },
  );
}
