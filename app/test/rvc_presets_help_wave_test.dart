import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/speech_configuration.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_painter.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/voices/rvc_configuration.dart';
import 'package:fh_radio_studio/screens/voices/speech_configuration_panel.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/speech_parameter_help.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_chip.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';
import 'rvc_workbench_test.dart' show rvcSession;
import 'speech_generation_test.dart' show FakeSpeech;
import 'speech_window_flow_test.dart' show fonts, size, theme;
import 'support/capture_output.dart';

class PresetSpeech extends FakeSpeech {
  final actions = <String>[];
  PresetSpeech() {
    state = jsonDecode(jsonEncode(rvcSession().state));
  }
  Map<String, dynamic> config() => jsonDecode(
    jsonEncode({
      'selection': engine['selection'],
      'parameters': engine['parameters'],
      'runtime': engine['runtime'] ?? {'device': 'cpu'},
    }),
  );
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    actions.add(action);
    if (action == 'save-preset') {
      state['engine']['presets'] = [
        {'id': 'p', 'name': input['name'], 'configuration': config()},
      ];
      state['engine']['selected_preset_id'] = 'p';
    } else if (action == 'select-preset') {
      state['engine'].addAll(presets.single['configuration']);
      state['engine']['selected_preset_id'] = input['id'];
    } else if (action == 'delete-preset') {
      state['engine']['presets'] = [];
      state['engine']['selected_preset_id'] = null;
    } else if (action == 'save-parameters') {
      state['engine']['parameters'] = input;
    } else {
      return super.call(action, input);
    }
    state['engine']['preset_dirty'] =
        presets.isNotEmpty &&
        jsonEncode(config()) != jsonEncode(presets.single['configuration']);
    notifyListeners();
    return state;
  }
}

void main() {
  setUpAll(fonts);
  testWidgets(
    'RVC preset saves, marks unsaved changes, restores and deletes without removing voice',
    (t) async {
      size(t, const Size(1100, 1050));
      final s = PresetSpeech();
      addTearDown(s.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: RvcConfigurationPanel(session: s),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('rvc-save-preset')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('rvc-preset-name')), '播报音色');
      await t.tap(find.widgetWithText(RmButton, '保存预设').last);
      await t.pumpAndSettle();
      expect(find.text('RVC 预设“播报音色”已保存。'), findsOneWidget);
      final pitch = find.descendant(
        of: find.byType(RmNumberField).first,
        matching: find.byType(TextField),
      );
      await t.enterText(pitch, '4');
      await t.pumpAndSettle();
      expect(find.text('播报音色 *'), findsOneWidget);
      expect(s.presets.single['configuration']['parameters']['pitch'], 0);
      await t.tap(find.byKey(const ValueKey('rvc-preset')));
      await t.pumpAndSettle();
      await t.tap(find.text('播报音色 *').last);
      await t.pumpAndSettle();
      expect(s.actions, contains('select-preset'));
      expect(s.engine['parameters']['pitch'], 0);
      expect(t.widget<TextField>(pitch).controller!.text, '0');
      expect(find.text('播报音色 *'), findsNothing);
      await t.tap(find.byKey(const ValueKey('rvc-delete-preset')));
      await t.pumpAndSettle();
      expect(s.presets, isEmpty);
      expect(s.engine['selection']['model_id'], 'voice');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('RVC status uses a framed chip and opens its engine dialog', (
    t,
  ) async {
    size(t, const Size(1500, 1000));
    final s = rvcSession();
    addTearDown(s.dispose);
    s.state['engine']['api'] = {'ready': true, 'state': 'ready'};
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpeechGenerationPanel(
              session: s,
              conversion: true,
              entries: const [
                {
                  'text': '原音',
                  'target': {'bank_id': 'b', 'index': 0},
                },
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.widgetWithText(RmChip, 'RVC 可用'), findsOneWidget);
    await t.tap(find.text('RVC 可用'));
    await t.pumpAndSettle();
    expect(find.text('安装与设置 RVC 引擎'), findsOneWidget);
    await t.tap(find.widgetWithText(RmButton, '完成'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
  for (final gpt in [false, true]) {
    testWidgets(
      '${gpt ? 'GPT-SoVITS' : 'RVC'} parameter help appears after hover delay',
      (t) async {
        size(t, const Size(1100, 950));
        final s = gpt ? FakeSpeech() : rvcSession();
        addTearDown(s.dispose);
        final c = SpeechConfiguration(s);
        addTearDown(c.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: gpt
                    ? SpeechParameterFields(configuration: c)
                    : RvcConfigurationPanel(session: s),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final label = find.byWidgetPredicate(
          (w) => w is SpeechParameterLabel && w.label == (gpt ? '语速' : '音高提取'),
        );
        await t.ensureVisible(label);
        await t.pumpAndSettle();
        final help = gpt
            ? gptParameterHelp['speed_factor']!
            : rvcParameterHelp['f0_method']!;
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(t.getCenter(label));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text(help, findRichText: true), findsNothing);
        await t.pump(const Duration(milliseconds: 500));
        expect(find.text(help, findRichText: true), findsOneWidget);
        await mouse.removePointer();
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('song and refine backgrounds retain time guides without beats', (
    t,
  ) async {
    size(t, const Size(900, 700));
    final bars = WaveformBars.fromValues(List.filled(100, 0));
    late RmTheme rm;
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              rm = context.rm;
              return SizedBox(
                width: 600,
                child: ManualFocusWaveform(
                  bars: bars,
                  beats: const [],
                  segments: const [],
                  duration: 10,
                  accent: rm.accent.base,
                  handles: const [],
                  free: false,
                  locked: false,
                  onPlace: (_, {required isMove}) {},
                ),
              );
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final focus = t
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(ManualFocusWaveform),
            matching: find.byType(CustomPaint),
          ),
        )
        .firstWhere((w) => w.painter != null)
        .painter!;
    final main = WaveformPainter(
      rm: rm,
      bars: bars,
      beats: const [],
      segments: const [],
      duration: 10,
      markers: const [],
      tlLoop: null,
      plLoop: null,
      playhead: -1,
    );
    for (final item in [('song', main), ('refine', focus)]) {
      await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        // Use one canvas/recorder pair for the actual raster, at exact grid coordinates.
        final painterCanvas = Canvas(recorder)
          ..drawColor(Colors.white, BlendMode.src);
        item.$2.paint(painterCanvas, const Size(600, 178));
        final picture = recorder.endRecording();
        final image = await picture.toImage(600, 178);
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(
          rgba.getUint8((40 * 600 + 30) * 4),
          lessThan(rgba.getUint8((40 * 600 + 33) * 4)),
        );
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await captureOutputFile(
          'rvc/presets-20261114/${item.$1}-background.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
    }
  });
}
