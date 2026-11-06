import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'speech_preview_workflow_test.dart' show app;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final metadata in [true, false]) {
    testWidgets(
      'material and replacement use the same editor without synthesis: $metadata',
      (t) async {
        t.view.physicalSize = const Size(1500, 950);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          app(
            VoiceClipEditor(
              asset: {
                'id': 'a',
                'name': '素材',
                'duration': 2.0,
                'category': '未分类',
              },
              folders: const ['未分类'],
              metadata: metadata,
              empty: true,
              load: () async => {},
            ),
          ),
        );
        await t.pump();
        expect(find.text('语音素材'), findsOneWidget);
        expect(find.text('素材名称'), findsOneWidget);
        expect(find.text('所在文件夹'), findsOneWidget);
        expect(find.text('生成语音'), findsNothing);
        expect(find.text('声音预设'), findsNothing);
        expect(find.text('保持原时长'), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
}
