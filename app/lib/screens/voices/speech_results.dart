import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/speech_configuration.dart';
import '../../core/speech_generation.dart';
import '../../core/studio_audio_players.dart';
import '../../core/voice_audition.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_field.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_number_field.dart';
import '../../widgets/rm_select.dart';
import 'voice_clip_editor.dart';
import 'speech_generation_status.dart';

/// Text entry and expandable results. Audio editing is the existing editor.
class SpeechResults extends StatefulWidget {
  const SpeechResults({super.key, required this.configuration});
  final SpeechConfiguration configuration;
  @override
  State<SpeechResults> createState() => _SpeechResultsState();
}

class _SpeechResultsState extends State<SpeechResults> {
  final _text = TextEditingController(),
      _count = TextEditingController(text: '1');
  final _scroll = ScrollController();
  final _edits = <String, Map<String, dynamic>>{};
  final _seen = <String>{};
  final _requestedJobs = <String>{};
  final _rendering = <String>{}, _using = <String>{};
  final _adoptedEdits = <String, String>{};
  String _mode = 'whole';
  String? _expanded, _message, _playing;
  bool _submitting = false;
  int _playRequest = 0;
  SpeechGenerationSession get session => widget.configuration.session;
  List<Map<String, dynamic>> get _records => [
    for (final job in session.jobs.reversed)
      if (job['kind'] == null &&
          (job['origin'] == 'studio' || job['target'] == null))
        for (final audio in speechMaps(job['candidates']).reversed)
          {...audio, 'job': job},
  ];
  List<String> _split() => _text.text
      .split(
        _mode == 'whole'
            ? RegExp(r'(?!)')
            : _mode == 'lines'
            ? RegExp(r'\r?\n')
            : RegExp(r'\r?\n\s*\r?\n'),
      )
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  @override
  void initState() {
    super.initState();
    final draft = session.composerDrafts['studio'];
    if (draft != null) {
      _text.text = '${draft['text']}';
      _count.text = '${draft['count']}';
      _mode = '${draft['mode']}';
      _adoptedEdits.addAll(
        speechMap(draft['adopted_edits']).map((k, v) => MapEntry(k, '$v')),
      );
      _requestedJobs.clear();
      _requestedJobs.addAll(
        (draft['requested_jobs'] as List? ?? []).cast<String>(),
      );
    }
    for (final e in speechMap(session.composerDrafts['studio-edits']).entries) {
      _edits[e.key] = speechMap(e.value);
    }
    _seen.addAll(_records.map((r) => '${r['id']}'));
    _expanded = _records.firstOrNull?['id'] as String?;
  }

  @override
  void dispose() {
    session.composerDrafts['studio'] = {
      'text': _text.text,
      'count': _count.text,
      'mode': _mode,
      'adopted_edits': _adoptedEdits,
      'requested_jobs': _requestedJobs.toList(),
    };
    session.composerDrafts['studio-edits'] = {..._edits};
    _playRequest++;
    if (_playing != null) unawaited(StudioAudioPlayers.voice.pause());
    _text.dispose();
    _count.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Map<String, dynamic> _request(
    Map<String, dynamic> record, {
    bool edits = true,
  }) => {
    'job_id': speechMap(record['job'])['id'],
    'candidate_id': record['id'],
    if (edits && _edits['${record['id']}'] != null)
      'edit': _edits['${record['id']}'],
  };
  Future<void> _generate() async {
    final count = int.tryParse(_count.text), lines = _split();
    if (count == null ||
        count < 1 ||
        count > 8 ||
        lines.isEmpty ||
        lines.length > 500) {
      setState(() => _message = '请输入文本；一次生成 1–8 条，批量文本最多 500 段。');
      return;
    }
    setState(() {
      _expanded = null;
      _submitting = true;
      _message = null;
    });
    try {
      final before = session.jobs.map((job) => job['id']).toSet();
      final result = await session.call('submit', {
        'config': widget.configuration.snapshot(),
        'count': count,
        'origin': 'studio',
        'entries': [
          for (final text in lines)
            {
              'text': text,
              'name': text.length > 40 ? '${text.substring(0, 40)}…' : text,
              'language': widget.configuration.data['text_lang'],
            },
        ],
        'auto_apply': false,
      });
      _requestedJobs.clear();
      _requestedJobs.addAll(
        speechMaps(result['jobs'])
            .where((job) => !before.contains(job['id']))
            .map((job) => '${job['id']}'),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _message = '$e'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _importText() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final value = await File(path).readAsString();
      if (mounted) setState(() => _text.text = value);
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取文本，请使用 UTF-8 编码的 TXT 文件。');
    }
  }

  Future<void> _play(Map<String, dynamic> record) async {
    final player = StudioAudioPlayers.voice,
        id = '${record['id']}',
        request = ++_playRequest;
    if (_playing == id && player.state.playing) {
      await player.pause();
      if (mounted) setState(() => _playing = null);
      return;
    }
    try {
      final edit = _edits[id];
      await StudioAudioPlayers.pauseOthers(player);
      await startVoiceAudition(
        player,
        '${speechMap(edit?['wave'])['path'] ?? record['path']}',
        gainDb: (edit?['gain_db'] as num?)?.toDouble() ?? 0,
        isCurrent: () => mounted && request == _playRequest,
      );
      if (mounted) setState(() => _playing = id);
    } catch (e) {
      if (mounted) setState(() => _message = '试听失败：$e');
    }
  }

  String _fingerprint(Map<String, dynamic> record) {
    final edit = _edits['${record['id']}'];
    return jsonEncode({
      'start': edit?['start'] ?? 0.0,
      'end': edit?['end'] ?? record['duration'],
      'gain_db': edit?['gain_db'] ?? 0.0,
      'audio_edits': edit?['audio_edits'] ?? [],
    });
  }

  Future<void> _use(Map<String, dynamic> record) async {
    final id = '${record['id']}';
    final fingerprint = _fingerprint(record);
    final edit = _edits[id] == null
        ? null
        : speechMap(jsonDecode(jsonEncode(_edits[id])));
    setState(() => _using.add(id));
    try {
      await session.accept(
        speechMap(record['job']),
        record,
        edit: edit,
        materialOnly: true,
      );
      if (mounted) {
        setState(() {
          _message = '已加入语音替换素材池。';
          _adoptedEdits[id] = fingerprint;
        });
      }
      await session.refresh();
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _using.remove(id));
    }
  }

  Future<void> _export(Map<String, dynamic> record, String format) async {
    try {
      final path = await FilePicker.saveFile(
        fileName:
            '${String.fromCharCodes('${speechMap(record['job'])['text'] ?? '生成语音'}'.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').runes.take(32)).trim()}.$format',
        type: FileType.custom,
        allowedExtensions: [format],
      );
      if (path != null) {
        await session.call('export-audio', {..._request(record), 'path': path});
      }
      if (path != null && mounted) setState(() => _message = '音频已导出。');
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> record) async {
    final id = '${record['id']}';
    setState(() => _using.add(id));
    try {
      if (_playing == id) {
        _playRequest++;
        await StudioAudioPlayers.voice.pause();
      }
      await session.deleteCandidate(speechMap(record['job']), record);
      if (mounted) {
        setState(() {
          _edits.remove(id);
          _adoptedEdits.remove(id);
          if (_expanded == id) _expanded = null;
          _message = '生成文件及其替换已删除。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _using.remove(id));
    }
  }

  Widget _result(Map<String, dynamic> record, int number) {
    final id = '${record['id']}', job = speechMap(record['job']);
    final expanded = _expanded == id, edit = _edits[id];
    final adopted =
        job['accepted'] == id &&
        (_adoptedEdits[id] == null ||
            _adoptedEdits[id] == _fingerprint(record));
    return Container(
      key: ValueKey('speech-result-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.rm.panel,
        border: Border.all(
          color: expanded ? context.rm.accent.base : context.rm.border,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _rendering.contains(id)
                ? null
                : () => setState(() => _expanded = expanded ? null : id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: LayoutBuilder(
                builder: (_, box) {
                  final title = Row(
                    children: [
                      RmIcon(
                        expanded ? 'chevron-down' : 'chevron-right',
                        size: 13,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${job['name'] ?? '生成语音 $number'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.sans(12, color: context.rm.fg),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${speechMap(job['preset'])['name']} · ${(edit?['edited_duration'] as num? ?? record['duration'] as num).toStringAsFixed(2)} 秒 · 种子 ${record['seed']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.mono(10.5, color: context.rm.fg3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                  final actions = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RmButton.icon(
                        key: ValueKey('speech-play-$id'),
                        icon: RmIcon(
                          _playing == id &&
                                  StudioAudioPlayers.voice.state.playing
                              ? 'pause'
                              : 'play',
                          size: 12,
                        ),
                        tooltip: '试听',
                        onPressed: _rendering.contains(id)
                            ? null
                            : () => _play(record),
                      ),
                      const SizedBox(width: 8),
                      RmButton(
                        key: ValueKey('speech-use-$id'),
                        label: adopted ? '已加入素材池' : '加入素材池',
                        leading: RmIcon(
                          adopted ? 'check' : 'list-plus',
                          size: 12,
                        ),
                        size: RmButtonSize.md,
                        variant: adopted
                            ? RmButtonVariant.defaultBtn
                            : RmButtonVariant.primary,
                        onPressed:
                            adopted ||
                                _rendering.contains(id) ||
                                _using.contains(id)
                            ? null
                            : () => _use(record),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        enabled: !_rendering.contains(id),
                        tooltip: '导出音频',
                        onSelected: (format) => _export(record, format),
                        itemBuilder: (_) => [
                          for (final format in [
                            'wav',
                            'flac',
                            'mp3',
                            'ogg',
                            'aac',
                          ])
                            PopupMenuItem(
                              value: format,
                              child: Text(format.toUpperCase()),
                            ),
                        ],
                        child: IgnorePointer(
                          child: RmButton.icon(
                            icon: const RmIcon('export', size: 13),
                            onPressed: () {},
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      RmButton.icon(
                        key: ValueKey('speech-delete-$id'),
                        icon: RmIcon(
                          'trash',
                          size: 12,
                          color: context.rm.danger,
                        ),
                        tooltip: '删除生成音频及其替换',
                        onPressed:
                            _rendering.contains(id) || _using.contains(id)
                            ? null
                            : () => _delete(record),
                      ),
                    ],
                  );
                  return box.maxWidth >= 450
                      ? Row(
                          children: [
                            Expanded(child: title),
                            const SizedBox(width: 8),
                            actions,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            title,
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: actions,
                            ),
                          ],
                        );
                },
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: VoiceClipEditor(
                key: ValueKey('speech-inline-$id'),
                embedded: true,
                asset: {
                  'id': id,
                  'name': job['name'] ?? '生成语音',
                  'duration': record['duration'],
                  'category': '生成语音',
                },
                folders: const ['生成语音'],
                initial: edit,
                load: () => session.call(
                  'candidate-audio',
                  _request(record, edits: false),
                ),
                render: (edit) async {
                  setState(() => _rendering.add(id));
                  try {
                    return await session.call('candidate-audio', {
                      ..._request(record, edits: false),
                      'edit': edit,
                    });
                  } finally {
                    if (mounted) setState(() => _rendering.remove(id));
                  }
                },
                onChanged: (value) {
                  if (mounted) setState(() => _edits[id] = value);
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, widget.configuration]),
    builder: (_, _) {
      final records = _records;
      final fresh = records.where((r) => !_seen.contains(r['id'])).toList();
      if (fresh.isNotEmpty) {
        _expanded = '${fresh.first['id']}';
        _seen.addAll(fresh.map((r) => '${r['id']}'));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
      final jobs = session.jobs
          .where(
            (j) =>
                j['kind'] == null &&
                j['origin'] != 'replacement' &&
                ['running', 'queued', 'paused', 'failed'].contains(j['status']),
          )
          .toList();
      final active = jobs
          .where((j) => ['running', 'queued'].contains(j['status']))
          .toList();
      final failed = jobs
          .where(
            (j) => j['status'] == 'failed' && _requestedJobs.contains(j['id']),
          )
          .lastOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '生成文本',
                      style: RmText.sans(
                        15,
                        color: context.rm.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    RmButton(
                      label: '导入文本',
                      size: RmButtonSize.md,
                      leading: const RmIcon('folder', size: 12),
                      onPressed: _importText,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                TextField(
                  key: const ValueKey('speech-studio-text'),
                  controller: _text,
                  minLines: 3,
                  maxLines: 5,
                  style: RmText.sans(12.5, color: context.rm.fg),
                  decoration: rmFieldDecoration(
                    context,
                    hint: '输入需要生成的语音；批量生成可按行或空行拆分。',
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (_, box) {
                    final mode = SizedBox(
                      width: 112,
                      child: RmSelect<String>(
                        value: _mode,
                        items: const {
                          'whole': '整段生成',
                          'lines': '每行一条',
                          'paragraphs': '空行分段',
                        },
                        onChanged: (v) => setState(() => _mode = v),
                      ),
                    );
                    final count = SizedBox(
                      width: 66,
                      height: 32,
                      child: RmNumberField(
                        key: const ValueKey('speech-count'),
                        controller: _count,
                        min: 1,
                        max: 8,
                        step: 1,
                        decimals: 0,
                      ),
                    );
                    final quantity = Text(
                      '数量',
                      style: RmText.sans(11.5, color: context.rm.fg3),
                    );
                    final generate = RmButton(
                      key: const ValueKey('speech-studio-generate'),
                      label: '生成语音',
                      variant: RmButtonVariant.primary,
                      leading: const RmIcon('volume', size: 12),
                      onPressed:
                          _submitting ||
                              _rendering.isNotEmpty ||
                              !widget.configuration.ready ||
                              !session.apiReady
                          ? null
                          : _generate,
                    );
                    final requested = session.jobs
                        .where((j) => _requestedJobs.contains(j['id']))
                        .toList();
                    final remaining = requested
                        .where(
                          (j) => [
                            'queued',
                            'running',
                            'paused',
                          ].contains(j['status']),
                        )
                        .length;
                    final completed = requested
                        .where((j) => j['status'] == 'ready')
                        .length;
                    final isPaused = session.state['paused'] == true;
                    final statusText = _submitting
                        ? '正在提交生成任务'
                        : _message ??
                              (failed != null
                                  ? '${failed['error']}'
                                  : requested.length > 1
                                  ? '完成 $completed/${requested.length} · 剩余 $remaining'
                                        '${isPaused
                                            ? ' · 已暂停'
                                            : active.isNotEmpty
                                            ? ' · ${active.first['progress'] ?? '等待生成'}'
                                            : ''}'
                                  : isPaused && remaining > 0
                                  ? '已暂停；点击继续生成'
                                  : active.isNotEmpty
                                  ? '${active.first['progress'] ?? '等待生成'}'
                                  : completed > 0
                                  ? '生成完成，请试听后加入素材池'
                                  : '输入文本后生成');
                    final status = SpeechGenerationStatus(
                      key: const ValueKey('speech-studio-status'),
                      text: statusText,
                      running: _submitting || active.isNotEmpty && !isPaused,
                      failed: failed != null,
                      onResume: isPaused ? () => session.call('resume') : null,
                      onPause: active.isNotEmpty && !isPaused
                          ? () => session.call('pause')
                          : null,
                      onCancel:
                          requested.any(
                            (j) => [
                              'running',
                              'queued',
                              'paused',
                            ].contains(j['status']),
                          )
                          ? () => session.call('cancel', {
                              'ids': requested.map((j) => j['id']).toList(),
                            })
                          : null,
                      onRetry: failed == null
                          ? null
                          : () => session.call('retry', {
                              'ids': [failed['id']],
                            }),
                    );
                    final controls = Row(
                      children: [
                        generate,
                        const SizedBox(width: 8),
                        mode,
                        const SizedBox(width: 8),
                        quantity,
                        const SizedBox(width: 6),
                        count,
                      ],
                    );
                    return box.maxWidth >= 760
                        ? Row(
                            children: [
                              controls,
                              const SizedBox(width: 12),
                              Flexible(
                                child: SizedBox(width: 320, child: status),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  generate,
                                  mode,
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      quantity,
                                      const SizedBox(width: 6),
                                      count,
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              status,
                            ],
                          );
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: context.rm.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Text(
                  '生成音频',
                  style: RmText.sans(
                    15,
                    color: context.rm.fg,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${records.length} 条 · 点击展开编辑',
                  style: RmText.sans(11, color: context.rm.fg3),
                ),
              ],
            ),
          ),
          Expanded(
            child: records.isEmpty
                ? Center(
                    child: Text(
                      '生成后在这里试听和编辑。',
                      style: RmText.sans(12, color: context.rm.fg3),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: records.length,
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<String>) return null;
                      final index = records.indexWhere(
                        (r) => r['id'] == key.value,
                      );
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (_, i) => KeyedSubtree(
                      key: ValueKey<String>('${records[i]['id']}'),
                      child: _result(records[i], i + 1),
                    ),
                  ),
          ),
        ],
      );
    },
  );
}
