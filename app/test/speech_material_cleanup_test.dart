import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:fh_radio_studio/core/speech_configuration.dart';
import 'package:fh_radio_studio/screens/voices/speech_configuration_panel.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'speech_generation_test.dart' show FakeSpeech;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'preset changes show star, revert clears it and save shows confirmation',
    (t) async {
      final session = FakeSpeech();
      final c = SpeechConfiguration(session);
      addTearDown(c.dispose);
      addTearDown(session.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpeechConfigurationPanel(configuration: c),
            ),
          ),
        ),
      );
      expect(c.isDirty, false);
      c.parameter('speed_factor', 1.25);
      await t.pump();
      expect(c.isDirty, true);
      expect(
        t
            .widget<RmSelect<String>>(
              find.byKey(const ValueKey('speech-preset')),
            )
            .items['p'],
        'Alice *',
      );
      c.parameter('speed_factor', 1.0);
      expect(c.isDirty, false);
      c.update('prompt_text', 'reference');
      expect(c.isDirty, true);
      await t.pump();
      await t.tap(find.widgetWithText(RmButton, '保存预设'));
      await t.pumpAndSettle();
      expect(c.isDirty, false);
      expect(find.text('声音预设“Alice”已保存。'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'audio page blanks stay inside page instead of sounding the route barrier',
    (t) async {
      final sounds = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemSound.play') {
            sounds.add('${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      // Establish that the same transparent blank would reach the modal barrier.
      Widget route(Widget child) => MaterialApp(
        home: Navigator(
          pages: [NoTransitionPage<void>(child: child)],
          onDidRemovePage: (_) {},
        ),
      );
      await t.pumpWidget(route(const SizedBox.expand()));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(740, 540));
      await t.pump();
      expect(sounds, contains('SystemSoundType.alert'));
      sounds.clear();
      var taps = 0;
      await t.pumpWidget(
        route(
          AudioEditorHost(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 160,
                height: 40,
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('normal control'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tapAt(const Offset(740, 540));
      await t.pump();
      expect(sounds, isEmpty);
      await t.tap(find.text('normal control'));
      expect(taps, 1);
      expect(t.takeException(), isNull);
    },
  );
}
