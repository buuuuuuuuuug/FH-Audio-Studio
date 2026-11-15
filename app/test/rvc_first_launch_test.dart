import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/screens/voices/rvc_workbench.dart';
import 'package:fh_radio_studio/screens/voices/speech_setup_guidance.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'rvc_workbench_test.dart' show rvcSession;
import 'speech_window_flow_test.dart' show fonts, size;
import 'support/capture_output.dart';

void main() {
  setUpAll(fonts);
  testWidgets(
    'RVC and GPT initial cards share compact layout and action footer',
    (t) async {
      size(t, const Size(960, 700));
      final session = rvcSession();
      addTearDown(session.dispose);
      session.state['engine']['installed'] = false;
      final heights = <double>[];
      for (final conversion in [false, true]) {
        final frame = GlobalKey();
        var opened = false;
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: frame,
                  child: SizedBox(
                    width: 660,
                    child: SpeechSetupGuidance(
                      session: session,
                      conversion: conversion,
                      onSettings: () => opened = true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        heights.add(
          t
              .getSize(
                find.byKey(
                  ValueKey(
                    conversion ? 'rvc-setup-guidance' : 'speech-setup-guidance',
                  ),
                ),
              )
              .height,
        );
        if (conversion) {
          await t.runAsync(() async {
            final image =
                await (frame.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await captureOutputFile(
              'rvc/first-launch-card.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await t.tap(
          find.widgetWithText(
            RmButton,
            conversion ? '安装与设置 RVC 引擎' : '安装与设置推理引擎',
          ),
        );
        expect(opened, isTrue);
        expect(t.takeException(), isNull);
      }
      expect(heights[0], heights[1]);
    },
  );
  for (final brightness in Brightness.values) {
    for (final width in [480.0, 960.0, 1700.0]) {
      testWidgets('RVC first launch guides setup at $width $brightness', (
        t,
      ) async {
        size(t, Size(width, width == 480 ? 560 : 900));
        final session = rvcSession();
        addTearDown(session.dispose);
        session.state['engine']['installed'] = false;
        final frame = GlobalKey();
        var switched = false;
        await t.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(
                brightness: brightness,
                accent: AppAccent.lime,
              ),
              home: Scaffold(
                body: RvcWorkbench(
                  session: session,
                  onTextMode: () => switched = true,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final card = find.byKey(const ValueKey('rvc-setup-guidance'));
        expect(card, findsOneWidget);
        expect(find.text('先安装 RVC 推理引擎'), findsOneWidget);
        expect(find.text('转换参数'), findsNothing);
        expect(find.text('源音频'), findsNothing);
        expect(t.getRect(card).center.dx, closeTo(width / 2, 1));
        final button = find.widgetWithText(RmButton, '安装与设置 RVC 引擎');
        expect(t.getRect(button).right, closeTo(t.getRect(card).right - 17, 2));
        if (width >= 960) {
          await t.runAsync(() async {
            final image =
                await (frame.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await captureOutputFile(
              'rvc/first-launch-${brightness.name}-$width.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await t.tap(button);
        await t.pumpAndSettle();
        expect(find.text('安装与设置 RVC 引擎'), findsNWidgets(2));
        await t.tap(find.widgetWithText(RmButton, '完成'));
        await t.pumpAndSettle();
        // Installation completing reveals both halves without requiring a model.
        session.state['engine']['installed'] = true;
        session.state['engine']['selection'] = <String, dynamic>{};
        session.state['engine']['files'] = <Map<String, dynamic>>[];
        session.notifyListeners();
        await t.pumpAndSettle();
        expect(card, findsNothing);
        expect(find.text('转换参数'), findsOneWidget);
        expect(find.text('源音频'), findsOneWidget);
        expect(session.state['inputs'], isNotEmpty);
        // An explicit uninstall restores the initial guidance without deleting drafts.
        session.state['engine']['installed'] = false;
        session.notifyListeners();
        await t.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(session.state['inputs'], isNotEmpty);
        await t.tap(find.byKey(const ValueKey('speech-mode-switch')));
        expect(switched, isTrue);
        expect(t.takeException(), isNull);
      });
    }
  }
}
