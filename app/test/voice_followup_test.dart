import 'package:flutter/material.dart';
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
  testWidgets(
    'unapply and pool removal clear only matching previews across rebuilds',
    (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = FakeSpeech();
      addTearDown(s.dispose);
      void ready(String id, String asset) {
        s.state['jobs'] = [
          ...s.jobs,
          {
            'id': id,
            'status': 'ready',
            'origin': 'replacement',
            'asset_id': asset,
            'target': {'bank_id': 'b', 'index': 0},
            'candidates': [
              {'id': id, 'duration': 2.0},
            ],
          },
        ];
        s.notifyListeners();
      }

      ready('one', 'a');
      Widget page() => app(
        SpeechGenerationPanel(
          session: s,
          entries: [
            {
              'name': 'test',
              'content': 'hello',
              'target': {'bank_id': 'b', 'index': 0},
            },
          ],
          onUnapply: (_, _) async {},
        ),
      );
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('speech-preview-one')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('speech-unapply')));
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      s.notifyListeners();
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      ready('two', 'b-asset');
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        false,
      );
      s.dismissPreviews(assetIds: {'b-asset'});
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      expect(
        t
            .widget<RmNumberField>(
              find.byKey(const ValueKey('material-silence-ms')),
            )
            .enabled,
        false,
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      ready('three', 'c');
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        false,
      );
      expect(find.text('恢复原音'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  for (final width in [1000.0, 1600.0]) {
    testWidgets(
      'selection actions stay with title and toolbar aligns at $width',
      (t) async {
        await base.open(
          t,
          Size(width, 900),
          [],
          responder: (a, o) async => a == 'scan' ? data.scan() : {},
        );
        await t.tap(find.byKey(const ValueKey('voice-export-text')));
        await t.pumpAndSettle();
        final toggle = t.getCenter(
          find.byKey(const ValueKey('voice-export-text')),
        );
        final export = t.getCenter(
          find.byKey(const ValueKey('voice-export-selected-text')),
        );
        expect(export.dy, closeTo(toggle.dy, 1));
        expect(
          t
              .getBottomRight(
                find.byKey(const ValueKey('voice-export-selected-text')),
              )
              .dx,
          lessThanOrEqualTo(
            t
                .getBottomRight(
                  find.byKey(const ValueKey('voice-workbench-tools')),
                )
                .dx,
          ),
        );
        final search = t.getCenter(
          find.byKey(const ValueKey('voice-entry-filter')),
        );
        final remove = t.getCenter(
          find.byKey(const ValueKey('voice-forget-audio')),
        );
        expect(search.dy, closeTo(remove.dy, 1));
        expect(find.text('清除替换'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
}
