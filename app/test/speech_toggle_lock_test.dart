import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/speech_experiment_setting.dart';
import 'speech_window_flow_test.dart' show fonts, theme;

class LockedStudio extends StudioController {
  LockedStudio(
    super.prefs,
    String project, {
    required bool hasProject,
    bool busy = false,
  }) {
    state = state.copyWith(
      projectDir: project,
      hasProject: hasProject,
      busy: busy,
      fileIntegrity: GameFileIntegritySummary.notChecked(),
    );
  }
  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}

void main() {
  setUpAll(fonts);
  for (final busy in [false, true]) {
    testWidgets(
      'speech toggle remains interactive without backup ${busy ? 'during project work' : 'and without ready tools'}',
      (t) async {
        final dir = Directory.systemTemp.createTempSync(
          'speech-toggle-locked-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        FhRadioStudioProject.ensure(dir.path);
        SharedPreferences.setMockInitialValues({
          'rm.studio.projectDir': dir.path,
        });
        final prefs = await SharedPreferences.getInstance();
        ProviderContainer container() => ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith(
              (ref) =>
                  LockedStudio(prefs, dir.path, hasProject: true, busy: busy),
            ),
          ],
        );
        final c = container();
        addTearDown(c.dispose);
        expect(c.read(studioProvider).projectEditingLocked, isTrue);
        expect(
          c.read(studioProvider).fileIntegrity.hasCurrentBaseline,
          isFalse,
        );
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: theme,
              home: const Scaffold(body: SpeechExperimentSetting()),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
        await t.tap(find.byType(Switch));
        await t.pumpAndSettle();
        expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
        expect(
          FhRadioStudioProject.readSettings(
            dir.path,
          )['speech_generation_enabled'],
          isFalse,
        );
        expect(c.read(studioProvider).projectEditingLocked, isTrue);
        final reopened = container();
        addTearDown(reopened.dispose);
        expect(reopened.read(editorOptionsProvider).speechEnabled, isFalse);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'speech can be disabled before opening a project without creating one',
    (t) async {
      final dir = Directory.systemTemp.createTempSync(
        'speech-toggle-no-project-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final project = '${dir.path}/not-created';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith(
            (ref) => LockedStudio(prefs, project, hasProject: false),
          ),
        ],
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: theme,
            home: const Scaffold(body: SpeechExperimentSetting()),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(c.read(editorOptionsProvider).speechEnabled, isFalse);
      expect(
        prefs.getBool(EditorOptionsController.speechPreferenceKey),
        isFalse,
      );
      expect(Directory(project).existsSync(), isFalse);
      expect(t.takeException(), isNull);
    },
  );
}
