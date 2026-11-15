import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_number_field.dart';
import '../../widgets/timing_dialog_frame.dart';
import 'speech_engine_dialog.dart';
import '../../widgets/audio_editor_dialog.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/rm_tooltip.dart';
import '../../widgets/rm_field.dart';
import 'speech_parameter_help.dart';

const rvcDefaults = <String, dynamic>{
  'pitch': 0,
  'speaker_id': 0,
  'f0_method': 'rmvpe',
  'index_rate': .75,
  'protect': .33,
  'rms_mix_rate': .25,
  'filter_radius': 3,
};

class RvcConfigurationPanel extends StatefulWidget {
  const RvcConfigurationPanel({super.key, required this.session});
  final SpeechGenerationSession session;
  @override
  State<RvcConfigurationPanel> createState() => _RvcConfigurationPanelState();
}

class _RvcConfigurationPanelState extends State<RvcConfigurationPanel> {
  final _fields = <String, TextEditingController>{};
  Map<String, dynamic> _parameters = {...rvcDefaults};
  String? _message;
  bool _initialized = false;
  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    try {
      await widget.session.call(action, input);
      if (mounted) {
        setState(() => _message = null);
      }
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    }
  }

  void _change(String key, dynamic value) {
    _parameters[key] = value;
    unawaited(_call('save-parameters', {..._parameters}));
  }

  void _loadParameters() {
    _parameters = {
      ...rvcDefaults,
      ...speechMap(widget.session.engine['parameters']),
    };
    for (final entry in _fields.entries) {
      entry.value.text = '${_parameters[entry.key]}';
    }
  }

  Future<void> _applyPreset(String id) async {
    try {
      await widget.session.call('select-preset', {
        'id': id.isEmpty ? null : id,
      });
      if (mounted) {
        setState(() {
          _loadParameters();
          _message = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  Future<void> _savePreset({bool asNew = false}) async {
    final s = widget.session;
    final selected = s.presets
        .where((p) => p['id'] == s.engine['selected_preset_id'])
        .firstOrNull;
    var name = selected?['name'] as String?;
    if (asNew || selected == null) {
      final controller = TextEditingController(
        text: asNew && name != null ? '$name 副本' : '',
      );
      name = await showDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (dialog) => TimingDialogFrame(
          title: '保存 RVC 预设',
          icon: 'save',
          busy: false,
          width: 430,
          body: TextField(
            key: const ValueKey('rvc-preset-name'),
            controller: controller,
            autofocus: true,
            maxLength: 100,
            decoration: rmFieldDecoration(dialog, hint: '预设名称'),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(dialog, value.trim());
            },
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(dialog)),
            RmButton(
              label: '保存预设',
              variant: RmButtonVariant.primary,
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(dialog, controller.text.trim());
                }
              },
            ),
          ],
        ),
      );
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        controller.dispose,
      );
      if (name == null || !mounted) return;
    }
    try {
      await s.call('save-preset', {
        'name': name,
        if (!asNew && selected != null) 'id': selected['id'],
      });
      if (!mounted) return;
      setState(() => _message = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('RVC 预设“$name”已保存。')));
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  Future<void> _import(String kind) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [kind == 'model' ? 'pth' : 'index'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final response = await widget.session.call('import-file', {
        'kind': kind,
        'path': path,
      });
      final file = speechMap(response['imported_file']);
      final selected = speechMap(widget.session.engine['selection']);
      if (kind == 'model' || selected['model_id'] != null) {
        await _call('select-model', {
          'model_id': kind == 'model' ? file['id'] : selected['model_id'],
          'index_id': kind == 'index' ? file['id'] : null,
        });
      }
      if (mounted) setState(() => _message = '已导入 ${file['filename']}');
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    }
  }

  Widget _label(String text, {String? help}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: help == null
        ? Text(text, style: RmText.sans(12, color: context.rm.fg2))
        : SpeechParameterLabel(label: text, help: help, size: 12),
  );
  Widget _fileRow(
    String kind,
    Map<String, dynamic> selection,
    List<Map<String, dynamic>> files,
  ) {
    final list = files.where((f) => f['kind'] == kind).toList();
    final value = '${selection['${kind}_id'] ?? ''}';
    return Row(
      children: [
        Expanded(
          child: RmSelect<String>(
            value: list.any((f) => f['id'] == value) ? value : '',
            items: {
              '': kind == 'model' ? '请选择音色模型' : '不使用索引',
              for (final f in list) '${f['id']}': '${f['filename']}',
            },
            onChanged: widget.session.busy
                ? null
                : (id) => _call('select-model', {
                    'model_id': kind == 'model' ? id : selection['model_id'],
                    'index_id': kind == 'index'
                        ? (id.isEmpty ? null : id)
                        : selection['index_id'],
                  }),
          ),
        ),
        const SizedBox(width: 8),
        RmButton(
          label: '导入',
          leading: const RmIcon('folder', size: 12),
          onPressed: () => _import(kind),
        ),
        if (value.isNotEmpty) ...[
          const SizedBox(width: 6),
          RmButton.icon(
            icon: const RmIcon('trash', size: 12),
            tooltip: '移除托管副本，保留外部原文件',
            onPressed: widget.session.busy
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      useRootNavigator: false,
                      builder: (ctx) => TimingDialogFrame(
                        title: '删除导入文件？',
                        busy: false,
                        width: 420,
                        body: const Text('将移除应用中的模型或索引副本，已生成的音频和外部原文件保留。'),
                        actions: [
                          RmButton(
                            label: '取消',
                            onPressed: () => Navigator.pop(ctx, false),
                          ),
                          RmButton(
                            label: '删除',
                            onPressed: () => Navigator.pop(ctx, true),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await _call('delete-model', {'id': value});
                    }
                  },
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (_, _) {
      final s = widget.session,
          engine = s.engine,
          selection = speechMap(engine['selection']);
      if (!_initialized && engine['parameters'] is Map) {
        _parameters = {...rvcDefaults, ...speechMap(engine['parameters'])};
        _initialized = true;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('RVC 预设'),
          Row(
            children: [
              Expanded(
                child: RmSelect<String>(
                  key: const ValueKey('rvc-preset'),
                  value: '${engine['selected_preset_id'] ?? ''}',
                  items: {
                    '': '当前配置 · 未保存',
                    for (final p in s.presets)
                      '${p['id']}':
                          '${p['name']}${p['id'] == engine['selected_preset_id'] && engine['preset_dirty'] == true ? ' *' : ''}',
                    '__new__': '另存为新预设…',
                  },
                  onChanged: s.busy
                      ? null
                      : (id) => id == '__new__'
                            ? _savePreset(asNew: true)
                            : _applyPreset(id),
                ),
              ),
              const SizedBox(width: 6),
              RmButton(
                key: const ValueKey('rvc-save-preset'),
                label: '保存预设',
                variant: RmButtonVariant.primary,
                leading: const RmIcon('save', size: 12),
                onPressed: s.busy || selection['model_id'] == null
                    ? null
                    : _savePreset,
              ),
              const SizedBox(width: 6),
              RmButton.icon(
                key: const ValueKey('rvc-delete-preset'),
                icon: const RmIcon('trash', size: 12),
                foregroundColor: context.rm.danger,
                tooltip: '删除 RVC 预设，保留模型、索引与音频',
                onPressed: s.busy || engine['selected_preset_id'] == null
                    ? null
                    : () => _call('delete-preset', {
                        'id': engine['selected_preset_id'],
                      }),
              ),
            ],
          ),
          Divider(height: 22, color: context.rm.border),
          _label('推理设备', help: rvcParameterHelp['device']),
          RmSelect<String>(
            key: const ValueKey('rvc-inference-device'),
            value: '${speechMap(engine['runtime'])['device'] ?? 'cpu'}',
            items: const {'cpu': 'CPU · 通用', 'cuda:0': 'CUDA · NVIDIA 显卡'},
            onChanged: s.busy
                ? null
                : (device) async {
                    await _call('configure-runtime', {'device': device});
                  },
          ),
          if (engine['installed'] != true) ...[
            const SizedBox(height: 6),
            Text(
              '当前设备的推理依赖尚未就绪，请在推理引擎中安装或修复。',
              style: RmText.sans(11, color: context.rm.fg3),
            ),
          ],
          const SizedBox(height: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('音色模型 · RVC v1 / v2'),
              _fileRow('model', selection, speechMaps(engine['files'])),
              const SizedBox(height: 12),
              RmTooltip(
                message:
                    '选择与音色模型配套的 .index，用训练音频特征辅助转换，减少原说话人音色残留。检索比例控制参与程度，过高可能带入训练数据的瑕疵。',
                child: _label('关联索引 · 可选'),
              ),
              _fileRow('index', selection, speechMaps(engine['files'])),
              const SizedBox(height: 6),
              Text(
                '索引需与音色模型配套；没有索引也能转换。',
                style: RmText.sans(11, color: context.rm.fg3),
              ),
            ],
          ).tourAnchor('rvc-models'),
          Divider(height: 24, color: context.rm.border),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '转换参数',
                      style: RmText.sans(
                        14,
                        weight: FontWeight.w600,
                        color: context.rm.fg,
                      ),
                    ),
                  ),
                  RmButton(
                    label: '默认',
                    onPressed: () {
                      setState(() {
                        _parameters = {...rvcDefaults};
                        for (final e in _fields.entries) {
                          e.value.text = '${_parameters[e.key]}';
                        }
                      });
                      _call('save-parameters', _parameters);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _label('音高提取', help: rvcParameterHelp['f0_method']),
              RmSelect<String>(
                value: '${_parameters['f0_method']}',
                items: const {
                  'rmvpe': 'RMVPE',
                  'harvest': 'Harvest',
                  'pm': 'PM',
                },
                onChanged: (v) {
                  setState(() => _change('f0_method', v));
                },
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (_, box) {
                  final columns = box.maxWidth >= 620
                      ? 4
                      : box.maxWidth >= 270
                      ? 2
                      : 1;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final spec
                          in <(String, String, double, double, double, int)>[
                            ('pitch', '变调 · 半音', -24, 24, 1, 0),
                            ('speaker_id', '说话人编号 · 默认0', 0, 1023, 1, 0),
                            ('index_rate', '检索比例', 0, 1, .05, 2),
                            ('protect', '辅音保护 · 0.5关闭', 0, .5, .01, 2),
                            ('rms_mix_rate', '原音/结果音量包络', 0, 1, .05, 2),
                            ('filter_radius', 'Harvest滤波半径', 0, 7, 1, 0),
                          ])
                        SizedBox(
                          width: (box.maxWidth - (columns - 1) * 10) / columns,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _label(spec.$2, help: rvcParameterHelp[spec.$1]),
                              RmNumberField(
                                controller: _fields.putIfAbsent(
                                  spec.$1,
                                  () => TextEditingController(
                                    text: '${_parameters[spec.$1]}',
                                  ),
                                ),
                                min: spec.$3,
                                max: spec.$4,
                                step: spec.$5,
                                decimals: spec.$6,
                                enabled:
                                    spec.$1 != 'filter_radius' ||
                                    _parameters['f0_method'] == 'harvest',
                                onChanged: (v) {
                                  final number = num.tryParse(v);
                                  if (number != null) _change(spec.$1, number);
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                '0半音保留原音高起伏；降低辅音保护数值可加强保护。',
                style: RmText.sans(11, color: context.rm.fg3),
              ),
            ],
          ).tourAnchor('rvc-parameters'),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _message!,
                style: RmText.sans(11, color: context.rm.fg2),
              ),
            ),
        ],
      );
    },
  );
}

Future<void> showRvcEngineDialog(
  BuildContext context,
  SpeechGenerationSession session,
) => showSpeechEngineDialog(context, session, conversion: true);

Future<void> showRvcConfigurationDialog(
  BuildContext context,
  SpeechGenerationSession session,
) => showAudioEditorDialog<void>(
  context: context,
  builder: (ctx) => TimingDialogFrame(
    title: 'RVC 音色与参数',
    icon: 'settings',
    busy: false,
    width: 620,
    body: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 540),
      child: SingleChildScrollView(
        child: RvcConfigurationPanel(session: session),
      ),
    ),
    actions: [
      RmButton(
        label: '推理引擎',
        onPressed: () async {
          Navigator.pop(ctx);
          await Future<void>.delayed(Duration.zero);
          if (context.mounted) await showRvcEngineDialog(context, session);
        },
      ),
      RmButton(
        label: '完成',
        variant: RmButtonVariant.primary,
        onPressed: () => Navigator.pop(ctx),
      ),
    ],
  ),
);
