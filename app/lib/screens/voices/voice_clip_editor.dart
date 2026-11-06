import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../widgets/rm_tooltip.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import '../../core/studio_audio_players.dart';
import '../../core/voice_audition.dart';
import '../../widgets/rm_number_field.dart';
import '../../core/waveform_zoom.dart';
import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/editor_controls.dart';
import '../../widgets/feature_tour.dart';
import '../../widgets/editor_columns.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_field.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_slider.dart';
import '../../widgets/timing_dialog_frame.dart';
import '../replace_editor/manual_focus_waveform.dart';
import '../replace_editor/waveform_overview.dart';
import '../stingers/stinger_models.dart';

/// Shared non-destructive material editor. Rendering uses the Python audio path.
class VoiceClipEditorController extends ChangeNotifier {
  Object? _owner;
  Future<void> Function()? _toggle;
  VoidCallback? undo, redo;
  Future<void> Function()? restore;
  bool playing = false, busy = true;
  Future<void> toggle() async {
    if (!busy) await _toggle?.call();
  }

  void _bind(Object owner, Future<void> Function() toggle) {
    _owner = owner;
    _toggle = toggle;
    busy = true;
    undo = redo = null;
    restore = null;
  }

  void _unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _toggle = null;
    undo = redo = null;
    restore = null;
  }

  void _sync(
    Object owner,
    bool nextPlaying,
    bool nextBusy,
    VoidCallback? nextUndo,
    VoidCallback? nextRedo,
    Future<void> Function()? nextRestore,
  ) {
    if (!identical(_owner, owner)) return;
    final changed =
        playing != nextPlaying ||
        busy != nextBusy ||
        (undo == null) != (nextUndo == null) ||
        (redo == null) != (nextRedo == null) ||
        (restore == null) != (nextRestore == null);
    playing = nextPlaying;
    busy = nextBusy;
    undo = nextUndo;
    redo = nextRedo;
    restore = nextRestore;
    if (changed) notifyListeners();
  }
}

class VoiceClipEditor extends StatefulWidget {
  const VoiceClipEditor({
    super.key,
    required this.asset,
    required this.folders,
    required this.load,
    this.render,
    this.initial,
    this.metadata = true,
    this.targetDuration,
    this.title,
    this.preferredWidth = 1080,
    this.featureTour = false,
    this.embedded = false,
    this.onChanged,
    this.replacementInline = false,
    this.controller,
    this.empty = false,
  });
  final Map<String, dynamic> asset;
  final Map<String, dynamic>? initial;
  final List<String> folders;
  final Future<Map<String, dynamic>> Function() load;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? render;
  final bool metadata;
  final double? targetDuration;
  final String? title;
  final double preferredWidth;
  final bool featureTour;
  final bool embedded;
  final ValueChanged<Map<String, dynamic>>? onChanged;
  final bool replacementInline;
  final bool empty;
  final VoiceClipEditorController? controller;
  @override
  State<VoiceClipEditor> createState() => _VoiceClipEditorState();
}

class _VoiceClipEditorState extends State<VoiceClipEditor> {
  static _VoiceClipEditorState? _playbackOwner;
  late final TextEditingController _name;
  final _newFolderName = TextEditingController(),
      _silenceMs = TextEditingController(text: '100');
  late String _folder;
  late double _a, _b, _gain;
  List<Map<String, dynamic>> _operations = [];
  bool _addingFolder = false,
      _loading = true,
      _starting = false,
      _playing = false;
  bool _keepDuration = false;
  String? _error;
  Map<String, dynamic> _wave = {};
  Map<String, dynamic>? _barsWave;
  WaveformBars? _waveBars;
  WaveformBars get _bars {
    if (!identical(_barsWave, _wave)) {
      _barsWave = _wave;
      _waveBars = WaveformBars.fromValues(
        ((_wave['bins'] as List?) ?? []).map((e) => stingerNumber(e)).toList(),
      );
    }
    return _waveBars!;
  }

  final _folders = <String>{'未分类'};
  final _undo = <Map<String, dynamic>>[], _redo = <Map<String, dynamic>>[];
  double _window = 0, _span = 0, _position = 0, _waveWidth = 600;
  double? _selectionA, _selectionB;
  double? _playEnd;
  Player? _player;
  StreamSubscription<Duration>? _positions;
  StreamSubscription<bool>? _completions;
  StreamSubscription<bool>? _playingEvents;
  int _generation = 0;
  double get _duration => stingerNumber(_wave['duration'], _b - _a);
  double get _viewSpan => _span <= 0 ? _duration : _span;
  bool get _hasSelection =>
      _selectionA != null && _selectionB! - _selectionA! > 1 / 48000;
  Map<String, dynamic> get _snapshot => {
    'start': _a,
    'end': _b,
    'gain_db': _gain,
    'keep_duration': _keepDuration,
    'audio_edits': [
      for (final op in _operations) Map<String, dynamic>.from(op),
    ],
    'name': _name.text,
    'category': _folder,
    'edited_duration': _duration,
  };
  void _publish() => widget.onChanged?.call({..._snapshot, 'wave': _wave});

  @override
  void initState() {
    super.initState();
    widget.controller?._bind(this, _play);
    final edit = widget.initial ?? widget.asset;
    _keepDuration = edit['keep_duration'] == true;
    _a = stingerNumber(edit['start']);
    _b = stingerNumber(edit['end'], stingerNumber(widget.asset['duration']));
    _gain = stingerNumber(edit['gain_db']);
    _operations = stingerMaps(edit['audio_edits']);
    _name = TextEditingController(text: '${widget.asset['name']}');
    _folder = '${widget.asset['category'] ?? '未分类'}';
    _folders.addAll([...widget.folders, _folder]);
    for (final f in _folders.toList()) {
      final parts = f.split('/');
      for (var i = 1; i < parts.length; i++) {
        _folders.add(parts.take(i).join('/'));
      }
    }
    if (!widget.empty) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var wave = await widget.load();
      if (!mounted) return;
      if (widget.render != null &&
          (_operations.isNotEmpty ||
              _a != 0 ||
              (_b - stingerNumber(widget.asset['duration'])).abs() > .0001)) {
        wave = await widget.render!({..._snapshot, 'gain_db': 0});
      }
      if (!mounted) return;
      if ((wave['bins'] as List?)?.isNotEmpty != true ||
          stingerNumber(wave['duration']) <= 0) {
        throw const FormatException('未能读取素材波形。');
      }
      setState(() {
        _wave = wave;
        _loading = false;
      });
      _publish();
      unawaited(_preparePlayback());
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e'.replaceFirst('FormatException: ', '');
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant VoiceClipEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._unbind(this);
      widget.controller?._bind(this, _play);
    }
  }

  Future<void> _preparePlayback() async {
    final generation = _generation;
    _playbackOwner = this;
    try {
      await prepareVoiceAudition(
        _player ??= StudioAudioPlayers.material,
        '${_wave['path']}',
        start: _position,
        gainDb: _gain,
        isCurrent: () =>
            mounted &&
            generation == _generation &&
            identical(_playbackOwner, this),
      );
    } on Object {
      // The play action reports output-device errors; preparing is optional.
    }
  }

  @override
  void dispose() {
    widget.controller?._unbind(this);
    _generation++;
    _positions?.cancel();
    _completions?.cancel();
    _playingEvents?.cancel();
    if (identical(_playbackOwner, this)) {
      _playbackOwner = null;
      if (_player != null) unawaited(_player!.pause());
    }
    _name.dispose();
    _newFolderName.dispose();
    _silenceMs.dispose();
    super.dispose();
  }

  void _checkpoint() {
    _undo.add({..._snapshot, 'wave': _wave, 'position': _position});
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
  }

  void _history(bool redo) {
    final from = redo ? _redo : _undo, to = redo ? _undo : _redo;
    if (from.isEmpty || _loading) return;
    to.add({..._snapshot, 'wave': _wave, 'position': _position});
    final old = from.removeLast();
    _stop();
    setState(() {
      _a = stingerNumber(old['start']);
      _b = stingerNumber(old['end']);
      _gain = stingerNumber(old['gain_db']);
      _operations = stingerMaps(old['audio_edits']);
      _wave = stingerMap(old['wave']);
      _position = stingerNumber(old['position']);
      _window = 0;
      _span = 0;
      _keepDuration = old['keep_duration'] == true;
      _name.text = '${old['name']}';
      _folder = '${old['category']}';
      _selectionA = _selectionB = null;
      _error = null;
    });
    _publish();
  }

  Future<void> _restoreAudio() async {
    if (_loading) return;
    _stop();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wave = await widget.load();
      if (!mounted) return;
      _checkpoint();
      setState(() {
        _a = 0;
        _b = stingerNumber(widget.asset['duration']);
        _operations = [];
        _wave = wave;
        _gain = 0;
        _position = _window = _span = 0;
        _selectionA = _selectionB = null;
      });
      _publish();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('FormatException: ', ''));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _operation(String kind) async {
    if (_loading || _starting || _wave.isEmpty || widget.render == null) return;
    if (kind != 'insert' && !_hasSelection) return;
    final milliseconds = double.tryParse(_silenceMs.text);
    if (kind == 'insert' &&
        (milliseconds == null || !milliseconds.isFinite || milliseconds <= 0)) {
      setState(() => _error = '请输入大于 0 的静音时长（毫秒）。');
      return;
    }
    final operation = kind == 'insert'
        ? <String, dynamic>{
            'kind': kind,
            'at': _position,
            'duration': milliseconds! / 1000,
          }
        : <String, dynamic>{
            'kind': kind,
            'start': _selectionA,
            'end': _selectionB,
          };
    final ops = [..._operations, operation];
    _stop();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wave = await widget.render!({
        ..._snapshot,
        'audio_edits': ops,
        'gain_db': 0,
      });
      if (!mounted) return;
      _checkpoint();
      setState(() {
        if (kind == 'insert') {
          _position += milliseconds! / 1000;
        }
        _operations = ops;
        _wave = wave;
        _position = _position.clamp(0, _duration);
        _selectionA = _selectionB = null;
        _window = 0;
        _span = 0;
      });
      _publish();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('FormatException: ', ''));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _seek(double time) {
    _generation++;
    _playEnd = null;
    setState(() {
      _position = time.clamp(0, _duration);
      _selectionA = _selectionB = null;
    });
    if (_player != null && !_starting) {
      unawaited(_seekPlayer(_position));
    }
  }

  Future<void> _seekPlayer(double position) async {
    final player = _player!;
    final native = player.platform;
    if (native is NativePlayer) await native.setProperty('end', 'none');
    await player.seek(Duration(microseconds: (position * 1e6).round()));
  }

  void _zoom(double factor) {
    final bins = (_wave['bins'] as List?)?.length ?? 0;
    final next = (_viewSpan * factor)
        .clamp(
          minimumWaveformSpan(
            duration: _duration,
            bins: bins,
            width: _waveWidth,
          ),
          _duration,
        )
        .toDouble();
    final anchor = _position.clamp(_window, _window + _viewSpan);
    final fraction = _viewSpan > 0 ? (anchor - _window) / _viewSpan : .5;
    setState(() {
      _window = (anchor - next * fraction).clamp(
        0,
        math.max(0, _duration - next),
      );
      _span = next;
    });
  }

  void _stop() {
    _generation++;
    if (_player != null && identical(_playbackOwner, this)) {
      unawaited(_player!.pause());
    }
    _playing = false;
  }

  Future<void> _play() async {
    if (_starting || _loading || _wave.isEmpty) return;
    if (_playing && _player?.state.completed != true) {
      setState(_stop);
      return;
    }
    final request = ++_generation;
    _playbackOwner = this;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final player = _player ??= StudioAudioPlayers.material;
      _playingEvents ??= player.stream.playing.listen((playing) {
        if (!playing &&
            mounted &&
            identical(_playbackOwner, this) &&
            _playing &&
            !_starting &&
            !player.state.completed) {
          setState(() => _playing = false);
        }
      });
      _positions ??= player.stream.position.listen((position) {
        if (!mounted || !_playing || !identical(_playbackOwner, this)) return;
        final seconds = position.inMicroseconds / 1e6;
        if (_playEnd case final end? when seconds >= end) {
          unawaited(player.pause());
          setState(() {
            _position = end;
            _playing = false;
          });
        } else {
          setState(() => _position = seconds.clamp(0, _duration));
        }
      });
      _completions ??= player.stream.completed.listen((done) {
        if (done &&
            mounted &&
            identical(_playbackOwner, this) &&
            _playing &&
            !_starting &&
            !_loading) {
          unawaited(_finishPlayback(_generation));
        }
      });
      _playEnd = _hasSelection ? _selectionB : null;
      await StudioAudioPlayers.pauseOthers(player);
      await startVoiceAudition(
        player,
        '${_wave['path']}',
        start: _hasSelection
            ? _selectionA!
            : (player.state.completed || _position >= _duration - .002
                  ? 0
                  : _position),
        // Only a selected region has an end limit; seeking clears it explicitly.
        end: _playEnd,
        gainDb: _gain,
        isCurrent: () =>
            mounted &&
            request == _generation &&
            identical(_playbackOwner, this),
      );
      if (mounted && request == _generation) {
        setState(() => _playing = true);
        if (player.state.completed) unawaited(_finishPlayback(request));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = '试听失败：$e';
        });
      }
    }
    if (mounted) setState(() => _starting = false);
  }

  void _save() {
    if (_loading || _starting || _wave.isEmpty) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请输入素材名称。');
      return;
    }
    final value = {..._snapshot, 'name': _name.text.trim(), 'wave': _wave};
    if (widget.embedded) {
      widget.onChanged?.call(value);
    } else {
      Navigator.pop(context, value);
    }
  }

  Future<void> _finishPlayback(int generation) async {
    final end = _playEnd ?? _duration;
    bool current() =>
        mounted &&
        generation == _generation &&
        _playing &&
        identical(_playbackOwner, this);
    try {
      await waitForVoiceTail(_player!, end, isCurrent: current);
    } on Object {
      if (!current()) return;
    }
    if (current()) {
      setState(() {
        _position = end;
        _playing = false;
      });
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance, key = event.logicalKey;
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyS) {
      _save();
      return KeyEventResult.handled;
    }
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null) {
      return KeyEventResult.ignored;
    }
    if (keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyY)) {
      _history(key == LogicalKeyboardKey.keyY);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      unawaited(_play());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete && _hasSelection) {
      unawaited(_operation('delete'));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _addFolder() {
    final name = _newFolderName.text.trim();
    if (name.isEmpty ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(name) ||
        name == '.' ||
        name == '..') {
      setState(() => _error = '请输入不含路径符号的文件夹名称。');
      return;
    }
    _checkpoint();
    setState(() {
      _folder = _folder == '未分类' ? name : '$_folder/$name';
      _folders.add(_folder);
      _addingFolder = false;
      _newFolderName.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.controller?._sync(
            this,
            _playing,
            _loading || _starting,
            _loading || _undo.isEmpty ? null : () => _history(false),
            _loading || _redo.isEmpty ? null : () => _history(true),
            _loading ? null : _restoreAudio,
          );
        }
      });
    }
    if (widget.replacementInline) {
      return Focus(
        onKeyEvent: _key,
        child: LayoutBuilder(
          builder: (_, box) {
            final tools = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_error != null)
                      RmTooltip(
                        message: _error!,
                        child: SizedBox.square(
                          dimension: 32,
                          child: Center(
                            child: RmIcon(
                              'info',
                              size: 13,
                              color: context.rm.danger,
                            ),
                          ),
                        ),
                      ),
                    EditorHistoryButtons(
                      onUndo: _undo.isEmpty || widget.empty
                          ? null
                          : () => _history(false),
                      onRedo: _redo.isEmpty || widget.empty
                          ? null
                          : () => _history(true),
                    ),
                    const SizedBox(width: 6),
                    RmButton(
                      label: '恢复原音',
                      leading: const RmIcon('reset', size: 12),
                      onPressed: widget.empty || _loading
                          ? null
                          : _restoreAudio,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _compactEdits(),
                const SizedBox(height: 4),
                _compactVolume(),
              ],
            );
            final wave = _waveform(
              canvasHeight: 116,
              showOverview: false,
              showHeader: false,
            );
            return box.maxWidth >= 500
                ? EditorColumns(
                    main: wave,
                    side: Align(alignment: Alignment.center, child: tools),
                    sideWidth: 240,
                    gap: 10,
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [wave, const SizedBox(height: 8), tools],
                  );
          },
        ),
      );
    }
    if (widget.embedded) {
      return Focus(
        onKeyEvent: _key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _waveform(canvasHeight: 112),
            const SizedBox(height: 8),
            _transport(),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (_, box) => EditorWaveformPanel(
                child: box.maxWidth >= 880
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(flex: 3, child: _compactEdits()),
                          const SizedBox(width: 16),
                          Expanded(flex: 2, child: _compactVolume()),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _compactEdits(),
                          const SizedBox(height: 6),
                          _compactVolume(),
                        ],
                      ),
              ),
            ),
            if (_error != null)
              Text(_error!, style: RmText.sans(11, color: context.rm.danger)),
          ],
        ),
      );
    }
    final editor = Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: TimingDialogFrame(
        title: widget.title ?? '语音素材',
        icon: 'volume',
        width: widget.preferredWidth,
        editorStyle: true,
        bodyPadding: const EdgeInsets.all(12),
        busy: _loading || _starting,
        description: '左键定位播放 · 右键拖动选区 · 原素材保留',
        headerActions: [
          _icon('zoom-out', '缩小', _wave.isEmpty ? null : () => _zoom(1.5)),
          _icon(
            'zoom-in',
            '放大 · Ctrl+滚轮',
            _wave.isEmpty ? null : () => _zoom(1 / 1.5),
          ),
        ],
        body: LayoutBuilder(
          builder: (context, box) {
            final main = Column(
              key: const ValueKey('material-main-column'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _waveform(canvasHeight: 132).tourAnchor('wave'),
                const SizedBox(height: 10),
                _transport().tourAnchor('transport'),
                const SizedBox(height: 10),
                EditorWaveformPanel(
                  key: const ValueKey('material-edit-panel'),
                  child: _editControls(),
                ).tourAnchor('edits'),
              ],
            );
            final settings = Container(
              key: const ValueKey('material-settings-panel'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.rm.raised,
                border: Border.all(color: context.rm.border),
                borderRadius: BorderRadius.circular(RmTokens.rLg),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '素材设置',
                      style: RmText.sans(
                        13,
                        color: context.rm.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _metadata(),
                    Divider(height: 24, color: context.rm.border),

                    _volume(),
                  ],
                ),
              ),
            );
            if (box.maxWidth >= 860) {
              return EditorColumns(
                main: main,
                side: settings.tourAnchor('settings'),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                main,
                const SizedBox(height: 10),
                settings.tourAnchor('settings'),
              ],
            );
          },
        ),
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Text(_error!, style: RmText.sans(11, color: context.rm.danger)),
              const SizedBox(height: 6),
            ],
            const EditorShortcutHints(
              hints: [
                'Space 播放 / 暂停',
                'Delete 删除选区',
                'Ctrl + Z 撤销',
                'Ctrl + Y 重做',
                'Ctrl + S 保存',
              ],
            ),
          ],
        ),
        actions: [
          RmButton(label: '取消', onPressed: () => Navigator.pop(context)),
          RmButton(
            label: widget.metadata ? '保存素材' : '应用替换',
            leading: const RmIcon('check', size: 12),
            variant: RmButtonVariant.primary,
            onPressed: _loading || _wave.isEmpty ? null : _save,
          ).tourAnchor('confirm'),
        ],
      ),
    );
    return widget.featureTour
        ? editor.withFeatureTour(
            widget.metadata
                ? TourPage.voiceMaterial
                : TourPage.voiceReplacementEditor,
            enabled: !_loading && _wave.isNotEmpty,
          )
        : editor;
  }

  Widget _waveform({
    double canvasHeight = 132,
    bool showOverview = true,
    bool showHeader = true,
  }) => EditorWaveformPanel(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          Row(
            children: [
              Expanded(
                child: Text(
                  _hasSelection
                      ? '选区 ${stingerTime(_selectionA)} – ${stingerTime(_selectionB)} · ${stingerTime(_selectionB! - _selectionA!)}'
                      : '素材波形 · 右键拖动选择区域',
                  key: const ValueKey('material-selection-status'),
                  style: RmText.sans(11.5, color: context.rm.fg3),
                  maxLines: 1,
                ),
              ),
              if (widget.embedded || widget.replacementInline) ...[
                _icon(
                  'zoom-out',
                  '缩小',
                  _wave.isEmpty ? null : () => _zoom(1.5),
                ),
                const SizedBox(width: 4),
                _icon(
                  'zoom-in',
                  '放大 · Ctrl+滚轮',
                  _wave.isEmpty ? null : () => _zoom(1 / 1.5),
                ),
              ],
            ],
          ),
        if (showHeader) const SizedBox(height: 6),
        if (_wave.isNotEmpty) ...[
          LayoutBuilder(
            builder: (context, box) {
              _waveWidth = box.maxWidth;
              return ManualFocusWaveform(
                key: const ValueKey('voice-clip-waveform'),
                bars: _bars,
                beats: const [],
                segments: const [],
                duration: _duration,
                accent: context.rm.accent.base,
                handles: const [],
                free: true,
                locked: _loading || _starting,
                playhead: _position,
                canvasHeight: canvasHeight,
                windowStart: _window,
                windowEnd: math.min(_duration, _window + _viewSpan),
                onZoom: _zoom,
                timeGrid: true,
                selectionStart: _selectionA,
                selectionEnd: _selectionB,
                onPlace: (_, {required isMove}) {},
                onSeek: _seek,
                onSelection: (a, b) => setState(() {
                  _selectionA = math.min(a, b);
                  _selectionB = math.max(a, b);
                }),
              );
            },
          ),
          if (showOverview) ...[
            const SizedBox(height: 6),
            WaveformOverview(
              key: const ValueKey('voice-clip-overview'),
              height: 32,
              bars: _bars,
              duration: _duration,
              windowStart: _window,
              windowEnd: math.min(_duration, _window + _viewSpan),
              onWindowStart: (v) => setState(() => _window = v),
            ),
          ],
        ] else if (widget.empty)
          ManualFocusWaveform(
            key: const ValueKey('voice-empty-waveform'),
            bars: _bars,
            beats: const [],
            segments: const [],
            duration: 1,
            accent: context.rm.fg4,
            handles: const [],
            free: false,
            locked: true,
            canvasHeight: canvasHeight,
            timeGrid: true,
            showTimeAxis: false,
            onPlace: (_, {required isMove}) {},
          )
        else
          SizedBox(
            // Match the waveform canvas, flag padding, gap and time axis while
            // loading. A shorter placeholder shrinks the right-hand controls.
            height: widget.replacementInline ? canvasHeight + 24 : 150,
            child: Center(
              child: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : RmButton(
                      label: '重新读取波形',
                      onPressed: () => unawaited(_load()),
                    ),
            ),
          ),
      ],
    ),
  );

  Widget _transport() => EditorTransport(
    key: const ValueKey('material-transport'),
    playing: _playing,
    onPlay: _loading || _starting ? null : _play,
    position: Text(
      '${stingerTime(_position)} / ${stingerTime(_duration)}',
      style: RmText.mono(12, color: context.rm.fg2),
    ),
    onUndo: _loading || _undo.isEmpty ? null : () => _history(false),
    onRedo: _loading || _redo.isEmpty ? null : () => _history(true),
    inlineBreakpoint: 500,
    actions: [
      RmButton(
        label: '恢复原音',
        leading: const RmIcon('reset', size: 12),
        onPressed:
            _loading ||
                (_operations.isEmpty &&
                    _a == 0 &&
                    (_b - stingerNumber(widget.asset['duration'])).abs() <
                        .0001 &&
                    _gain == 0)
            ? null
            : _restoreAudio,
      ),
    ],
  );

  Widget _silenceDuration() => SizedBox(
    height: 32,
    child: RmNumberField(
      key: const ValueKey('material-silence-ms'),
      enabled: !widget.empty,
      controller: _silenceMs,
      min: 50,
      max: 3600000,
      step: 50,
      decimals: 0,
      unit: 'ms',
    ),
  );

  Widget _editControls() => LayoutBuilder(
    builder: (context, box) {
      final insert = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('静音时长', style: RmText.sans(12, color: context.rm.fg2)),
          const SizedBox(width: 8),
          SizedBox(width: 112, child: _silenceDuration()),
          const SizedBox(width: 8),
          RmButton(
            key: const ValueKey('material-insert-silence'),
            label: '插入静音',
            leading: const RmIcon('plus', size: 12),
            onPressed: _loading || _starting || widget.empty || _wave.isEmpty
                ? null
                : () => _operation('insert'),
          ),
        ],
      );
      final selection = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RmButton(
            key: const ValueKey('material-silence-selection'),
            label: '选区静音',
            leading: const RmIcon('volume-x', size: 12),
            onPressed: !_hasSelection || _loading
                ? null
                : () => _operation('silence'),
          ),
          const SizedBox(width: 8),
          RmButton(
            key: const ValueKey('material-delete-selection'),
            label: '删除选区',
            leading: const RmIcon('trash', size: 12),
            onPressed: !_hasSelection || _loading
                ? null
                : () => _operation('delete'),
          ),
        ],
      );
      return Column(
        key: const ValueKey('material-edit-actions'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (box.maxWidth >= 570)
            Row(children: [insert, const Spacer(), selection])
          else ...[
            Align(alignment: Alignment.centerLeft, child: insert),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: selection),
          ],
          const SizedBox(height: 7),
          Text(
            '在当前播放位置插入静音；右键拖动波形选择要处理的区域。',
            style: RmText.sans(11, color: context.rm.fg3, height: 1.5),
          ),
        ],
      );
    },
  );

  Widget _compactEdits() => LayoutBuilder(
    builder: (_, box) {
      final duration = _silenceDuration();
      final insert = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('静音', style: RmText.sans(11.5, color: context.rm.fg3)),
          const SizedBox(width: 5),
          if (widget.replacementInline)
            SizedBox(width: 88, child: duration)
          else if (box.maxWidth < 480)
            Expanded(child: duration)
          else
            SizedBox(width: 96, child: duration),
          const SizedBox(width: 6),
          if (widget.replacementInline) const Spacer(),
          RmButton(
            key: const ValueKey('material-insert-silence'),
            label: '插入静音',
            size: RmButtonSize.md,
            leading: const RmIcon('plus', size: 12),
            onPressed: _loading || _starting || widget.empty || _wave.isEmpty
                ? null
                : () => _operation('insert'),
          ),
        ],
      );
      final selection = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RmButton(
            key: const ValueKey('material-silence-selection'),
            label: '选区静音',
            size: RmButtonSize.md,
            leading: const RmIcon('volume-x', size: 12),
            onPressed: _loading || !_hasSelection
                ? null
                : () => _operation('silence'),
          ),
          const SizedBox(width: 6),
          RmButton(
            key: const ValueKey('material-delete-selection'),
            label: '删除选区',
            size: RmButtonSize.md,
            leading: const RmIcon('trash', size: 12),
            onPressed: _loading || !_hasSelection
                ? null
                : () => _operation('delete'),
          ),
        ],
      );
      if (widget.replacementInline) {
        return Column(
          key: const ValueKey('speech-inline-silence-grid'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: duration),
                const SizedBox(width: 6),
                Expanded(
                  child: RmButton(
                    key: const ValueKey('material-insert-silence'),
                    label: '插入静音',
                    size: RmButtonSize.md,
                    leading: const RmIcon('plus', size: 12),
                    onPressed:
                        _loading || _starting || widget.empty || _wave.isEmpty
                        ? null
                        : () => _operation('insert'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: RmButton(
                    key: const ValueKey('material-silence-selection'),
                    label: '选区静音',
                    leading: const RmIcon('volume-x', size: 12),
                    onPressed: _loading || !_hasSelection
                        ? null
                        : () => _operation('silence'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: RmButton(
                    key: const ValueKey('material-delete-selection'),
                    label: '删除选区',
                    leading: const RmIcon('trash', size: 12),
                    onPressed: _loading || !_hasSelection
                        ? null
                        : () => _operation('delete'),
                  ),
                ),
              ],
            ),
          ],
        );
      }
      return box.maxWidth >= 480
          ? Row(children: [insert, const Spacer(), selection])
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                insert,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: selection),
              ],
            );
    },
  );

  Widget _compactVolume() => Row(
    key: const ValueKey('material-volume'),
    children: [
      Text('音量', style: RmText.sans(11.5, color: context.rm.fg3)),
      const SizedBox(width: 5),
      Expanded(
        child: SizedBox(
          height: 28,
          child: RmSlider(
            value: _gain,
            min: -6,
            max: 6,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            onChangeStart: (_) => _checkpoint(),
            onChanged: widget.empty
                ? null
                : (v) {
                    _stop();
                    setState(() => _gain = v);
                    _publish();
                  },
          ),
        ),
      ),
      SizedBox(
        width: 48,
        child: Text(
          '${_gain >= 0 ? '+' : ''}${_gain.toStringAsFixed(1)} dB',
          textAlign: TextAlign.right,
          style: RmText.mono(10.5, color: context.rm.fg3),
        ),
      ),
      if (!widget.replacementInline) ...[
        const SizedBox(width: 5),
        RmButton(
          label: '默认',
          size: RmButtonSize.md,
          onPressed: () {
            _checkpoint();
            _stop();
            setState(() => _gain = 0);
            _publish();
          },
        ),
      ],
    ],
  );

  Widget _volume() => Column(
    key: const ValueKey('material-volume'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Text('音量', style: RmText.sans(12, color: context.rm.fg2)),
          const Spacer(),
          Text(
            '${_gain >= 0 ? '+' : ''}${_gain.toStringAsFixed(1)} dB',
            style: RmText.mono(11, color: context.rm.fg3),
          ),
          const SizedBox(width: 8),
          RmButton(
            label: '默认',
            onPressed: () {
              _checkpoint();
              _stop();
              setState(() => _gain = 0);
              _publish();
            },
          ),
        ],
      ),
      RmSlider(
        value: _gain,
        min: -6,
        max: 6,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        activeColor: context.rm.accent.base,
        onChangeStart: (_) => _checkpoint(),
        onChanged: (v) {
          _stop();
          setState(() => _gain = v);
          _publish();
        },
      ),
    ],
  );

  Widget _icon(String icon, String tooltip, VoidCallback? action) =>
      RmButton.icon(
        icon: RmIcon(icon, size: 13),
        tooltip: tooltip,
        onPressed: action,
      );

  Widget _metadata() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, box) {
          final name = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('素材名称', style: RmText.sans(11.5, color: context.rm.fg2)),
              const SizedBox(height: 6),
              SizedBox(
                height: 34,
                child: TextField(
                  enabled: widget.metadata,
                  controller: _name,
                  style: RmText.sans(12.5, color: context.rm.fg),
                  decoration: rmFieldDecoration(context),
                ),
              ),
            ],
          );
          final folder = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('所在文件夹', style: RmText.sans(11.5, color: context.rm.fg2)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: RmSelect<String>(
                      key: const ValueKey('voice-clip-folder'),
                      value: _folder,
                      items: {
                        for (final f in (_folders.toList()..sort()))
                          f: f.replaceAll('/', ' / '),
                      },
                      onChanged: !widget.metadata
                          ? null
                          : (v) {
                              _checkpoint();
                              setState(() => _folder = v);
                            },
                    ),
                  ),
                  const SizedBox(width: 6),
                  _icon(
                    'folder-plus',
                    '在所选文件夹中新建',
                    !widget.metadata
                        ? null
                        : () => setState(() => _addingFolder = !_addingFolder),
                  ),
                ],
              ),
            ],
          );
          return box.maxWidth >= 600
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: name),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: folder),
                  ],
                )
              : Column(children: [name, const SizedBox(height: 8), folder]);
        },
      ),
      if (_addingFolder)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _newFolderName,
                    autofocus: true,
                    style: RmText.sans(12, color: context.rm.fg),
                    decoration: rmFieldDecoration(
                      context,
                      hint: _folder == '未分类' ? '新建文件夹名称' : '在“$_folder”中新建子文件夹',
                    ),
                    onSubmitted: (_) => _addFolder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RmButton(
                label: '新建',
                size: RmButtonSize.sm,
                onPressed: _addFolder,
              ),
            ],
          ),
        ),
    ],
  );
}
