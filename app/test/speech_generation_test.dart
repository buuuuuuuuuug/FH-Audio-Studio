import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/core/speech_configuration.dart';
import 'package:fh_radio_studio/screens/speech_studio.dart';
import 'package:fh_radio_studio/screens/voices/speech_configuration_panel.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_number_field.dart';

class FakeSpeech extends SpeechGenerationSession {
  FakeSpeech() : super(FhRadioStudioCli(repoRoot: 'D:/unused'), 'D:/unused') {
    state = {
      'engine': {
        'installed': true,
        'api': {'state': 'ready', 'ready': true},
        'presets': [
          {
            'id': 'p',
            'name': 'Alice',
            'version': 'v2ProPlus',
            'parameters': {'speed_factor': 1.0},
            'gpt_model': 'models/test.ckpt',
            'sovits_model': 'models/test.pth',
            'ref_audio_path': 'references/test.wav',
          },
        ],
      },
      'jobs': [],
    };
  }
  Map<String, dynamic>? submitted, saved;
  @override
  Future<void> start() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (action == 'submit') submitted = input;
    if (action == 'candidate-audio') {
      final operations = input['edit']?['audio_edits'] as List? ?? [];
      return {
        'duration': 2.0 + operations.length * .1,
        'bins': List.filled(256, .5),
        'path': 'test.wav',
      };
    }
    if (action == 'save-preset') {
      saved = input;
      state['engine']['presets'] = [input];
    }
    return state;
  }
}

class MemoryWorkspace extends VoiceWorkspaceSession {
  int writes = 0;
  @override
  Future<void> writeDraft(
    String project,
    Map<String, dynamic> edits,
    Map<String, dynamic> saved,
  ) async {
    writes++;
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'accepted results preserve changes made while inference was running',
    () async {
      final w = MemoryWorkspace();
      w.view = {
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
      final result = <String, dynamic>{
        'plan': {
          'assets': [
            {
              'id': 'generated',
              'generation': {'job_id': 'j'},
            },
          ],
        },
        'asset': {
          'id': 'generated',
          'generation': {'job_id': 'j'},
        },
        'target': {'bank_id': 'b', 'index': 0},
        'expected': null,
        'edit': {'asset_id': 'generated'},
      };
      await w.acceptGeneration('unused', result);
      expect(result['applied_to_target'], false);
      expect(speechMap(speechMap(w.view!['edits'])['b'])['0'], {
        'asset_id': 'manual',
      });
      expect(speechMaps(w.view!['assets']).single['id'], 'generated');
      expect(w.writes, 0);
    },
  );
  test(
    'same-job candidate changes are undoable without changing saved mappings',
    () async {
      final w = MemoryWorkspace();
      w.view = {
        'assets': <Map<String, dynamic>>[],
        'edits': {'b': {}},
        'saved': {'b': {}},
        'undo': <dynamic>[],
        'redo': <dynamic>[],
      };
      for (final id in ['one', 'two']) {
        await w.acceptGeneration('unused', {
          'plan': {
            'assets': [
              {
                'id': id,
                'generation': {'job_id': 'j'},
              },
            ],
          },
          'asset': {
            'id': id,
            'generation': {'job_id': 'j'},
          },
          'target': {'bank_id': 'b', 'index': 0},
          'expected': null,
          'edit': {'asset_id': id},
          'previous_edit': id == 'two' ? {'asset_id': 'one'} : null,
        });
      }
      expect(w.writes, 2);
      expect(speechMap(speechMap(w.view!['edits'])['b'])['0'], {
        'asset_id': 'two',
      });
      expect(w.view!['saved'], {'b': {}});
      expect(w.view!['undo'], hasLength(2));
    },
  );
  for (final width in [280.0, 360.0, 520.0, 960.0]) {
    testWidgets('generation panel fits $width and submits edited text', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = FakeSpeech();
      addTearDown(session.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SpeechGenerationPanel(
                session: session,
                entries: [
                  {
                    'name':
                        'Very long resource filename and original voice entry name that must fit',
                    'text': '元の文章',
                    'language': 'all_ja',
                  },
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.enterText(find.byKey(const ValueKey('speech-text')), '新しい文章');
      await t.tap(find.byKey(const ValueKey('speech-generate')));
      await t.pumpAndSettle();
      expect(speechMaps(session.submitted?['entries']).single['text'], '新しい文章');
      expect(session.submitted?['auto_apply'], false);
      expect(session.submitted?['count'], 1);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('batch generation skips existing replacements by default', (
    t,
  ) async {
    t.view.physicalSize = const Size(960, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final session = FakeSpeech();
    addTearDown(session.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpeechGenerationPanel(
              session: session,
              entries: [
                {
                  'text': 'one',
                  'target': {'bank_id': 'b', 'index': 0, 'expected': null},
                },
                {
                  'text': 'two',
                  'target': {
                    'bank_id': 'b',
                    'index': 1,
                    'expected': {'asset_id': 'existing'},
                  },
                },
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('speech-generate')));
    await t.pumpAndSettle();
    expect(session.submitted?['auto_apply'], false);
    final entries = speechMaps(session.submitted?['entries']);
    expect(entries, hasLength(1));
    expect(entries.single['text'], 'one');
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'editor generation uses saved preset without duplicating parameters',
    (t) async {
      final session = FakeSpeech();
      addTearDown(session.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpeechGenerationPanel(
                session: session,
                entries: [
                  {'name': 'Test', 'text': 'hello'},
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('参数'), findsNothing);
      expect(find.text('声音与引擎'), findsNothing);
      expect(find.text('批量文本'), findsNothing);
      expect(find.text('原音作参考'), findsNothing);
      expect(find.text('模型设置'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('speech-generate')));
      await t.pumpAndSettle();
      expect(session.submitted?['preset_id'], 'p');
      expect(session.submitted?['original_reference'], isNull);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('number controls clamp and accept arrow keys', (t) async {
    final field = TextEditingController(text: '2.98');
    addTearDown(field.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 180,
            height: 36,
            child: RmNumberField(controller: field, min: .1, max: 3, step: .05),
          ),
        ),
      ),
    );
    await t.tap(find.byType(InkWell).first);
    expect(field.text, '3.00');
    await t.tap(find.byType(TextField));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(field.text, '2.95');
  });
  testWidgets('trial text survives switching to configuration and back', (
    t,
  ) async {
    final session = FakeSpeech();
    addTearDown(session.dispose);
    Widget page() => MaterialApp(
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpeechGenerationPanel(
            session: session,
            entries: [
              {'name': 'trial', 'text': ''},
            ],
          ),
        ),
      ),
    );
    await t.pumpWidget(page());
    await t.enterText(
      find.byKey(const ValueKey('speech-text')),
      'keep this draft',
    );
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(page());
    await t.pumpAndSettle();
    expect(find.text('keep this draft'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test(
    'working settings survive navigation and save the current values',
    () async {
      final session = FakeSpeech();
      final configuration = SpeechConfiguration(session);
      configuration.parameter('speed_factor', 1.25);
      configuration.update('prompt_text', 'reference text');
      await configuration.save('Alice');
      expect(session.saved?['prompt_text'], 'reference text');
      expect(speechMap(session.saved?['parameters'])['speed_factor'], 1.25);
      configuration.dispose();
      final reopened = SpeechConfiguration(session);
      expect(reopened.parameters['speed_factor'], 1.25);
      reopened.dispose();
      session.dispose();
    },
  );
  for (final width in [700.0, 860.0, 1200.0, 1600.0]) {
    testWidgets(
      'studio inline layout at $width and generation uses working config',
      (t) async {
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final session = FakeSpeech();
        addTearDown(session.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(body: SpeechStudioWorkbench(session: session)),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        // Model pickers are selectors, never editable path text fields.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('speech-gpt_model')),
            matching: find.byType(TextField),
          ),
          findsNothing,
        );
        expect(find.textContaining('GAG'), findsNothing);
        final panel = t.widget<SpeechConfigurationPanel>(
          find.byType(SpeechConfigurationPanel),
        );
        panel.configuration.parameter('speed_factor', 1.45);
        final count = find.byKey(const ValueKey('speech-count'));
        await t.tap(
          find.descendant(of: count, matching: find.byType(InkWell)).first,
        );
        await t.enterText(
          find.byKey(const ValueKey('speech-studio-text')),
          '生成する文章',
        );
        await t.tap(find.byKey(const ValueKey('speech-studio-generate')));
        await t.pumpAndSettle();
        expect(session.submitted?['count'], 2);
        expect(
          speechMap(
            speechMap(session.submitted?['config'])['parameters'],
          )['speed_factor'],
          1.45,
        );
        expect(session.submitted?['origin'], 'studio');
        expect(session.submitted?['auto_apply'], false);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('new audio expands inline, previous audio folds and keeps edits', (
    t,
  ) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final session = FakeSpeech();
    addTearDown(session.dispose);
    Map<String, dynamic> job(String id) => {
      'id': id,
      'status': 'ready',
      'origin': 'studio',
      'name': id,
      'preset': {'name': 'Alice'},
      'candidates': [
        {'id': id, 'path': 'test.wav', 'duration': 2.0, 'seed': 1},
      ],
    };
    session.state['jobs'] = [job('first')];
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(body: SpeechStudioWorkbench(session: session)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(VoiceClipEditor), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await t.tap(find.byKey(const ValueKey('material-insert-silence')));
    await t.pumpAndSettle();
    session.state['jobs'] = [job('first'), job('second')];
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    session.notifyListeners();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('speech-inline-second')), findsOneWidget);
    expect(find.byKey(const ValueKey('speech-inline-first')), findsNothing);
    await t.tap(find.text('first').first);
    await t.pumpAndSettle();
    final editor = t.widget<VoiceClipEditor>(find.byType(VoiceClipEditor));
    expect(editor.initial?['audio_edits'], hasLength(1));
    expect(t.takeException(), isNull);
  });
}
