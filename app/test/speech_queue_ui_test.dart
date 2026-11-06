import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_status.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/shell/nav_item.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_install_interaction_test.dart' show InstallSpeech;
import 'speech_window_flow_test.dart' show fonts, size, theme;

class RecordingSpeech extends FakeSpeech {
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) {
    actions.add(action);
    return super.call(action, input);
  }
}

Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      'D:/FH6_Music/outputs/gpt-sovits/revision-20261104-generation-queue/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(fonts);
  testWidgets(
    'compact active navigation does not overlay its icon with an accent bar',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 44,
                child: NavItem(
                  spec: kNavItems.first,
                  active: true,
                  compact: true,
                  trailing: SizedBox(
                    width: 20,
                    child: RmButton(label: '›', onPressed: () {}),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Positioned), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('completed installation no longer displays a progress card', (
    t,
  ) async {
    size(t, const Size(1400, 1000));
    final session = InstallSpeech();
    addTearDown(session.dispose);
    session.state['engine']['installed'] = true;
    session.state['jobs'] = [
      {
        'id': 'install',
        'kind': 'install',
        'status': 'ready',
        'installation': {'completed': 15, 'total': 15, 'fraction': 1.0},
      },
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => RmButton(
              label: 'open',
              onPressed: () => showSpeechEngineDialog(context, session),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('speech-install-progress')), findsNothing);
    expect(find.text('组件已就绪；启动服务只需 GPT / SoVITS 模型，参考音频用于生成。'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('empty preview disables both silence input and insert button', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: VoiceClipEditor(
            empty: true,
            replacementInline: true,
            asset: const {'id': '', 'duration': 0},
            folders: const [],
            load: () async => {},
            render: (_) async => {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
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
    expect(t.takeException(), isNull);
  });

  for (final width in [780.0, 1400.0]) {
    testWidgets('studio action and shared status align at $width', (t) async {
      size(t, Size(width, 1050));
      final session = RecordingSpeech();
      addTearDown(session.dispose);
      final frame = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: RepaintBoundary(
              key: frame,
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: SpeechStudioWorkbench(session: session),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final generate = find.byKey(const ValueKey('speech-studio-generate'));
      final count = find.byKey(const ValueKey('speech-count'));
      expect(t.getTopLeft(generate).dx, lessThan(t.getTopLeft(count).dx));
      expect(find.byType(SpeechGenerationStatus), findsOneWidget);
      final directory = find.byKey(
        const ValueKey('speech-open-engine-directory'),
      );
      await t.tap(directory);
      expect(session.actions, contains('open-install-directory'));
      await capture(t, frame, 'studio-$width');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('replacement generation stop control keeps a full 32px target', (
    t,
  ) async {
    size(t, const Size(1100, 700));
    final session = FakeSpeech();
    addTearDown(session.dispose);
    session.state['jobs'] = [
      {
        'id': 'new',
        'status': 'running',
        'origin': 'replacement',
        'target': {'bank_id': 'b', 'index': 0},
        'progress': '生成音频 1/1',
        'candidates': [],
      },
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpeechGenerationPanel(
              session: session,
              entries: const [
                {
                  'name': 'test',
                  'text': 'test',
                  'target': {'bank_id': 'b', 'index': 0},
                },
              ],
            ),
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    final status = find.byType(SpeechGenerationStatus);
    final stop = find.descendant(of: status, matching: find.byType(RmButton));
    expect(t.getSize(stop).height, 32);
    expect(t.getSize(stop).width, 32);
    expect(t.takeException(), isNull);
  });
}
