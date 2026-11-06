import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/rm_field.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_select.dart';
import 'speech_configuration_panel.dart';
import 'voice_clip_editor.dart';
import 'speech_generation_status.dart';

/// Stable per-entry preview; successful new requests are adopted to the draft.
class SpeechGenerationPanel extends StatefulWidget {
  const SpeechGenerationPanel({
    super.key,
    required this.session,
    required this.entries,
    this.initialSpeed,
    this.initialEntryIndex = 0,
    this.onEntryChanged,
    this.onClose,
    this.onAccepted,
    this.original,
    this.targetSnapshot,
    this.onUnapply,
    this.featureTour = false,
  });
  final SpeechGenerationSession session;
  final List<Map<String, dynamic>> entries;
  final double? initialSpeed;
  final int initialEntryIndex;
  final ValueChanged<int>? onEntryChanged;
  final VoidCallback? onClose;
  final ValueChanged<Map<String, dynamic>>? onAccepted;
  final Future<void> Function()? original;
  final Map<String, dynamic> Function(Map<String, dynamic>)? targetSnapshot;
  final Future<void> Function(Map<String, dynamic>, String?)? onUnapply;
  final bool featureTour;
  @override
  State<SpeechGenerationPanel> createState() => _SpeechGenerationPanelState();
}

class _SpeechGenerationPanelState extends State<SpeechGenerationPanel> {
  final _text = TextEditingController(),
      _undo = UndoHistoryController(),
      _clip = VoiceClipEditorController();
  String? _preset, _message;
  String _source = 'content';
  late String _loadedTextKey;
  int _index = 0;
  bool _submitting = false, _applying = false, _skipExisting = true;
  Timer? _editTimer;
  Future<void> _editWrites = Future.value();
  Future<void> Function()? _pendingEdit;
  final _texts = <String, String>{};
  Map<String, dynamic> get current => widget.entries[_index];
  String _targetKey(Map<String, dynamic> entry) {
    final target = speechMap(entry['target']);
    return jsonEncode([
      target['bank_id'],
      target['index'],
      target.isEmpty
          ? (entry['source_entry_name'] ?? entry['name'] ?? '')
          : null,
    ]);
  }

  String get _key => _targetKey(current);
  String _entryTextKey(Map<String, dynamic> entry) =>
      '${_targetKey(entry)}:$_source:${entry[_source == 'translation' ? 'display_language' : 'language']}';
  String get _textKey => _entryTextKey(current);
  Map<String, dynamic> get _draft => widget.session.composerDrafts.putIfAbsent(
    'preview:$_key',
    () => <String, dynamic>{},
  );
  String _defaultText(Map<String, dynamic> entry) =>
      '${entry[_source] ?? entry['text'] ?? ''}';
  @override
  void initState() {
    super.initState();
    _index = widget.initialEntryIndex.clamp(0, widget.entries.length - 1);
    final cached = widget.session.composerDrafts['replacement-composer'];
    _preset = widget.session.selectedPresetId ?? cached?['preset'] as String?;
    _source = cached?['source'] == 'translation' ? 'translation' : 'content';
    _texts.addAll(speechMap(cached?['texts']).map((k, v) => MapEntry(k, '$v')));
    _text.text = _texts[_textKey] ?? _defaultText(current);
    _loadedTextKey = _textKey;
    unawaited(_activate());
  }

  Future<void> _activate() async {
    try {
      await widget.session.start();
      if (mounted) {
        if (widget.session.selectedPresetId != null) {
          setState(() => _preset = widget.session.selectedPresetId);
        } else if (_preset != null) {
          widget.session.selectPreset(_preset!);
        }
        await widget.session.checkApi(autoStart: true);
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'API 检查失败：$e');
    }
  }

  @override
  void didUpdateWidget(covariant SpeechGenerationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_loadedTextKey != _textKey) {
      _texts[_loadedTextKey] = _text.text;
      _loadedTextKey = _textKey;
      _text.text = _texts[_textKey] ?? _defaultText(current);
    }
  }

  void _cache() {
    _texts[_loadedTextKey] = _text.text;
    widget.session.composerDrafts['replacement-composer'] = {
      'texts': {..._texts},
      'source': _source,
      'preset': _preset,
    };
  }

  @override
  void dispose() {
    _flushPreviewEdit();
    _cache();
    _text.dispose();
    _undo.dispose();
    _clip.dispose();
    super.dispose();
  }

  void _flushPreviewEdit() {
    _editTimer?.cancel();
    final apply = _pendingEdit;
    _pendingEdit = null;
    if (apply == null) return;
    _editWrites = _editWrites.catchError((Object _) {}).then((_) async {
      try {
        await apply();
      } catch (e) {
        if (mounted) setState(() => _message = '编辑结果尚未应用：$e');
      }
    });
  }

  void _previewEdited(Map<String, dynamic> preview, Map<String, dynamic> edit) {
    final duration = speechMap(preview['candidate'])['duration'];
    List<Object?> audioState(Map<String, dynamic> value) => [
      value['start'] ?? 0.0,
      value['end'] ?? duration,
      value['gain_db'] ?? 0.0,
      value['audio_edits'] ?? [],
    ];
    final changed =
        jsonEncode(audioState(speechMap(preview['edit']))) !=
        jsonEncode(audioState(edit));
    preview['edit'] = edit;
    if (!changed) return;
    final session = widget.session;
    final job = speechMap(preview['job']),
        candidate = speechMap(preview['candidate']);
    // accept() checks the job's previous applied edit before updating a target.
    // Editing the preview must not overwrite an intervening manual replacement.
    _pendingEdit = () async {
      if (session.isPreviewDismissed(candidate['id'])) return;
      await session.accept(job, candidate, edit: edit);
    };
    _editTimer?.cancel();
    _editTimer = Timer(const Duration(milliseconds: 250), _flushPreviewEdit);
  }

  bool _sameTarget(Map<String, dynamic> job) =>
      _targetKey(job) == _key && job['origin'] == 'replacement';
  List<Map<String, dynamic>> get _jobs {
    final jobs = widget.session.jobs.where(_sameTarget).toList();
    final deleted = jobs.lastIndexWhere(
      (j) =>
          j['preview_deleted'] == true ||
          j['status'] == 'ready' && speechMaps(j['candidates']).isEmpty,
    );
    return deleted < 0 ? jobs : jobs.skip(deleted + 1).toList();
  }

  Map<String, dynamic>? _preview() {
    final draft = _draft;
    final available = {
      for (final j in _jobs)
        for (final c in speechMaps(j['candidates'])) c['id'],
    };
    if (draft['candidate_id'] != null &&
        !available.contains(draft['candidate_id'])) {
      draft.clear();
      draft['dismissed'] = available.toList();
    }
    final dismissed = (draft['dismissed'] as List? ?? []).toSet();
    final matches = [
      for (final job in _jobs)
        for (final candidate in speechMaps(job['candidates']))
          if (job['preview_dismissed'] != true &&
              !dismissed.contains(candidate['id']) &&
              !widget.session.isPreviewDismissed(candidate['id']))
            {'job': job, 'candidate': candidate},
    ];
    final latestJob = _jobs.lastOrNull;
    if (_submitting ||
        ['queued', 'running', 'paused'].contains(latestJob?['status'])) {
      return null;
    }
    final latest = matches.lastOrNull;
    if (widget.session.isPreviewDismissed(draft['candidate_id'])) {
      draft.clear();
    }
    if (latest != null) {
      final candidate = speechMap(latest['candidate']);
      if (draft['candidate_id'] != candidate['id']) {
        draft['candidate_id'] = candidate['id'];
        draft['candidate'] = candidate;
        draft.remove('edit');
      }
      draft['job'] = latest['job'];
    }
    return draft['candidate'] == null ? null : draft;
  }

  Future<void> _generate() async {
    _cache();
    final entries = [
      for (final entry in widget.entries)
        if (widget.entries.length == 1 ||
            !_skipExisting ||
            speechMap(entry['target'])['expected'] == null)
          {
            ...entry,
            if (entry['target'] != null)
              'target':
                  widget.targetSnapshot?.call(speechMap(entry['target'])) ??
                  entry['target'],
            'text': _texts[_entryTextKey(entry)] ?? _defaultText(entry),
            'language':
                entry[_source == 'translation'
                    ? 'display_language'
                    : 'language'] ??
                'auto',
          },
    ];
    if (entries.isEmpty) {
      setState(() => _message = '所选条目已有替换，可取消“跳过已替换”。');
      return;
    }
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await widget.session.generateReplacement({
        'preset_id': _preset,
        'count': 1,
        'origin': 'replacement',
        'entries': entries,
        if (widget.initialSpeed != null)
          'parameters': {'speed_factor': widget.initialSpeed},
      });
    } catch (e) {
      if (mounted) {
        setState(() => _message = '$e'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _deleteFile(Map<String, dynamic> preview) async {
    setState(() => _applying = true);
    try {
      await widget.session.deleteCandidate(
        speechMap(preview['job']),
        speechMap(preview['candidate']),
      );
      if (!mounted) return;
      _draft.clear();
      _draft['dismissed'] = [
        for (final j in _jobs)
          for (final c in speechMaps(j['candidates'])) c['id'],
      ];
      setState(() => _message = '生成文件及其替换已删除。');
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Widget _textField() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo.undo,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): _undo.redo,
    },
    child: TextField(
      key: const ValueKey('speech-text'),
      controller: _text,
      undoController: _undo,
      minLines: 1,
      maxLines: 2,
      onChanged: (_) => _cache(),
      style: RmText.sans(12, color: context.rm.fg),
      decoration: rmFieldDecoration(context, hint: '输入需要生成的文本'),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, _clip]),
    builder: (_, _) {
      final s = widget.session, presets = s.presets;
      if (!presets.any((p) => p['id'] == _preset)) {
        _preset =
            presets
                    .where((p) => p['id'] == s.selectedPresetId)
                    .firstOrNull?['id']
                as String? ??
            presets.firstOrNull?['id'] as String?;
      }
      final preview = _preview(), jobs = _jobs;
      final latest = jobs.lastOrNull;
      final batchIds =
          (s.composerDrafts['replacement-batch']?['ids'] as List? ?? [])
              .toSet();
      final targets = widget.entries.map(_targetKey).toSet();
      final batch = s.jobs.where((j) => batchIds.contains(j['id'])).toList();
      final relevantBatch = batch.any((j) => targets.contains(_targetKey(j)));
      final progressJobs = relevantBatch ? batch : [?latest];
      final pending = progressJobs
          .where((j) => ['queued', 'running', 'paused'].contains(j['status']))
          .toList();
      final active =
          pending.where((j) => j['status'] == 'running').firstOrNull ??
          pending.firstOrNull;
      final failed = latest?['status'] == 'failed' ? latest : null;
      final preset = SizedBox(
        width: 128,
        child: RmSelect<String>(
          key: const ValueKey('speech-use-preset'),
          menuWidth: 260,
          value: _preset ?? '',
          items: presets.isEmpty
              ? {'': '请先保存声音预设'}
              : {for (final p in presets) '${p['id']}': '${p['name']}'},
          onChanged: presets.isEmpty
              ? null
              : (id) => setState(() {
                  _preset = id;
                  s.selectPreset(id);
                  _cache();
                }),
        ),
      );
      final language = RmButton(
        label: _source == 'content' ? '语音语言' : '显示语言',
        leading: const RmIcon('swap', size: 12),
        horizontalPadding: 8,
        onPressed: () {
          _cache();
          setState(() {
            _source = _source == 'content' ? 'translation' : 'content';
            _loadedTextKey = _textKey;
            _text.text = _texts[_textKey] ?? _defaultText(current);
          });
          _cache();
        },
      );
      final settings = RmButton(
        label: '模型设置',
        horizontalPadding: 8,
        leading: const RmIcon('settings', size: 12),
        onPressed: () => showSpeechConfigurationDialog(context, s),
      );
      final api = SpeechApiStatus(session: s);
      final controls = <Widget>[
        RmButton(
          key: const ValueKey('speech-generate'),
          label: widget.entries.length > 1 ? '批量生成' : '生成语音',
          variant: RmButtonVariant.primary,
          leading: const RmIcon('volume', size: 12),
          onPressed: _submitting || _preset == null || !s.apiReady || _applying
              ? null
              : _generate,
        ),
        RmButton(
          key: const ValueKey('speech-preview-play'),
          label: _clip.playing ? '暂停' : '播放',
          leading: RmIcon(_clip.playing ? 'pause' : 'play', size: 12),
          onPressed: preview == null || _clip.busy ? null : _clip.toggle,
        ),
        RmButton(
          key: const ValueKey('speech-unapply'),
          label: '取消应用',
          leading: const RmIcon('x', size: 12),
          onPressed: preview == null || _applying || widget.onUnapply == null
              ? null
              : () async {
                  _editTimer?.cancel();
                  _pendingEdit = null;
                  await widget.onUnapply!(
                    speechMap(current['target']),
                    speechMap(preview['job'])['asset_id'] as String?,
                  );
                  widget.session.dismissPreviews(
                    target: speechMap(current['target']),
                  );
                  if (mounted) setState(() => _message = '已取消应用，音频文件保留。');
                },
        ),
        RmButton(
          key: const ValueKey('speech-delete-file'),
          label: '删除文件',
          leading: const RmIcon('trash', size: 12),
          foregroundColor: context.rm.danger,
          onPressed: preview == null || _applying
              ? null
              : () => _deleteFile(preview),
        ),
        if (widget.entries.length > 1)
          SizedBox(
            height: 32,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: const ValueKey('speech-skip-existing'),
                  visualDensity: VisualDensity.compact,
                  value: _skipExisting,
                  onChanged: (v) => setState(() => _skipExisting = v!),
                ),
                Text('跳过已替换', style: RmText.sans(11, color: context.rm.fg3)),
              ],
            ),
          ),
      ];
      final ready = progressJobs.where((j) => j['status'] == 'ready').length;
      final failures = progressJobs
          .where((j) => j['status'] == 'failed')
          .length;
      final queued = pending.where((j) => j['status'] == 'queued').length;
      final cancelled = progressJobs
          .where((j) => j['status'] == 'cancelled')
          .length;
      final statusText = _submitting
          ? '正在提交生成任务'
          : active == null && _message != null
          ? _message!
          : progressJobs.length > 1
          ? '批量：完成 $ready/${progressJobs.length} · 剩余 ${pending.length}'
                '${queued > 0 ? ' · 排队 $queued' : ''}'
                '${failures > 0 ? ' · 失败 $failures' : ''}'
                '${cancelled > 0 ? ' · 取消 $cancelled' : ''}'
                '${active != null ? ' · ${active['status'] == 'paused' ? '已暂停' : active['progress'] ?? '等待生成'}' : ''}'
          : '${active?['progress'] ?? (active != null ? '等待生成' : null) ?? _message ?? failed?['error'] ?? (latest?['status'] == 'cancelled'
                    ? '已取消；保留可用预览'
                    : preview != null
                    ? '生成完成，已自动替换；请试听后保存'
                    : '')}';
      final status = SizedBox(
        key: const ValueKey('speech-generation-status'),
        width: progressJobs.length > 1 ? 280 : 240,
        child: SpeechGenerationStatus(
          text: statusText,
          running: active != null && active['status'] != 'paused',
          failed: failed != null && active == null,
          onCancel: active == null
              ? null
              : () => s.call('cancel', {
                  'ids': pending.map((j) => j['id']).toList(),
                }),
        ),
      );
      final panel = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, box) {
              final optionRow = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  language,
                  const SizedBox(width: 8),
                  preset,
                  const SizedBox(width: 8),
                  settings,
                  const SizedBox(width: 8),
                  api,
                ],
              );
              final options = box.maxWidth >= 820
                  ? optionRow
                  : Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [language, preset, settings, api],
                    );
              return box.maxWidth >= 820
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: _textField()),
                        const SizedBox(width: 8),
                        options,
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _textField(),
                        const SizedBox(height: 6),
                        options,
                      ],
                    );
            },
          ).tourAnchor('generation-text'),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final control in controls) ...[
                  control,
                  const SizedBox(width: 8),
                ],
                status,
              ],
            ),
          ).tourAnchor('generation-actions'),
          ...[
            const SizedBox(height: 8),
            VoiceClipEditor(
              key: ValueKey(
                'speech-preview-${preview?['candidate_id'] ?? 'empty:$_key'}',
              ),
              empty: preview == null,
              replacementInline: true,
              controller: _clip,
              asset: {
                'id': preview?['candidate_id'] ?? '',
                'name': speechMap(preview?['job'])['text'] ?? '',
                'duration': speechMap(preview?['candidate'])['duration'] ?? 0,
                'category': '生成语音',
              },
              folders: const ['生成语音'],
              initial: preview?['edit'] as Map<String, dynamic>?,
              load: () => s.call('candidate-audio', {
                'job_id': speechMap(preview?['job'])['id'],
                'candidate_id': preview?['candidate_id'],
              }),
              render: (edit) => s.call('candidate-audio', {
                'job_id': speechMap(preview?['job'])['id'],
                'candidate_id': preview?['candidate_id'],
                'edit': edit,
              }),
              onChanged: (edit) {
                if (preview != null) _previewEdited(preview, edit);
              },
            ).tourAnchor('generation-wave'),
          ],
        ],
      );
      return widget.featureTour
          ? panel.withFeatureTour(
              TourPage.voiceGeneration,
              enabled: s.apiReady && _preset != null && !s.busy && !_submitting,
            )
          : panel;
    },
  );
}
