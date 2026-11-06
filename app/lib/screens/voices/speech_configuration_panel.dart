import '../../widgets/audio_editor_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/speech_configuration.dart';
import '../../core/speech_generation.dart';
import '../../core/studio_audio_players.dart';
import '../../core/voice_audition.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/rm_field.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_number_field.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_tooltip.dart';
export 'speech_engine_dialog.dart';
import '../../widgets/timing_dialog_frame.dart';

class SpeechConfigurationPanel extends StatefulWidget {
  const SpeechConfigurationPanel({super.key, required this.configuration});
  final SpeechConfiguration configuration;
  @override
  State<SpeechConfigurationPanel> createState() =>
      _SpeechConfigurationPanelState();
}

class _SpeechConfigurationPanelState extends State<SpeechConfigurationPanel> {
  final _prompt = TextEditingController();
  int _revision = -1;
  String? _error, _playingReference, _importing;
  SpeechConfiguration get c => widget.configuration;
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('FormatException: ', ''));
      }
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pick(String key) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: key == 'gpt_model'
          ? ['ckpt']
          : key == 'sovits_model'
          ? ['pth']
          : ['wav', 'flac', 'ogg', 'mp3'],
      dialogTitle: key == 'ref_audio_path' ? '导入 3–10 秒参考音频' : '导入模型文件',
    );
    final file = result?.files.single.path;
    if (file == null || !mounted) return;
    final revision = c.revision;
    setState(() => _importing = key);
    try {
      final result = await c.session.call('import-file', {
        'kind': key,
        'path': file,
      });
      if (!mounted || c.revision != revision) return;
      final imported = speechMap(result['imported_file']);
      c.update(key, imported['path']);
      c.update(
        key == 'gpt_model'
            ? 'gpt_filename'
            : key == 'sovits_model'
            ? 'sovits_filename'
            : 'reference_filename',
        imported['filename'],
      );
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _save({bool asNew = false}) async {
    var name = '${c.data['name']}';
    if (asNew || c.presetId == null) {
      final field = TextEditingController(
        text: asNew && c.presetId != null
            ? '$name 副本'
            : name == '当前配置'
            ? ''
            : name,
      );
      final chosen = await showDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => TimingDialogFrame(
          title: '保存当前配置为预设',
          icon: 'save',
          busy: false,
          width: 430,
          body: TextField(
            controller: field,
            autofocus: true,
            maxLength: 100,
            decoration: rmFieldDecoration(ctx, hint: '预设名称'),
            style: RmText.sans(13, color: ctx.rm.fg),
            onSubmitted: (s) {
              if (s.trim().isNotEmpty) Navigator.pop(ctx, s.trim());
            },
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
            RmButton(
              label: '保存预设',
              variant: RmButtonVariant.primary,
              onPressed: () {
                if (field.text.trim().isNotEmpty) {
                  Navigator.pop(ctx, field.text.trim());
                }
              },
            ),
          ],
        ),
      );
      Future<void>.delayed(const Duration(milliseconds: 250), field.dispose);
      if (chosen == null || !mounted) return;
      name = chosen;
    }
    await c.save(name, asNew: asNew);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('声音预设“$name”已保存。')));
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(text, style: RmText.sans(11.5, color: context.rm.fg2)),
  );
  Widget _file(String key, String label, String alias) {
    final current = '${c.data[key] ?? ''}';
    final files = <String, String>{'': '请导入文件'};
    final filenameKey = key == 'gpt_model'
        ? 'gpt_filename'
        : key == 'sovits_model'
        ? 'sovits_filename'
        : 'reference_filename';
    for (final imported in speechMaps(c.session.state['imports'])) {
      if (imported['kind'] == key) {
        files['${imported['path']}'] = '${imported['filename']}';
      }
    }
    for (final preset in c.session.presets) {
      final path = '${preset[key] ?? ''}';
      if (path.isNotEmpty) {
        files[path] = '${preset[filenameKey] ?? '原名未记录'}';
      }
    }
    if (current.isNotEmpty) {
      files[current] = '${c.data[filenameKey] ?? '原名未记录'}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(label),
        _fileRow(
          file: RmSelect<String>(
            key: ValueKey('speech-$key'),
            value: current,
            items: files,
            onChanged: (v) {
              c.update(key, v);
              c.update(alias, files[v] == '原名未记录' ? null : files[v]);
              c.update(filenameKey, files[v] == '原名未记录' ? null : files[v]);
            },
          ),
          choose: () => _act(() => _pick(key)),
          importing: _importing == key,
          audition: key != 'ref_audio_path' || current.isEmpty
              ? null
              : () => _act(() => _playReference(current)),
        ),
      ],
    );
  }

  Future<void> _pickAuxiliary([int? index]) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowMultiple: index == null,
      allowedExtensions: ['wav', 'flac', 'ogg', 'mp3'],
    );
    if (!mounted || result == null) return;
    final paths = List<String>.from(c.data['aux_ref_audio_paths'] as List);
    final names = List<String?>.generate(
      paths.length,
      (i) =>
          (c.data['aux_reference_filenames'] as List?)?.elementAtOrNull(i)
              as String?,
    );
    final revision = c.revision;
    final selected = <Map<String, dynamic>>[];
    setState(() => _importing = 'auxiliary');
    try {
      for (final file in result.paths.whereType<String>()) {
        final response = await c.session.call('import-file', {
          'kind': 'aux_ref_audio',
          'path': file,
        });
        selected.add(speechMap(response['imported_file']));
      }
      if (!mounted || c.revision != revision) return;
      if (index != null && selected.isNotEmpty) {
        paths[index] = '${selected.first['path']}';
        names[index] = '${selected.first['filename']}';
      } else {
        paths.addAll(selected.map((item) => '${item['path']}'));
        names.addAll(selected.map((item) => '${item['filename']}'));
      }
    } finally {
      if (mounted) setState(() => _importing = null);
    }
    c.update('aux_ref_audio_paths', paths);
    c.update('aux_reference_filenames', names);
  }

  Widget _auxiliary(int index) {
    final path = '${(c.data['aux_ref_audio_paths'] as List)[index]}';
    final name = (c.data['aux_reference_filenames'] as List?)?.elementAtOrNull(
      index,
    );
    return _fileRow(
      file: RmTooltip(
        message: name == null ? '原名未记录；可重新选择文件补全' : '$name',
        child: Container(
          height: 32,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: context.rm.raised,
            border: Border.all(color: context.rm.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$name' == 'null' ? '原名未记录' : '$name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.sans(12, color: context.rm.fg),
          ),
        ),
      ),
      choose: () => _act(() => _pickAuxiliary(index)),
      audition: () => _act(() => _playReference(path)),
      remove: () {
        final paths = List<dynamic>.from(c.data['aux_ref_audio_paths'] as List)
          ..removeAt(index);
        final names = List<dynamic>.generate(
          (c.data['aux_ref_audio_paths'] as List).length,
          (i) =>
              (c.data['aux_reference_filenames'] as List?)?.elementAtOrNull(i),
        )..removeAt(index);
        c.update('aux_ref_audio_paths', paths);
        c.update('aux_reference_filenames', names);
      },
    );
  }

  Widget _fileRow({
    required Widget file,
    required VoidCallback choose,
    VoidCallback? audition,
    VoidCallback? remove,
    bool importing = false,
  }) => Row(
    children: [
      Expanded(child: file),
      const SizedBox(width: 6),
      RmButton(
        label: importing ? '导入中…' : '导入',
        size: RmButtonSize.md,
        leading: const RmIcon('folder', size: 12),
        onPressed: _importing != null ? null : choose,
      ),
      if (audition != null) ...[
        const SizedBox(width: 6),
        RmButton.icon(
          icon: const RmIcon('play', size: 12),
          tooltip: '试听参考音频',
          onPressed: audition,
        ),
      ],
      if (remove != null) ...[
        const SizedBox(width: 6),
        RmButton.icon(
          icon: const RmIcon('trash', size: 12),
          tooltip: '移除辅助参考',
          foregroundColor: context.rm.danger,
          onPressed: remove,
        ),
      ],
    ],
  );

  Future<void> _playReference(String path) async {
    final player = StudioAudioPlayers.voice;
    if (_playingReference == path && player.state.playing) {
      await player.pause();
      if (mounted) setState(() => _playingReference = null);
      return;
    }
    await StudioAudioPlayers.pauseOthers(player);
    await startVoiceAudition(
      player,
      p.isAbsolute(path) ? path : p.join('${c.session.engine['home']}', path),
    );
    if (mounted) setState(() => _playingReference = path);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (_, _) {
      if (_revision != c.revision) {
        _prompt.text = '${c.data['prompt_text'] ?? ''}';
        _revision = c.revision;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('声音预设'),
              Row(
                children: [
                  Expanded(
                    child: RmSelect<String>(
                      key: const ValueKey('speech-preset'),
                      value: c.presetId ?? '',
                      items: {
                        '': '当前配置 · 未保存',
                        for (final preset in c.session.presets)
                          '${preset['id']}':
                              '${preset['name']}${preset['id'] == c.presetId && c.isDirty ? ' *' : ''}',
                      },
                      onChanged: (id) {
                        if (id.isNotEmpty) {
                          c.load(
                            c.session.presets.firstWhere((p) => p['id'] == id),
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  RmButton(
                    label: '保存预设',
                    leading: const RmIcon('save', size: 12),
                    variant: RmButtonVariant.primary,
                    size: RmButtonSize.md,
                    onPressed: () => _act(_save),
                  ),
                  const SizedBox(width: 6),
                  RmButton.icon(
                    icon: const RmIcon('trash', size: 13),
                    tooltip: '删除声音预设',
                    foregroundColor: context.rm.danger,
                    onPressed: c.presetId == null ? null : () => _act(c.remove),
                  ),
                ],
              ),
              Divider(height: 22, color: context.rm.border),
              Row(
                children: [
                  _label('模型版本'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: RmSelect<String>(
                      value: c.version,
                      items: {for (final v in speechVersions) v: v},
                      onChanged: (v) => c.update('version', v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (_, box) => box.maxWidth >= 350
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _file('gpt_model', 'GPT 模型', 'gpt_label'),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _file(
                              'sovits_model',
                              'SoVITS 模型',
                              'sovits_label',
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _file('gpt_model', 'GPT 模型', 'gpt_label'),
                          const SizedBox(height: 8),
                          _file('sovits_model', 'SoVITS 模型', 'sovits_label'),
                        ],
                      ),
              ),
            ],
          ).tourAnchor('speech-models'),
          Divider(height: 22, color: context.rm.border),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('生成语言'),
                        RmSelect<String>(
                          value: '${c.data['text_lang']}',
                          items: speechLanguages,
                          onChanged: (v) => c.update('text_lang', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('参考语言'),
                        RmSelect<String>(
                          value: '${c.data['prompt_lang']}',
                          items: speechLanguages,
                          onChanged: (v) => c.update('prompt_lang', v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _file('ref_audio_path', '主参考音频 · 3–10 秒', 'reference_label'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _label('参考音频对应文本')),
                  RmTooltip(
                    message:
                        ['v3', 'v4', 'v5dev', 'v5turbo'].contains(c.version)
                        ? '此模型需要参考文本'
                        : '不使用参考文本，主参考音频仍然需要',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 25,
                          height: 25,
                          child: Transform.scale(
                            scale: .8,
                            child: Checkbox(
                              value: c.parameters['no_prompt'] == true,
                              onChanged:
                                  [
                                    'v3',
                                    'v4',
                                    'v5dev',
                                    'v5turbo',
                                  ].contains(c.version)
                                  ? null
                                  : (v) => c.parameter('no_prompt', v),
                            ),
                          ),
                        ),
                        Text(
                          '无需参考文本',
                          style: RmText.sans(11, color: context.rm.fg3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('speech-reference-text'),
                controller: _prompt,
                enabled: c.parameters['no_prompt'] != true,
                maxLines: 1,
                style: RmText.sans(12, color: context.rm.fg),
                decoration: rmFieldDecoration(context, hint: '与参考音频内容一致'),
                onChanged: (v) => c.update('prompt_text', v),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(child: _label('辅助参考音频')),
                  RmButton(
                    label: '添加参考',
                    size: RmButtonSize.md,
                    leading: const RmIcon('plus', size: 12),
                    onPressed: () => _act(() => _pickAuxiliary()),
                  ),
                ],
              ),
              for (
                var i = 0;
                i < (c.data['aux_ref_audio_paths'] as List).length;
                i++
              )
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _auxiliary(i),
                ),
            ],
          ).tourAnchor('speech-reference'),
          Divider(height: 22, color: context.rm.border),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '推理参数',
                    style: RmText.sans(
                      13,
                      color: context.rm.fg,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  RmButton(
                    label: '默认',
                    size: RmButtonSize.md,
                    onPressed: c.resetParameters,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SpeechParameterFields(configuration: c),
            ],
          ).tourAnchor('speech-parameters'),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: RmText.sans(11, color: context.rm.danger),
              ),
            ),
        ],
      );
    },
  );
}

class SpeechParameterFields extends StatefulWidget {
  const SpeechParameterFields({super.key, required this.configuration});
  final SpeechConfiguration configuration;
  @override
  State<SpeechParameterFields> createState() => _SpeechParameterFieldsState();
}

class _SpeechParameterFieldsState extends State<SpeechParameterFields> {
  final _fields = <String, TextEditingController>{};
  int _revision = -1;

  SpeechConfiguration get c => widget.configuration;
  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget _number(
    String key,
    String label,
    double min,
    double max,
    double step, {
    int decimals = 2,
  }) {
    final controller = _fields.putIfAbsent(
      key,
      () => TextEditingController(text: '${c.parameters[key]}'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: RmText.sans(11, color: context.rm.fg3)),
        const SizedBox(height: 4),
        SizedBox(
          height: 34,
          child: RmNumberField(
            key: ValueKey('speech-param-$key'),
            controller: controller,
            min: min,
            max: max,
            step: step,
            decimals: decimals,
            onChanged: (text) {
              final value = num.tryParse(text);
              c.parameter(key, value != null && value.isFinite ? value : text);
            },
          ),
        ),
      ],
    );
  }

  Widget _toggle(String key, String label, {bool enabled = true}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 26,
        height: 26,
        child: Transform.scale(
          scale: .8,
          child: Checkbox(
            value: c.parameters[key] == true,
            onChanged: enabled ? (v) => c.parameter(key, v) : null,
          ),
        ),
      ),
      Text(
        label,
        style: RmText.sans(
          11.5,
          color: enabled ? context.rm.fg2 : context.rm.fg4,
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (_, _) {
      if (_revision != c.revision) {
        for (final e in _fields.entries) {
          e.value.text = '${c.parameters[e.key]}';
        }
        _revision = c.revision;
      }
      final flow = ['v3', 'v4', 'v5dev', 'v5turbo'].contains(c.version);
      final external =
          speechMap(c.session.engine['connection'])['mode'] == 'existing';
      final controls = [
        _number('speed_factor', '语速', .1, 3, .05),
        _number('seed', '随机种子 · -1 随机', -1, 4294967295, 1, decimals: 0),
        _number('top_k', 'Top K', 1, 100, 1, decimals: 0),
        _number('top_p', 'Top P', .01, 1, .05),
        _number('temperature', 'Temperature', .01, 1, .05),
        _number('repetition_penalty', '重复惩罚', .01, 5, .05),
        _number('fragment_interval', '句间停顿 · 秒', .01, 1, .05),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('文本切分', style: RmText.sans(11, color: context.rm.fg3)),
            const SizedBox(height: 4),
            RmSelect<String>(
              value: '${c.parameters['text_split_method']}',
              items: speechSplitMethods,
              onChanged: (v) => c.parameter('text_split_method', v),
            ),
          ],
        ),
        if (flow)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('采样步数', style: RmText.sans(11, color: context.rm.fg3)),
              const SizedBox(height: 4),
              RmSelect<int>(
                value: (c.parameters['sample_steps'] as num).toInt(),
                items: const {4: '4', 8: '8', 16: '16', 32: '32'},
                onChanged: (v) => c.parameter('sample_steps', v),
              ),
            ],
          ),
        if (c.version.startsWith('v5')) _number('cfg_rate', 'CFG', 0, 2, .1),
        ...[
          _number('batch_size', '批次大小', 1, 200, 1, decimals: 0),
          _number('batch_threshold', '分批阈值', 0, 1, .05),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('推理设备', style: RmText.sans(11, color: context.rm.fg3)),
              const SizedBox(height: 4),
              RmSelect<String>(
                value: '${c.parameters['device']}',
                items: const {'cuda': 'CUDA 显卡', 'cpu': 'CPU'},
                onChanged: external ? null : (v) => c.parameter('device', v),
              ),
            ],
          ),
        ],
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, box) {
              final columns = ((box.maxWidth + 10) / 130).floor().clamp(1, 4);
              return Wrap(
                spacing: 10,
                runSpacing: 9,
                children: [
                  for (final field in controls)
                    SizedBox(
                      width: (box.maxWidth - 10 * (columns - 1)) / columns,
                      child: field,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 3,
            children: [
              if (c.version == 'v3') _toggle('super_sampling', '超采样'),
              ...[
                _toggle('is_half', '半精度', enabled: !external),
                _toggle('parallel_infer', '并行推理'),
                _toggle('split_bucket', '按长度分桶'),
              ],
            ],
          ),
          if (external)
            Text(
              '已有 API 的推理设备与精度由其启动配置决定。',
              style: RmText.sans(11, color: context.rm.fg3),
            ),
        ],
      );
    },
  );
}

Future<void> showSpeechConfigurationDialog(
  BuildContext context,
  SpeechGenerationSession session,
) async {
  final configuration = SpeechConfiguration(session);
  final selected = session.presets
      .where((p) => p['id'] == session.selectedPresetId)
      .firstOrNull;
  if (selected != null) configuration.load(selected);
  try {
    await showAudioEditorDialog<void>(
      context: context,
      builder: (ctx) => TimingDialogFrame(
        title: '声音与模型设置',
        icon: 'settings',
        busy: false,
        width: 860,
        description: '模型、参考音频和推理参数保存在声音预设中',
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .65,
          ),
          child: SingleChildScrollView(
            child: SpeechConfigurationPanel(configuration: configuration),
          ),
        ),
        actions: [
          RmButton(
            label: '完成',
            variant: RmButtonVariant.primary,
            leading: const RmIcon('check', size: 12),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  } finally {
    configuration.dispose();
  }
}
