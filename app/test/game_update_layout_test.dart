import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_preview_workflow_test.dart' show app;
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;
import 'speech_window_flow_test.dart' show fonts;

void main() {
  setUpAll(fonts);
  for (final width in [760.0, 1400.0]) {
    testWidgets('generation editing layout remains fixed at $width', (t) async {
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = FakeSpeech();
      addTearDown(session.dispose);
      final frame = GlobalKey();
      await t.pumpWidget(
        app(
          RepaintBoundary(
            key: frame,
            child: Container(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SpeechGenerationPanel(
                  session: session,
                  entries: [
                    for (var i = 0; i < 3; i++)
                      {
                        'name': '语音条目 $i',
                        'content': '次の曲をお楽しみください。',
                        'target': {'bank_id': 'b', 'index': i},
                      },
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('speech-apply-preview')), findsNothing);
      expect(find.text('播放原音'), findsNothing);
      expect(find.text('1. 语音条目 0'), findsNothing);
      expect(
        t
            .widget<RmNumberField>(
              find.byKey(const ValueKey('material-silence-ms')),
            )
            .enabled,
        false,
      );
      final emptyHeight = t.getSize(find.byType(VoiceClipEditor)).height;
      session.state['jobs'] = [
        {
          'id': 'j',
          'status': 'ready',
          'origin': 'replacement',
          'text': '次の曲をお楽しみください。',
          'target': {'bank_id': 'b', 'index': 0},
          'candidates': [
            {'id': 'c', 'duration': 2.0},
          ],
        },
      ];
      session.notifyListeners();
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byType(VoiceClipEditor)).height,
        closeTo(emptyHeight, 1),
      );
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (frame.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'D:/FH6_Music/outputs/gpt-sovits/revision-20261105-game-update/generation-$width.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
    testWidgets('multiselect keeps one toolbar and no extraction at $width', (
      t,
    ) async {
      await base.open(
        t,
        Size(width, 900),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await t.tap(find.byKey(const ValueKey('voice-export-text')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-extract-assets')), findsNothing);
      expect(find.byType(Checkbox).first, findsOneWidget);
      expect(
        find.byKey(const ValueKey('voice-export-selected-text')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }
}
