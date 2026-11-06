import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/speech_generation.dart';
import 'package:fh_radio_studio/screens/voices/speech_generation_panel.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'speech_generation_test.dart' show FakeSpeech, MemoryWorkspace;

class PreviewSession extends FakeSpeech {
  int imports = 0;
  Completer<void>? importGate;
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (action == 'accept') {
      imports++;
      await importGate?.future;
      return {
        'plan': {
          'assets': [
            {'id': 'generated', 'name': 'test'},
          ],
        },
        'asset': {'id': 'generated'},
        'edit': {'asset_id': 'generated'},
        'target': {'bank_id': 'b', 'index': 0},
        'expected': null,
      };
    }
    return super.call(action, input);
  }

  void job(String id, String status, {int index = 0}) {
    state['jobs'] = [
      ...jobs,
      {
        'id': id,
        'status': status,
        'origin': 'replacement',
        'name': 'test',
        'text': 'test',
        'target': {'bank_id': 'b', 'index': index},
        'candidates': status == 'ready'
            ? [
                {'id': 'audio-$id', 'duration': 2.0, 'path': 'test.wav'},
              ]
            : [],
        if (status == 'failed') 'error': 'test failure',
      },
    ];
    selectPreset('p');
  }
}

Widget app(Widget child) => MaterialApp(
  theme: buildAppTheme(brightness: Brightness.light, accent: AppAccent.lime),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'material editor finds a preview by its source rather than generated text',
    (t) async {
      final session = PreviewSession();
      addTearDown(session.dispose);
      session.state['jobs'] = [
        {
          'id': 'material-job',
          'status': 'ready',
          'origin': 'replacement',
          'source_entry_name': 'existing material',
          'name': 'generated words',
          'text': 'generated words',
          'candidates': [
            {'id': 'material-candidate', 'duration': 2.0, 'path': 'test.wav'},
          ],
        },
      ];
      await t.pumpWidget(
        app(
          SpeechGenerationPanel(
            session: session,
            entries: [
              {'name': 'existing material', 'text': 'generated words'},
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-preview-material-candidate')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'historical previews preserve edits without automatically adopting old results',
    (t) async {
      t.view.physicalSize = const Size(1250, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = PreviewSession();
      addTearDown(session.dispose);
      final workspace = MemoryWorkspace()
        ..view = {
          'assets': <Map<String, dynamic>>[],
          'edits': {'b': {}},
          'saved': {'b': {}},
          'undo': <dynamic>[],
          'redo': <dynamic>[],
        };
      session.receive = (data) => workspace.acceptGeneration('unused', data);
      Widget page() => app(
        SpeechGenerationPanel(
          session: session,
          entries: [
            {
              'name': 'test',
              'content': 'hello',
              'target': {'bank_id': 'b', 'index': 0},
            },
          ],
          targetSnapshot: (target) => {
            ...target,
            'expected': speechMap(
              speechMap(workspace.view!['edits'])['b'],
            )['0'],
          },
          onUnapply: (target, _) async {
            speechMap(workspace.view!['edits'])['b'].remove('0');
          },
        ),
      );
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      session.job('one', 'ready');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-preview-audio-one')),
        findsOneWidget,
      );
      final duration = t.getRect(
        find.byKey(const ValueKey('material-silence-ms')),
      );
      final insertRect = t.getRect(
        find.byKey(const ValueKey('material-insert-silence')),
      );
      final silenceRect = t.getRect(
        find.byKey(const ValueKey('material-silence-selection')),
      );
      final deleteRect = t.getRect(
        find.byKey(const ValueKey('material-delete-selection')),
      );
      expect(duration.width, closeTo(insertRect.width, .01));
      expect(duration.left, closeTo(silenceRect.left, .01));
      expect(duration.right, closeTo(silenceRect.right, .01));
      expect(insertRect.left, closeTo(deleteRect.left, .01));
      expect(insertRect.right, closeTo(deleteRect.right, .01));
      for (final rect in [duration, insertRect, silenceRect, deleteRect]) {
        expect(rect.height, 32);
      }
      expect(find.widgetWithText(RmButton, '默认'), findsNothing);
      await t.tap(find.byKey(const ValueKey('material-insert-silence')));
      await t.pumpAndSettle();
      final draft = session.composerDrafts.values.firstWhere(
        (v) => v['candidate_id'] == 'audio-one',
      );
      expect(draft['edit']['audio_edits'], hasLength(1));
      session.job('failed', 'failed');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-preview-audio-one')),
        findsOneWidget,
      );
      expect(draft['edit']['audio_edits'], hasLength(1));
      session.job('cancelled', 'cancelled');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-preview-audio-one')),
        findsOneWidget,
      );
      expect(speechMap(speechMap(workspace.view!['edits'])['b'])['0'], {
        'asset_id': 'generated',
      });
      expect(session.imports, 1);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('speech-preview-audio-one')),
        findsOneWidget,
      );
      for (final id in ['two', 'three']) {
        session.job(id, 'ready');
        await t.pumpAndSettle();
        expect(
          find.byKey(ValueKey('speech-preview-audio-$id')),
          findsOneWidget,
        );
        expect(
          t
              .widget<RmButton>(
                find.byKey(const ValueKey('speech-preview-play')),
              )
              .onPressed,
          isNotNull,
        );
      }
      expect(speechMap(speechMap(workspace.view!['edits'])['b'])['0'], {
        'asset_id': 'generated',
      });
      expect(session.imports, 1);
      expect(speechMap(speechMap(workspace.view!['edits'])['b'])['0'], {
        'asset_id': 'generated',
      });
      await t.ensureVisible(find.byKey(const ValueKey('speech-unapply')));
      await t.tap(find.byKey(const ValueKey('speech-unapply')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-empty-waveform')),
        findsOneWidget,
      );
      expect(speechMap(speechMap(workspace.view!['edits'])['b'])['0'], isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic adoption freezes destination and preserves changes during import',
    (t) async {
      t.view.physicalSize = const Size(1250, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = PreviewSession();
      addTearDown(session.dispose);
      final workspace = MemoryWorkspace()
        ..view = {
          'assets': <Map<String, dynamic>>[],
          'edits': {
            'b': {
              '0': {'asset_id': 'before'},
            },
          },
          'saved': {'b': {}},
          'undo': <dynamic>[],
          'redo': <dynamic>[],
        };
      session.receive = (data) => workspace.acceptGeneration('unused', data);
      await t.pumpWidget(
        app(
          SpeechGenerationPanel(
            session: session,
            entries: [
              {
                'name': 'test',
                'target': {'bank_id': 'b', 'index': 0},
              },
            ],
            targetSnapshot: (target) => {
              ...target,
              'expected': speechMap(
                speechMap(workspace.view!['edits'])['b'],
              )['0'],
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      session.importGate = Completer<void>();
      session.job('one', 'ready');
      final pending = session.accept(
        session.jobs.last,
        speechMap(speechMaps(session.jobs.last['candidates']).last),
        target: {
          'bank_id': 'b',
          'index': 0,
          'expected': {'asset_id': 'before'},
        },
      );
      await t.pump();
      workspace.view!['edits'] = {
        'b': {
          '0': {'asset_id': 'later'},
        },
      };
      session.importGate!.complete();
      await pending;
      await t.pumpAndSettle();
      expect(session.lastAccepted!['applied_to_target'], false);
      expect(speechMap(speechMap(workspace.view!['edits'])['b'])['0'], {
        'asset_id': 'later',
      });
      expect(workspace.writes, 0);
      expect(t.takeException(), isNull);
    },
  );
}
