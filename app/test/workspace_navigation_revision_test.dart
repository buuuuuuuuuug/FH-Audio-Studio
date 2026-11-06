import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/speech_configuration_panel.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/shell/nav_item.dart';
import 'package:fh_radio_studio/widgets/rm_icon.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'studio_v18_workflow_test.dart' as fixtures;
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'sidebar follows drag and toggles between restored width and icons',
    (t) async {
      final container = await fixtures.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: Row(
                children: [
                  Sidebar(activeId: 'voices'),
                  Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.drag(
        find.byKey(const ValueKey('sidebar-resizer')),
        const Offset(80, 0),
      );
      await t.pumpAndSettle();
      expect(container.read(sidebarLayoutProvider), closeTo(300, 1));
      await t.drag(
        find.byKey(const ValueKey('sidebar-resizer')),
        const Offset(-200, 0),
      );
      await t.pumpAndSettle();
      expect(container.read(sidebarLayoutProvider), 56);
      expect(find.text('自建歌曲'), findsNothing);
      await t.drag(
        find.byKey(const ValueKey('sidebar-resizer')),
        const Offset(244, 0),
      );
      await t.pumpAndSettle();
      expect(container.read(sidebarLayoutProvider), closeTo(300, 1));
      expect(find.text('自建歌曲'), findsOneWidget);
      final station = find.byWidgetPredicate(
        (w) => w is NavItem && w.spec.id == 'stingers',
      );
      final icon = find
          .descendant(of: station, matching: find.byType(RmIcon))
          .first;
      final initialY = t.getCenter(icon).dy;
      await t.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 90));
      expect(t.getCenter(icon).dy, closeTo(initialY, .1));
      await t.pumpAndSettle();
      expect(t.getCenter(icon).dy, closeTo(initialY, .1));
      await t.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await t.pumpAndSettle();
      expect(container.read(sidebarLayoutProvider), closeTo(300, 1));
      expect(t.getCenter(icon).dy, closeTo(initialY, .1));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'generation remains mounted with empty multi-selection and both panes fold',
    (t) async {
      final parent = await fixtures.fixture();
      final speech = FakeSpeech();
      final c = ProviderContainer(
        parent: parent,
        overrides: [
          speechGenerationProvider.overrideWith((ref, key) => speech),
        ],
      );
      addTearDown(c.dispose);
      c.read(editorOptionsProvider.notifier).update(speechEnabled: true);
      final snapshot = data.scan();
      await base.open(
        t,
        const Size(1700, 1000),
        [],
        container: c,
        responder: (action, input) async => action == 'scan' ? snapshot : {},
      );
      expect(
        t
            .widget<RmSelect<String>>(
              find.byKey(const ValueKey('voice-pool-sort')),
            )
            .value,
        'added',
      );
      await t.tap(find.byKey(const ValueKey('voice-open-generation')));
      await t.pumpAndSettle();
      final state = t.state(find.byType(SpeechGenerationPanel));
      final originalTop = t
          .getTopLeft(find.byKey(const ValueKey('speech-generate')))
          .dy;
      await t.tap(find.byKey(const ValueKey('voice-export-text')));
      await t.pumpAndSettle();
      expect(t.state(find.byType(SpeechGenerationPanel)), same(state));
      expect(
        t.getTopLeft(find.byKey(const ValueKey('speech-generate'))).dy,
        originalTop,
      );
      final empty = t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor));
      expect(empty.empty, true);
      expect(
        find.byKey(const ValueKey('voice-empty-waveform')),
        findsOneWidget,
      );
      expect(
        t
            .widget<RmNumberField>(
              find.byKey(const ValueKey('material-silence-ms')),
            )
            .enabled,
        false,
      );
      expect(
        t
            .widget<RmButton>(
              find.byKey(const ValueKey('material-insert-silence')),
            )
            .onPressed,
        isNull,
      );
      await t.tap(find.byKey(const ValueKey('voice-collapse-resources')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-resources-collapsed')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('voice-expand-resources')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('voice-collapse-pool')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-pool-collapsed')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('voice-expand-pool')));
      await t.pumpAndSettle();
      final before = t
          .getSize(find.byKey(const ValueKey('voice-workbench-tools')))
          .width;
      await t.drag(
        find.byKey(const ValueKey('voice-right-divider')),
        const Offset(240, 0),
      );
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byKey(const ValueKey('voice-pool-collapsed'))).width,
        36,
      );
      expect(
        t.getSize(find.byKey(const ValueKey('voice-workbench-tools'))).width,
        greaterThan(before),
      );
      await t.drag(
        find.byKey(const ValueKey('voice-right-divider')),
        const Offset(-240, 0),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-pool-sort')), findsOneWidget);
      await t.drag(
        find.byKey(const ValueKey('voice-left-divider')),
        const Offset(-220, 0),
      );
      await t.pumpAndSettle();
      expect(
        t
            .getSize(find.byKey(const ValueKey('voice-resources-collapsed')))
            .width,
        36,
      );
      await t.drag(
        find.byKey(const ValueKey('voice-left-divider')),
        const Offset(220, 0),
      );
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-resources-collapsed')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('model settings are removed with the owning page', (t) async {
    final speech = FakeSpeech();
    addTearDown(speech.dispose);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: Row(
            children: [
              TextButton(
                onPressed: () => active.value = false,
                child: const Text('Other page'),
              ),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, current, _) => current
                      ? AudioEditorHost(
                          child: Builder(
                            builder: (context) => TextButton(
                              onPressed: () => showSpeechConfigurationDialog(
                                context,
                                speech,
                              ),
                              child: const Text('Models'),
                            ),
                          ),
                        )
                      : const Text('New page'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('Models'));
    await t.pumpAndSettle();
    expect(find.text('声音与模型设置'), findsOneWidget);
    await t.tap(find.text('Other page'));
    await t.pumpAndSettle();
    expect(find.text('声音与模型设置'), findsNothing);
    expect(find.text('New page'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'replacement generation directs incomplete setup to the speech page',
    (t) async {
      final parent = await fixtures.fixture();
      final speech = FakeSpeech();
      speech.state['engine']['installed'] = false;
      speech.state['engine']['presets'] = [];
      addTearDown(speech.dispose);
      final c = ProviderContainer(
        parent: parent,
        overrides: [
          speechGenerationProvider.overrideWith((ref, key) => speech),
        ],
      );
      addTearDown(c.dispose);
      c.read(editorOptionsProvider.notifier).update(speechEnabled: true);
      await base.open(
        t,
        const Size(1700, 1000),
        [],
        container: c,
        responder: (action, input) async => action == 'scan' ? data.scan() : {},
      );
      await t.tap(find.byKey(const ValueKey('voice-open-generation')));
      await t.pumpAndSettle();
      expect(find.text('请先配置语音生成'), findsOneWidget);
      expect(find.widgetWithText(RmButton, '前往语音生成'), findsOneWidget);
      expect(find.byType(SpeechGenerationPanel), findsNothing);
      await t.tap(find.text('暂不设置'));
      await t.pumpAndSettle();
      expect(find.text('请先配置语音生成'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
