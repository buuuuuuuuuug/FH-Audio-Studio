import '../core/playlist_capacity.dart';
import 'playlist_capacity.dart';
import 'playlist_catalog_state.dart';
import 'playlist_plan_state.dart';
import '../domain/radio_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/project_workspace.dart';
import 'studio_state.dart';
import 'app_state.dart';

class EditorOptions {
  const EditorOptions({
    this.syncPostLoop = false,
    this.manualOnly = false,
    this.sirenEnabled = false,
    this.expansionEnabled = false,
    this.slmEnabled = true,
    this.speechEnabled = true,
  });
  final bool syncPostLoop;
  final bool manualOnly;
  final bool sirenEnabled;
  final bool expansionEnabled;
  final bool slmEnabled;
  final bool speechEnabled;
}

class EditorOptionsController extends StateNotifier<EditorOptions> {
  EditorOptionsController(this.ref) : super(const EditorOptions()) {
    _load();
    ref.listen<String>(
      studioProvider.select((s) => s.projectDir),
      (_, next) => _load(),
    );
  }
  final Ref ref;
  static const speechPreferenceKey = 'rm.speech_generation_enabled';
  void _load() {
    final studio = ref.read(studioProvider);
    final settings = studio.hasProject
        ? FhRadioStudioProject.readSettings(studio.projectDir)
        : <String, dynamic>{};
    state = EditorOptions(
      syncPostLoop: settings['sync_post_loop'] == true,
      manualOnly: settings['manual_only'] == true,
      sirenEnabled: settings['siren_enabled'] == true,
      expansionEnabled: settings['expansion_enabled'] == true,
      slmEnabled: settings['seamless_loop_music'] != false,
      speechEnabled: settings['speech_generation_enabled'] is bool
          ? settings['speech_generation_enabled'] as bool
          : ref.read(sharedPreferencesProvider).getBool(speechPreferenceKey) ??
                true,
    );
  }

  List<String> expansionOverflow() {
    final catalog = ref.read(playlistCatalogProvider);
    final plan = ref.read(effectivePlaylistPlanProvider);
    final hasPlan =
        ref.read(playlistPlanProvider.notifier).hasUserPlan || plan.hasDraft;
    final fallback = <String, Map<String, int>>{
      if (!hasPlan)
        for (final radio in catalog.radios)
          radio.code: {
            for (final type in ['FreeRoam', 'Event'])
              if (catalog.modeOfList(radio.code, type) == StationMode.custom)
                type: catalog.tracksOfRadio(radio.code, type).length,
          },
    };
    return describeCapacityViolations(
      ref
          .read(playlistCapacityPolicyProvider)
          .violations(plan, fallbackCounts: fallback),
    );
  }

  bool update({
    bool? syncPostLoop,
    bool? manualOnly,
    bool? sirenEnabled,
    bool? expansionEnabled,
    bool? slmEnabled,
    bool? speechEnabled,
  }) {
    if (expansionEnabled == false && state.expansionEnabled) {
      final plan = ref.read(effectivePlaylistPlanProvider);
      if (plan.splitPlaylistTypes == true) {
        return false;
      }
    }
    if (expansionEnabled == false &&
        state.expansionEnabled &&
        expansionOverflow().isNotEmpty) {
      return false;
    }
    final next = EditorOptions(
      syncPostLoop: syncPostLoop ?? state.syncPostLoop,
      manualOnly: manualOnly ?? state.manualOnly,
      sirenEnabled: sirenEnabled ?? state.sirenEnabled,
      expansionEnabled: expansionEnabled ?? state.expansionEnabled,
      slmEnabled: slmEnabled ?? state.slmEnabled,
      speechEnabled: speechEnabled ?? state.speechEnabled,
    );
    final studio = ref.read(studioProvider);
    if (studio.hasProject) {
      FhRadioStudioProject.writeSettings(
        studio.projectDir,
        syncPostLoop: next.syncPostLoop,
        manualOnly: next.manualOnly,
        sirenEnabled: next.sirenEnabled,
        expansionEnabled: next.expansionEnabled,
        slmEnabled: next.slmEnabled,
        speechEnabled: next.speechEnabled,
      );
    } else if (speechEnabled != null) {
      // Feature visibility can be changed before a project or backup exists.
      // Do not create a project as a side effect of toggling an app feature.
      ref
          .read(sharedPreferencesProvider)
          .setBool(speechPreferenceKey, speechEnabled);
    }
    state = next;
    return true;
  }
}

final editorOptionsProvider =
    StateNotifierProvider<EditorOptionsController, EditorOptions>(
      (ref) => EditorOptionsController(ref),
      dependencies: [studioProvider, sharedPreferencesProvider],
    );
