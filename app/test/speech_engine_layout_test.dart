import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'speech_generation_test.dart' show FakeSpeech;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [720.0, 1100.0]) {
    testWidgets('engine controls stay compact without stale failures at $width', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = FakeSpeech();
      addTearDown(session.dispose);
      session.state['jobs'] = [
        {
          'id': 'old',
          'kind': 'start-engine',
          'status': 'failed',
          'error': 'old 404 error',
        },
      ];
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
              body: Builder(
                builder: (context) => RmButton(
                  label: '设置',
                  onPressed: () =>
                      unawaited(showSpeechEngineDialog(context, session)),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.widgetWithText(RmButton, '设置'));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (frame.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'D:/FH6_Music/outputs/gpt-sovits/revision-20261104-installer/engine-$width.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      if (width >= 1000) {
        expect(
          t.getBottomLeft(find.byKey(const ValueKey('speech-console-log'))).dy,
          closeTo(
            t
                .getBottomLeft(
                  find.byKey(const ValueKey('speech-install-settings')),
                )
                .dy,
            1,
          ),
        );
      }
      for (final label in [
        '测试连接',
        '安装或修复',
        '检查组件',
        '删除推理引擎',
        '启动服务',
        '停止服务',
        '重启服务',
        '保存设置',
        '完成',
      ]) {
        expect(t.getSize(find.widgetWithText(RmButton, label)).height, 32);
      }
      expect(find.text('old 404 error'), findsNothing);
      expect(find.text('收起控制台'), findsOneWidget);
      expect(find.text('清空输出'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
