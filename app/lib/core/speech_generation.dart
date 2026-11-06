import 'dart:async';
import 'open_directory.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'fh_radio_studio_cli.dart';
import '../screens/stingers/stinger_session.dart';

Map<String, dynamic> speechMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> speechMaps(dynamic value) =>
    value is List ? value.map(speechMap).toList() : [];

/// Application/project lifetime, independent of disposable routes and editors.
class SpeechGenerationSession extends ChangeNotifier {
  static SpeechGenerationSession? _foreground;

  /// Survives route changes; only a live installation is shown in the shell.
  static final activeInstallation = ValueNotifier<SpeechGenerationSession?>(
    null,
  );
  Map<String, dynamic>? get installationJob =>
      jobs.where((job) => job['kind'] == 'install').lastOrNull;
  bool get installing =>
      ['queued', 'running'].contains(installationJob?['status']);
  void _publishInstallation() {
    if (installing) {
      activeInstallation.value = this;
    } else if (activeInstallation.value == this) {
      activeInstallation.value = null;
    }
  }

  static Future<void> _activation = Future.value();
  static final _appSession = DateTime.now().microsecondsSinceEpoch.toString();
  SpeechGenerationSession(FhRadioStudioCli cli, String project)
    : _worker = StingerSession(cli, project, '', command: 'speech');
  final StingerSession _worker;
  Map<String, dynamic> state = {};
  String? selectedPresetId;
  double? quickSpeed;
  final composerDrafts = <String, Map<String, dynamic>>{};
  final _dismissedPreviews = <String>{};
  bool isPreviewDismissed(Object? id) => _dismissedPreviews.contains('$id');

  /// Pool removal and unapply share preview invalidation. Keep the audio file
  /// and generation history, but never resurrect their waveform on a poll.
  void dismissPreviews({
    Map<String, dynamic>? target,
    Set<String> assetIds = const {},
  }) {
    final affected = <String>[];
    for (final job in jobs) {
      final destination = speechMap(job['target']);
      final matchesTarget =
          target != null &&
          destination['bank_id'] == target['bank_id'] &&
          destination['index'] == target['index'];
      final matchesAsset =
          assetIds.contains(job['asset_id']) ||
          (lastAccepted?['job_id'] == job['id'] &&
              assetIds.contains(speechMap(lastAccepted?['asset'])['id']));
      if (!matchesTarget && !matchesAsset) continue;
      affected.add('${job['id']}');
      _dismissedPreviews.addAll(
        speechMaps(job['candidates']).map((c) => '${c['id']}'),
      );
      _automaticTargets.remove('${job['id']}');
    }
    if (affected.isNotEmpty && !_disposed) {
      unawaited(
        call('acknowledge', {
          'preview_job_ids': affected,
        }).catchError((Object _) => <String, dynamic>{}),
      );
    }
    if (!_disposed) notifyListeners();
  }

  Map<String, dynamic>? configurationDraft;
  Map<String, dynamic>? lastAccepted;
  int acceptedRevision = 0;
  bool _checkedApi = false, _started = false, _checkingApi = false;
  DateTime _lastApiCheck = DateTime.fromMillisecondsSinceEpoch(0);
  Future<Map<String, dynamic>>? _apiCheckRequest;
  bool _startingApi = false;
  final _automaticTargets = <String, Map<String, dynamic>>{};
  bool _adopting = false;
  int _selectionRevision = 0;
  bool get apiReady => speechMap(engine['api'])['ready'] == true;
  String get apiState => _startingApi
      ? 'starting'
      : _checkingApi
      ? 'checking'
      : '${speechMap(engine['api'])['state'] ?? 'unconfigured'}';
  String get apiDetail => '${speechMap(engine['api'])['detail'] ?? '请先配置推理引擎'}';
  Future<void> checkApi({
    bool autoStart = false,
    bool background = false,
  }) async {
    if (busy || _disposed) return;
    _lastApiCheck = DateTime.now();
    _checkingApi = !background && !apiReady;
    if (_checkingApi) notifyListeners();
    try {
      await (_apiCheckRequest ??= call('check-engine', {
        'passive': background,
      }));
    } finally {
      _apiCheckRequest = null;
      _checkingApi = false;
      if (!_disposed) notifyListeners();
    }
    final config = speechMap(engine['connection']);
    if (autoStart &&
        !apiReady &&
        config['mode'] != 'existing' &&
        config['auto_start'] != false &&
        presets.isNotEmpty &&
        !busy &&
        !_startingApi) {
      _startingApi = true;
      notifyListeners();
      try {
        final selected = presets
            .where((p) => p['id'] == selectedPresetId)
            .firstOrNull;
        final startupConfig = configurationDraft?['id'] == selectedPresetId
            ? configurationDraft
            : selected ?? configurationDraft;
        await call('start-engine', {'config': ?startupConfig});
      } finally {
        _startingApi = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  void selectPreset(String id) {
    if (selectedPresetId == id) {
      if (!_disposed) notifyListeners();
      return;
    }
    _selectionRevision++;
    if (selectedPresetId != id) quickSpeed = null;
    selectedPresetId = id;
    unawaited(
      call('select-preset', {
        'id': id,
      }).catchError((Object _) => <String, dynamic>{}),
    );
    if (!_disposed) notifyListeners();
  }

  String? error;
  Timer? _timer;
  bool _disposed = false, _refreshing = false;
  Future<void> Function(Map<String, dynamic>)? receive;
  List<Map<String, dynamic>> get presets => speechMaps(engine['presets']);
  Map<String, dynamic> get engine => speechMap(state['engine']);
  List<Map<String, dynamic>> get jobs => speechMaps(state['jobs']);
  bool get busy => jobs.any((j) => ['queued', 'running'].contains(j['status']));

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    if (_disposed) throw const FormatException('语音生成已关闭。');
    final selectionRevision = _selectionRevision;
    try {
      final result = await _worker.call(action, input: input);
      if (action == 'open-install-directory' && result['path'] is String) {
        await openDirectory(result['path'] as String);
      }
      if (_disposed) return result;
      if (result['engine'] != null) {
        state = result;
        if (result.containsKey('selected_preset_id') &&
            selectionRevision == _selectionRevision) {
          selectedPresetId = result['selected_preset_id'] as String?;
        }
      }
      error = null;
      _publishInstallation();
      notifyListeners();
      return result;
    } catch (e) {
      if (!_disposed) {
        error = '$e'.replaceFirst('FormatException: ', '');
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      await call('status');
      if (_foreground == this &&
          !busy &&
          DateTime.now().difference(_lastApiCheck).inSeconds >= 15 &&
          !['stopped', 'unconfigured'].contains(apiState)) {
        await checkApi(background: true);
      }
      await _applyAutomatic();
    } catch (_) {
      // Preserve the last usable state. The visible panel reports the error.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> generateReplacement(Map<String, dynamic> input) async {
    final previous = jobs.map((j) => j['id']).toSet();
    final result = await call('submit', {...input, 'auto_apply': false});
    composerDrafts['replacement-batch'] = {
      'ids': [
        for (final job in speechMaps(result['jobs']))
          if (!previous.contains(job['id']) && job['origin'] == 'replacement')
            job['id'],
      ],
    };
    for (final job in speechMaps(result['jobs'])) {
      if (!previous.contains(job['id']) && job['origin'] == 'replacement') {
        _automaticTargets['${job['id']}'] = speechMap(job['target']);
      }
    }
    await _applyAutomatic();
  }

  Future<void> _applyAutomatic() async {
    if (_adopting || _disposed) return;
    _adopting = true;
    try {
      for (final id in _automaticTargets.keys.toList()) {
        final job = jobs.where((j) => j['id'] == id).firstOrNull;
        if (job == null || ['failed', 'cancelled'].contains(job['status'])) {
          _automaticTargets.remove(id);
          continue;
        }
        final candidate = speechMaps(job['candidates']).lastOrNull;
        if (job['status'] != 'ready' || candidate == null) continue;
        final target = _automaticTargets.remove(id)!;
        await accept(job, candidate, target: target.isEmpty ? null : target);
      }
    } finally {
      _adopting = false;
    }
  }

  Future<void> deleteCandidate(
    Map<String, dynamic> job,
    Map<String, dynamic> candidate,
  ) async {
    final result = await call('delete-candidate', {
      'job_id': job['id'],
      'candidate_id': candidate['id'],
    });
    if (receive != null) await receive!(result);
    acceptedRevision++;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_started && _foreground == this) {
      await _activation;
      return;
    }
    _started = true;
    _timer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(refresh()),
    );
    _activation = _activation.catchError((Object _) {}).then((_) async {
      if (_disposed) return;
      final previous = _foreground;
      if (previous != null && previous != this && !previous._disposed) {
        await previous.call('pause');
        while (!previous._disposed &&
            previous.jobs.any((j) => j['status'] == 'running')) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await previous.refresh();
        }
        if (!previous._disposed) await previous.call('unload');
      }
      _foreground = this;
      await call('begin-app-session', {'id': _appSession});
      await refresh();
      if (!_checkedApi) {
        _checkedApi = true;
        await checkApi();
      }
    });
    try {
      await _activation;
    } catch (e) {
      if (!_disposed) {
        error = '$e';
        notifyListeners();
      }
    }
  }

  Future<Map<String, dynamic>> accept(
    Map<String, dynamic> job,
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? edit,
    Map<String, dynamic>? target,
    bool materialOnly = false,
  }) async {
    // Capture the destination before awaiting an import. receive() compares this
    // snapshot against the live draft, preserving intervening manual changes.
    final destination = target == null
        ? null
        : speechMap(jsonDecode(jsonEncode(target)));
    final result = await call('accept', {
      'job_id': job['id'],
      'candidate_id': candidate['id'],
      'edit': ?edit,
    });
    if (!materialOnly && isPreviewDismissed(candidate['id'])) {
      result['applied_to_target'] = false;
      return result;
    }
    if (materialOnly) result.remove('target');
    if (destination != null) {
      result['target'] = destination;
      result['expected'] = destination['expected'];
      result.remove('previous_edit');
    }
    if (receive != null) await receive!(result);
    lastAccepted = {
      ...result,
      'job_id': job['id'],
      'candidate_id': candidate['id'],
    };
    acceptedRevision++;
    if (!_disposed) {
      notifyListeners();
      await call('acknowledge', {'job_id': job['id']});
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    if (activeInstallation.value == this) activeInstallation.value = null;
    if (_foreground == this) _foreground = null;
    _timer?.cancel();
    _worker.dispose();
    super.dispose();
  }
}

final speechGenerationProvider =
    Provider.family<SpeechGenerationSession, String>((ref, key) {
      final parts = List<String>.from(jsonDecode(key));
      final session = SpeechGenerationSession(
        FhRadioStudioCli(repoRoot: parts[0]),
        parts[1],
      );
      ref.onDispose(session.dispose);
      return session;
    });

String speechLanguage(String? code) => switch (code?.toUpperCase()) {
  'JP' || 'JA' => 'all_ja',
  'EN' => 'en',
  'KO' => 'all_ko',
  'CHS' || 'CHT' || 'CN' || 'TW' => 'all_zh',
  _ => 'auto',
};
