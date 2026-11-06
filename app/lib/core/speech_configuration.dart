import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'speech_generation.dart';

const speechLanguages = {
  'all_zh': '中文',
  'all_ja': '日语',
  'en': '英语',
  'all_ko': '韩语',
  'all_yue': '粤语',
  'auto': '自动混合',
  'zh': '中英混合',
  'ja': '日英混合',
  'ko': '韩英混合',
  'yue': '粤英混合',
  'auto_yue': '自动混合（含粤语）',
};
const speechVersions = [
  'v1',
  'v2',
  'v2Pro',
  'v2ProPlus',
  'v3',
  'v4',
  'v5dev',
  'v5turbo',
];
const speechParameterDefaults = <String, dynamic>{
  'top_k': 15,
  'top_p': 1.0,
  'temperature': 1.0,
  'speed_factor': 1.0,
  'repetition_penalty': 1.35,
  'seed': -1,
  'fragment_interval': .3,
  'text_split_method': 'cut1',
  'batch_size': 1,
  'batch_threshold': .75,
  'parallel_infer': false,
  'split_bucket': false,
  'sample_steps': 32,
  'super_sampling': false,
  'no_prompt': false,
  'device': 'cuda',
  'is_half': true,
  'cfg_rate': 0.0,
};
const speechSplitMethods = {
  'cut0': '不切分',
  'cut1': '四句一切',
  'cut2': '约 50 字',
  'cut3': '按中文句号',
  'cut4': '按英文句号',
  'cut5': '按标点',
};

/// The editable working configuration is distinct from a named, saved preset.
class SpeechConfiguration extends ChangeNotifier {
  SpeechConfiguration(this.session) {
    data = session.configurationDraft == null
        ? _blank()
        : _clone(session.configurationDraft!);
    _initialized = session.configurationDraft != null;
    session.addListener(_sync);
    _sync();
  }
  final SpeechGenerationSession session;
  late Map<String, dynamic> data;
  bool _initialized = false;
  int revision = 0;
  static Map<String, dynamic> _clone(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)));
  static Map<String, dynamic> _blank() => {
    'name': '当前配置',
    'version': 'v2ProPlus',
    'gpt_model': '',
    'sovits_model': '',
    'ref_audio_path': '',
    'prompt_text': '',
    'prompt_lang': 'all_ja',
    'text_lang': 'all_ja',
    'aux_ref_audio_paths': <String>[],
    'parameters': {...speechParameterDefaults},
  };
  Map<String, dynamic> get parameters => speechMap(data['parameters']);
  String? get presetId => data['id'] as String?;
  String _editableState(Map<String, dynamic> value) {
    const keys = [
      'name',
      'version',
      'gpt_model',
      'sovits_model',
      'ref_audio_path',
      'prompt_text',
      'prompt_lang',
      'text_lang',
      'aux_ref_audio_paths',
    ];
    final merged = {
      ...speechParameterDefaults,
      ...speechMap(value['parameters']),
    };
    return jsonEncode([
      for (final key in keys) value[key],
      [for (final key in speechParameterDefaults.keys) merged[key]],
    ]);
  }

  bool get isDirty {
    final saved = session.presets.where((p) => p['id'] == presetId).firstOrNull;
    if (saved == null) return true;
    return _editableState(data) !=
        _editableState({
          ..._blank(),
          ...saved,
          'parameters': {
            ...speechParameterDefaults,
            ...speechMap(saved['parameters']),
          },
        });
  }

  String get version => '${data['version']}';
  bool get ready => [
    'gpt_model',
    'sovits_model',
    'ref_audio_path',
  ].every((k) => '${data[k] ?? ''}'.isNotEmpty);
  Map<String, dynamic> snapshot() => _clone(data);
  void _sync() {
    if (_initialized || session.state.isEmpty) return;
    _initialized = true;
    if (session.presets.isNotEmpty) {
      load(
        session.presets
                .where((p) => p['id'] == session.selectedPresetId)
                .firstOrNull ??
            session.presets.first,
      );
    }
  }

  void _changed() {
    session.configurationDraft = snapshot();
    notifyListeners();
  }

  void load(Map<String, dynamic> preset) {
    _initialized = true;
    data = {
      ..._blank(),
      ..._clone(preset),
      'parameters': {
        ...speechParameterDefaults,
        ...speechMap(preset['parameters']),
      },
    };
    revision++;
    if (presetId != null) session.selectPreset(presetId!);
    _changed();
  }

  void update(String key, dynamic value) {
    _initialized = true;
    data[key] = value;
    _changed();
  }

  void parameter(String key, dynamic value) {
    data['parameters'] = {...parameters, key: value};
    _changed();
  }

  void resetParameters() {
    data['parameters'] = {
      ...speechParameterDefaults,
      if (version == 'v5dev') 'cfg_rate': 1.3,
      if (version == 'v5turbo') 'sample_steps': 4,
    };
    revision++;
    _changed();
  }

  Future<void> save(String name, {bool asNew = false}) async {
    final before = snapshot();
    final beforeRevision = revision;
    final value = snapshot()..['name'] = name.trim();
    if (asNew) value.remove('id');
    await session.call('save-preset', value);
    final saved = session.presets
        .where((p) => p['name'] == name.trim())
        .lastOrNull;
    if (saved == null || revision != beforeRevision) return;
    if (_editableState(data) == _editableState(before)) {
      load(saved);
    } else {
      // Edits made while saving stay in the working copy and retain the star.
      data['id'] = saved['id'];
      data['name'] = saved['name'];
      _changed();
    }
  }

  Future<void> remove() async {
    if (presetId == null) return;
    await session.call('delete-preset', {'id': presetId});
    data.remove('id');
    data['name'] = '当前配置';
    _changed();
  }

  @override
  void dispose() {
    session.configurationDraft = snapshot();
    session.removeListener(_sync);
    super.dispose();
  }
}
