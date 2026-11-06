import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'speech_generation_test.dart' show FakeSpeech, MemoryWorkspace;
import 'speech_preview_workflow_test.dart' show app;

class AutomaticSpeech extends FakeSpeech {
  int accepted = 0;
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (action == 'submit') {
      submitted = input;
      state['jobs'] = [
        ...jobs,
        {
          'id': 'new',
          'origin': 'replacement',
          'status': 'ready',
          'target': input['entries'][0]['target'],
          'candidates': [
            {'id': 'new-audio', 'duration': 2.0},
          ],
        },
      ];
    }
    if (action == 'accept') {
      accepted++;
      return {
        'asset': {'id': 'new-asset'},
        'edit': {'asset_id': 'new-asset'},
      };
    }
    return super.call(action, input);
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'only newly submitted generation automatically adopts with frozen target',
    () async {
      final s = AutomaticSpeech();
      addTearDown(s.dispose);
      final w = MemoryWorkspace()
        ..view = {
          'assets': <Map<String, dynamic>>[],
          'edits': {'b': {}},
          'saved': {'b': {}},
          'undo': <dynamic>[],
          'redo': <dynamic>[],
        };
      s.receive = (data) => w.acceptGeneration('unused', data);
      await s.generateReplacement({
        'origin': 'replacement',
        'entries': [
          {
            'text': 'test',
            'target': {'bank_id': 'b', 'index': 0, 'expected': null},
          },
        ],
      });
      expect(s.accepted, 1);
      expect(
        speechMap(speechMap(w.view!['edits'])['b'])['0']['asset_id'],
        'new-asset',
      );
    },
  );

  test(
    'automatic adoption preserves an intervening user replacement',
    () async {
      final s = AutomaticSpeech();
      addTearDown(s.dispose);
      final w = MemoryWorkspace()
        ..view = {
          'assets': <Map<String, dynamic>>[],
          'edits': {
            'b': {
              '0': {'asset_id': 'manual'},
            },
          },
          'saved': {'b': {}},
          'undo': <dynamic>[],
          'redo': <dynamic>[],
        };
      s.receive = (data) => w.acceptGeneration('unused', data);
      await s.generateReplacement({
        'origin': 'replacement',
        'entries': [
          {
            'text': 'test',
            'target': {'bank_id': 'b', 'index': 0, 'expected': null},
          },
        ],
      });
      expect(
        speechMap(speechMap(w.view!['edits'])['b'])['0']['asset_id'],
        'manual',
      );
      expect(s.lastAccepted!['applied_to_target'], false);
    },
  );

  testWidgets(
    'selected preset survives closing and reopening the generation panel',
    (t) async {
      final s = FakeSpeech();
      addTearDown(s.dispose);
      s.state['engine']['presets'] = [
        ...s.presets,
        {...s.presets.first, 'id': 'second', 'name': 'Other'},
      ];
      s.selectPreset('second');
      Widget page() => app(
        SpeechGenerationPanel(
          session: s,
          entries: [
            {'name': 'test'},
          ],
        ),
      );
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(
        t
            .widget<RmSelect<String>>(
              find.byKey(const ValueKey('speech-use-preset')),
            )
            .value,
        'second',
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(
        t
            .widget<RmSelect<String>>(
              find.byKey(const ValueKey('speech-use-preset')),
            )
            .value,
        'second',
      );
    },
  );

  testWidgets(
    'language refresh updates current text while retaining per-language edits',
    (t) async {
      final s = FakeSpeech();
      addTearDown(s.dispose);
      Widget page(String display, String text) => app(
        SpeechGenerationPanel(
          session: s,
          entries: [
            {
              'name': 'entry',
              'content': '日本語',
              'language': 'all_ja',
              'translation': text,
              'display_language': display,
              'target': {'bank_id': 'b', 'index': 0},
            },
          ],
        ),
      );
      await t.pumpWidget(page('all_zh', '中文'));
      await t.pumpAndSettle();
      await t.tap(find.text('语音语言'));
      await t.pumpAndSettle();
      expect(find.text('中文'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('speech-text')), '自定义中文');
      await t.pumpWidget(page('all_ja', '表示日本語'));
      await t.pumpAndSettle();
      expect(find.text('表示日本語'), findsOneWidget);
      await t.pumpWidget(page('all_zh', '中文'));
      await t.pumpAndSettle();
      expect(find.text('自定义中文'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'preview space is stable and hides old waveform during generation',
    (t) async {
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = FakeSpeech();
      addTearDown(s.dispose);
      await t.pumpWidget(
        app(
          SpeechGenerationPanel(
            session: s,
            entries: [
              {
                'name': 'entry',
                'target': {'bank_id': 'b', 'index': 0},
              },
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      final emptyHeight = t.getSize(find.byType(VoiceClipEditor)).height;
      s.state['jobs'] = [
        {
          'id': 'old',
          'origin': 'replacement',
          'status': 'ready',
          'target': {'bank_id': 'b', 'index': 0},
          'text': 'test',
          'candidates': [
            {'id': 'old-audio', 'duration': 2.0},
          ],
        },
      ];
      s.selectPreset('p');
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        false,
      );
      expect(
        t.getSize(find.byType(VoiceClipEditor)).height,
        closeTo(emptyHeight, 1),
      );
      s.state['jobs'].add({
        'id': 'new',
        'origin': 'replacement',
        'status': 'running',
        'target': {'bank_id': 'b', 'index': 0},
        'candidates': [],
      });
      s.notifyListeners();
      await t.pump();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      final spinner = find.byType(CircularProgressIndicator);
      final size = t.getSize(spinner.first);
      expect(size.width, size.height);
      s.state['jobs'] = [
        s.jobs.first,
        {
          'id': 'deleted',
          'origin': 'replacement',
          'status': 'ready',
          'target': {'bank_id': 'b', 'index': 0},
          'preview_deleted': true,
          'candidates': [],
        },
      ];
      s.notifyListeners();
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        app(
          SpeechGenerationPanel(
            session: s,
            entries: [
              {
                'name': 'entry',
                'target': {'bank_id': 'b', 'index': 0},
              },
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor)).empty,
        true,
      );
      expect(t.takeException(), isNull);
    },
  );
}
