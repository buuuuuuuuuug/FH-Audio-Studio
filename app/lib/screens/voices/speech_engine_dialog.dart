import '../../widgets/audio_editor_dialog.dart';
import '../../widgets/editor_columns.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_field.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_number_field.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_tooltip.dart';
import '../../widgets/timing_dialog_frame.dart';

class SpeechApiStatus extends StatelessWidget {
  const SpeechApiStatus({super.key, required this.session, this.onPressed});
  final SpeechGenerationSession session;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (_, _) {
      final starting = session.jobs.any(
        (j) =>
            ['start-engine', 'restart-engine'].contains(j['kind']) &&
            ['queued', 'running'].contains(j['status']),
      );
      final state = starting ? 'starting' : session.apiState;
      final label =
          const {
            'unconfigured': 'API 未配置',
            'stopped': 'API 已停止',
            'checking': 'API 检测中',
            'starting': 'API 启动中',
            'ready': 'API 可用',
            'generating': 'API 生成中',
            'error': 'API 异常',
          }[state] ??
          'API 未配置';
      return RmTooltip(
        message: session.apiDetail,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onPressed ?? () => showSpeechEngineDialog(context, session),
          child: RmChip(
            label: label,
            showDot: true,
            dense: true,
            variant: session.apiReady
                ? RmChipVariant.accent
                : state == 'error'
                ? RmChipVariant.danger
                : starting
                ? RmChipVariant.warn
                : RmChipVariant.muted,
          ),
        ),
      );
    },
  );
}

Future<void> showSpeechEngineDialog(
  BuildContext context,
  SpeechGenerationSession session, {
  Map<String, dynamic>? configuration,
}) {
  final key = GlobalKey<_SpeechEngineDialogState>();
  return showAudioEditorDialog<void>(
    context: context,
    beforeLeave: () => key.currentState?._requestClose() ?? Future.value(true),
    builder: (_) => _SpeechEngineDialog(
      key: key,
      session: session,
      configuration: configuration,
    ),
  );
}

class _SpeechEngineDialog extends StatefulWidget {
  const _SpeechEngineDialog({
    super.key,
    required this.session,
    this.configuration,
  });
  final SpeechGenerationSession session;
  final Map<String, dynamic>? configuration;
  @override
  State<_SpeechEngineDialog> createState() => _SpeechEngineDialogState();
}

class _SpeechEngineDialogState extends State<_SpeechEngineDialog> {
  final _url = TextEditingController(),
      _port = TextEditingController(),
      _timeout = TextEditingController();
  late String _mode;
  bool _autoStart = true, _saving = false;
  String _error = '', _feedback = '';
  bool _leaveRunning = false, _closing = false;
  String _downloadProfile = 'official';
  final _hf = TextEditingController(),
      _pypi = TextEditingController(),
      _torch = TextEditingController(),
      _github = TextEditingController();
  Map<String, dynamic>? get _installJob => widget.session.installationJob;
  bool get _installActive => widget.session.installing;

  Future<bool> _requestClose() async {
    if (_closing) return false;
    _closing = true;
    try {
      if (_installActive) {
        final choice = await showDialog<String>(
          context: context,
          useRootNavigator: false,
          builder: (dialog) => TimingDialogFrame(
            title: '安装还在进行',
            icon: 'import',
            description: '已下载的内容会保留',
            busy: false,
            width: 500,
            body: Text(
              '暂停后可返回继续，也可以让安装在后台进行。退出应用前仍会再次确认。',
              style: RmText.body(color: dialog.rm.fg2),
            ),
            actions: [
              RmButton(label: '继续查看', onPressed: () => Navigator.pop(dialog)),
              RmButton(
                label: '后台继续',
                onPressed: () => Navigator.pop(dialog, 'background'),
              ),
              RmButton(
                label: '暂停并关闭',
                variant: RmButtonVariant.primary,
                onPressed: () => Navigator.pop(dialog, 'pause'),
              ),
            ],
          ),
        );
        if (choice == null || !mounted) return false;
        _leaveRunning = choice == 'background';
        if (!_leaveRunning) await widget.session.call('pause-install');
      }
      if (mounted) {
        final navigator = Navigator.of(context), route = ModalRoute.of(context);
        if (route != null) navigator.popUntil((current) => current == route);
        navigator.pop();
      }
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return false;
    } finally {
      _closing = false;
    }
  }

  Future<void> _saveSources() => widget.session.call('configure-downloads', {
    'profile': _downloadProfile,
    'hf': _hf.text,
    'pypi': _pypi.text,
    'torch': _torch.text,
    'github': _github.text,
  });

  @override
  void initState() {
    super.initState();
    final c = speechMap(widget.session.engine['connection']);
    _mode = '${c['mode'] ?? 'managed'}';
    _url.text = '${c['url'] ?? 'http://127.0.0.1:9880'}';
    _port.text = '${c['port'] ?? 9880}';
    _timeout.text = '${c['timeout'] ?? 300}';
    _autoStart = c['auto_start'] != false;
    final downloads = speechMap(widget.session.engine['downloads']);
    _downloadProfile = '${downloads['profile'] ?? 'official'}';
    _hf.text = '${downloads['hf'] ?? 'https://hf-mirror.com'}';
    _pypi.text =
        '${downloads['pypi'] ?? 'https://pypi.tuna.tsinghua.edu.cn/simple'}';
    _torch.text =
        '${downloads['torch'] ?? 'https://mirror.sjtu.edu.cn/pytorch-wheels/cu126'}';
    _github.text = '${downloads['github'] ?? ''}';
  }

  @override
  void dispose() {
    if (_installActive && !_leaveRunning) {
      unawaited(
        widget.session
            .call('pause-install')
            .catchError((Object _) => <String, dynamic>{}),
      );
    }
    _hf.dispose();
    _pypi.dispose();
    _torch.dispose();
    _github.dispose();
    _url.dispose();
    _port.dispose();
    _timeout.dispose();
    super.dispose();
  }

  Future<void> _action(String action, {bool save = true}) async {
    if (_saving) return;
    if (action == 'uninstall-engine') {
      final accepted = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => TimingDialogFrame(
          title: '删除推理引擎？',
          icon: 'trash',
          busy: false,
          width: 520,
          body: Text(
            '删除本地引擎源码、依赖环境和基础模型，之后需要重新安装。声音预设、导入的模型与参考音频、工程中的歌曲和语音会保留。外部 API 不受影响。',
            style: RmText.body(color: ctx.rm.fg2),
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            RmButton(
              label: '删除推理引擎',
              leading: const RmIcon('trash', size: 12),
              foregroundColor: ctx.rm.danger,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() {
      _saving = true;
      _error = '';
      _feedback = '';
    });
    try {
      if (action == 'install' || action == 'save') await _saveSources();
      if (save) {
        await widget.session.call('configure-engine', {
          'mode': _mode,
          'url': _url.text,
          'port': int.tryParse(_port.text),
          'timeout': double.tryParse(_timeout.text),
          'auto_start': _autoStart,
        });
      }
      if (action != 'save') {
        await widget.session.call(action, {
          if (widget.configuration != null) 'config': widget.configuration,
        });
        _feedback = action == 'check-installation'
            ? (widget.session.engine['installed'] == true
                  ? '引擎组件已就绪；请继续配置声音模型和参考音频。'
                  : '组件尚未齐全，请继续安装。')
            : action == 'check-engine'
            ? widget.session.apiDetail
            : action == 'validate-config'
            ? '模型与参考音频检查完成'
            : action == 'clear-candidates'
            ? '已清理未采用的临时音频'
            : '';
      }
      if (action == 'save') _feedback = '设置已保存';
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showManualPreparation() => showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (dialog) => TimingDialogFrame(
      title: '手动准备推理引擎',
      icon: 'folder',
      width: 620,
      busy: false,
      description: '官方固定版本源码 · 已下载文件可继续复用',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '下载以下源码 ZIP，将其保存为安装目录中的 official.zip。返回后点击安装或修复，继续补齐 Python 依赖和基础模型。',
            style: RmText.body(color: dialog.rm.fg2),
          ),
          const SizedBox(height: 14),
          DialogSettingsSection(
            title: '下载地址',
            child: SelectableText(
              'https://github.com/RVC-Boss/GPT-SoVITS/archive/04a44eb977586645f33594b72af13a035a2056c6.zip',
              style: RmText.mono(11, color: dialog.rm.fg2),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '安装目录',
            style: RmText.sans(
              12,
              weight: FontWeight.w600,
              color: dialog.rm.fg,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            '${widget.session.engine['home'] ?? ''}',
            style: RmText.mono(11, color: dialog.rm.fg3),
          ),
          const SizedBox(height: 12),
          Text(
            '已有可运行的整合包：启动官方 api_v2，再选择“连接已有同机 API”。',
            style: RmText.sans(11.5, color: dialog.rm.fg3),
          ),
        ],
      ),
      actions: [
        RmButton(
          label: '打开安装目录',
          leading: const RmIcon('folder-open', size: 12),
          onPressed: () => _action('open-install-directory', save: false),
        ),
        RmButton(
          label: '复制地址',
          leading: const RmIcon('copy', size: 12),
          onPressed: () => Clipboard.setData(
            const ClipboardData(
              text:
                  'https://github.com/RVC-Boss/GPT-SoVITS/archive/04a44eb977586645f33594b72af13a035a2056c6.zip',
            ),
          ),
        ),
        RmButton(
          label: '完成',
          variant: RmButtonVariant.primary,
          onPressed: () => Navigator.pop(dialog),
        ),
      ],
    ),
  );

  Widget _connectionFields() => LayoutBuilder(
    builder: (_, box) {
      final mode = _caption(
        '连接方式',
        RmSelect<String>(
          value: _mode,
          items: const {'managed': '应用管理本地服务', 'existing': '连接已有同机 API'},
          onChanged: widget.session.busy
              ? null
              : (v) => setState(() => _mode = v),
        ),
      );
      final address = _caption(
        _mode == 'managed' ? '本地地址' : 'API 地址',
        _mode == 'managed'
            ? Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: context.rm.raised,
                  border: Border.all(color: context.rm.border),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '127.0.0.1',
                  style: RmText.mono(12, color: context.rm.fg2),
                ),
              )
            : SizedBox(
                height: 32,
                child: TextField(
                  controller: _url,
                  style: RmText.mono(12, color: context.rm.fg),
                  decoration: rmFieldDecoration(context),
                ),
              ),
      );
      final port = _caption(
        '端口',
        SizedBox(
          height: 32,
          child: RmNumberField(
            controller: _port,
            min: 1024,
            max: 65535,
            step: 1,
            decimals: 0,
          ),
        ),
      );
      final timeout = _caption(
        '请求超时',
        SizedBox(
          height: 32,
          child: RmNumberField(
            controller: _timeout,
            min: 10,
            max: 1800,
            step: 10,
            decimals: 0,
            unit: '秒',
          ),
        ),
      );
      final test = _button(
        '测试连接',
        'refresh',
        'check-engine',
        primary: true,
        enabled: !widget.session.busy,
      );
      if (box.maxWidth >= 600) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(width: 180, child: mode),
            const SizedBox(width: 8),
            Expanded(child: address),
            const SizedBox(width: 8),
            if (_mode == 'managed') ...[
              SizedBox(width: 84, child: port),
              const SizedBox(width: 8),
            ],
            SizedBox(width: 100, child: timeout),
            const SizedBox(width: 8),
            test,
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: mode),
              const SizedBox(width: 8),
              Expanded(child: address),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_mode == 'managed') ...[
                Expanded(child: port),
                const SizedBox(width: 8),
              ],
              Expanded(child: timeout),
              const SizedBox(width: 8),
              test,
            ],
          ),
        ],
      );
    },
  );
  Widget _group(List<Widget> buttons) => LayoutBuilder(
    builder: (_, box) {
      final width = (box.maxWidth - 16) / 3;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final button in buttons)
            SizedBox(width: width < 100 ? box.maxWidth : width, child: button),
        ],
      );
    },
  );
  Widget _caption(String text, Widget field) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(text, style: RmText.sans(11.5, color: context.rm.fg3)),
      const SizedBox(height: 5),
      field,
    ],
  );
  RmButton _button(
    String text,
    String icon,
    String action, {
    bool primary = false,
    bool save = true,
    bool? enabled,
  }) => RmButton(
    label: text,
    size: RmButtonSize.md,
    leading: RmIcon(icon, size: 12),
    variant: primary ? RmButtonVariant.primary : RmButtonVariant.defaultBtn,
    onPressed: _saving || enabled == false
        ? null
        : () => _action(action, save: save),
  );
  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: RmText.sans(13, weight: FontWeight.w600, color: context.rm.fg),
    ),
  );

  Widget _installationProgress(Map<String, dynamic>? job) {
    if (job == null || job['status'] == 'ready') {
      return const SizedBox.shrink();
    }
    final running = ['running', 'queued'].contains(job['status']);
    final label =
        const {
          'paused': '安装已暂停',
          'failed': '安装未完成',
          'ready': '安装完成',
          'queued': '等待安装',
          'running': '正在安装',
          'cancelled': '安装已停止',
        }[job['status']] ??
        '';
    final download = speechMap(job['download']),
        overall = speechMap(job['installation']);
    final fraction = (download['fraction'] as num?)?.toDouble();
    final totalFraction = (overall['fraction'] as num?)?.toDouble();
    final rate = (download['bytes_per_second'] as num?)?.toDouble();
    final rateText = rate == null
        ? '计算速度中…'
        : rate >= 1048576
        ? '${(rate / 1048576).toStringAsFixed(1)} MiB/s'
        : '${(rate / 1024).toStringAsFixed(0)} KiB/s';
    return Container(
      key: const ValueKey('speech-install-progress'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.rm.raised,
        border: Border.all(color: context.rm.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: RmText.sans(
                    12,
                    weight: FontWeight.w600,
                    color: context.rm.fg,
                  ),
                ),
              ),
              if (running)
                RmButton(
                  label: '暂停安装',
                  leading: const RmIcon('pause', size: 12),
                  onPressed: () => _action('pause-install', save: false),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  overall.isEmpty
                      ? '总进度 · 正在确认安装步骤'
                      : '总进度 · ${overall['completed']}/${overall['total']} 个步骤',
                  style: RmText.sans(11, color: context.rm.fg3),
                ),
              ),
              if (totalFraction != null)
                Text(
                  '${(totalFraction * 100).round()}%',
                  style: RmText.mono(11, color: context.rm.fg2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            key: const ValueKey('speech-install-total-progress'),
            value:
                totalFraction?.clamp(0, 1) ??
                (job['status'] == 'ready' ? 1 : 0),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${job['error'] ?? job['progress'] ?? '准备中…'}',
                  style: RmText.sans(
                    11.5,
                    color: job['status'] == 'failed'
                        ? context.rm.danger
                        : context.rm.fg2,
                  ),
                ),
              ),
              if (running && download.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  rateText,
                  key: const ValueKey('speech-download-speed'),
                  style: RmText.mono(11, color: context.rm.fg3),
                ),
              ],
            ],
          ),
          if (download.isNotEmpty) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: fraction?.clamp(0, 1)),
          ],
          if (job['status'] == 'paused') ...[
            const SizedBox(height: 6),
            Text(
              '已完成文件与依赖会复用；点击继续安装即可恢复。',
              style: RmText.sans(11, color: context.rm.fg3),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (_, _) {
      final s = widget.session,
          installed = widget.session.engine['installed'] == true;
      final owned = speechMap(s.engine['api'])['owned'] == true;
      final config =
          widget.configuration ?? s.presets.firstOrNull ?? <String, dynamic>{};
      final hasModels = [
        'gpt_model',
        'sovits_model',
      ].every((key) => '${config[key] ?? ''}'.isNotEmpty);
      final hasVoice =
          hasModels && '${config['ref_audio_path'] ?? ''}'.isNotEmpty;
      final job = _installJob;
      final settings = Column(
        key: const ValueKey('speech-install-settings'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('连接设置'),
          _connectionFields(),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    key: const ValueKey('speech-auto-start'),
                    value: _autoStart,
                    activeColor: context.rm.accent.base,
                    checkColor: context.rm.accent.onAccent,
                    onChanged: s.busy || _mode != 'managed'
                        ? null
                        : (value) => setState(() => _autoStart = value!),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '使用时自动启动本地 API',
                  style: RmText.sans(
                    12,
                    color: _mode == 'managed' ? context.rm.fg2 : context.rm.fg4,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 20, color: context.rm.border),
          _sectionTitle('下载与安装'),
          if (!installed) ...[
            Text(
              '首次完整下载预计约 4–6 GB，建议预留至少 20 GB 磁盘空间（含环境、基础模型与安装缓存）。不含自行导入的声音模型；已有缓存可减少下载量。',
              key: const ValueKey('speech-install-size-notice'),
              style: RmText.sans(11, color: context.rm.fg3),
            ),
            const SizedBox(height: 8),
          ],
          LayoutBuilder(
            builder: (context, box) {
              final source = RmSelect<String>(
                value: _downloadProfile,
                items: const {
                  'domestic': '国内镜像（推荐）',
                  'official': '官方源',
                  'custom': '自定义下载源',
                },
                onChanged: _installActive
                    ? null
                    : (v) => setState(() {
                        _downloadProfile = v;
                        if (v == 'domestic') {
                          _hf.text = 'https://hf-mirror.com';
                          _pypi.text =
                              'https://pypi.tuna.tsinghua.edu.cn/simple';
                          _torch.text =
                              'https://mirror.sjtu.edu.cn/pytorch-wheels/cu126';
                        }
                      }),
              );
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RmButton(
                    key: const ValueKey('speech-manual-install'),
                    label: '手动准备',
                    leading: const RmIcon('folder', size: 12),
                    onPressed: _showManualPreparation,
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    label: '打开安装目录',
                    leading: const RmIcon('folder-open', size: 12),
                    onPressed: () =>
                        _action('open-install-directory', save: false),
                  ),
                ],
              );
              if (box.maxWidth < 480) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    source,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: source),
                  const SizedBox(width: 8),
                  actions,
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            '暂停安装后可切换下载源；已完成文件继续复用。',
            style: RmText.sans(10.5, color: context.rm.fg3),
          ),
          if (_downloadProfile == 'domestic') ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _caption(
                    '模型源',
                    RmSelect<String>(
                      value: _hf.text,
                      items: const {
                        'https://hf-mirror.com': 'HF-Mirror',
                        'https://huggingface.co': 'Hugging Face 官方',
                      },
                      onChanged: _installActive
                          ? null
                          : (v) => setState(() => _hf.text = v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _caption(
                    'Python 源',
                    RmSelect<String>(
                      value: _pypi.text,
                      items: const {
                        'https://pypi.tuna.tsinghua.edu.cn/simple': '清华大学',
                        'https://mirrors.aliyun.com/pypi/simple': '阿里云',
                        'https://repo.huaweicloud.com/repository/pypi/simple':
                            '华为云',
                        'https://mirrors.ustc.edu.cn/pypi/simple': '中国科学技术大学',
                        'https://mirrors.bfsu.edu.cn/pypi/web/simple':
                            '北京外国语大学',
                        'https://pypi.org/simple': 'PyPI 官方',
                      },
                      onChanged: _installActive
                          ? null
                          : (v) => setState(() => _pypi.text = v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _caption(
                    'PyTorch 源',
                    RmSelect<String>(
                      value: _torch.text,
                      items: const {
                        'https://mirror.sjtu.edu.cn/pytorch-wheels/cu126':
                            '上海交通大学',
                        'https://mirrors.nju.edu.cn/pytorch/whl/cu126': '南京大学',
                        'https://download.pytorch.org/whl/cu126': 'PyTorch 官方',
                      },
                      onChanged: _installActive
                          ? null
                          : (v) => setState(() => _torch.text = v),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_downloadProfile == 'custom') ...[
            const SizedBox(height: 8),
            for (final entry in [
              ('模型地址', _hf),
              ('Python 索引', _pypi),
              ('PyTorch cu126 索引', _torch),
              ('GitHub 加速前缀（可选）', _github),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _caption(
                  entry.$1,
                  TextField(
                    controller: entry.$2,
                    decoration: rmFieldDecoration(context),
                    style: RmText.mono(11),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final part in speechMaps(s.engine['components']))
                RmTooltip(
                  message: speechMaps(s.engine['components']).isEmpty
                      ? ''
                      : (part['missing'] as List? ?? []).join('\n'),
                  child: RmChip(
                    label:
                        '${part['ready'] == true ? '✓' : '○'} ${part['name']}',
                    variant: part['ready'] == true
                        ? RmChipVariant.accent
                        : RmChipVariant.muted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _group([
            if (_mode == 'managed')
              _button(
                installed ? '安装或修复' : (job != null ? '继续安装' : '安装组件'),
                'import',
                'install',
                primary: true,
                save: false,
                enabled: !s.busy,
              ),
            _button(
              '检查组件',
              'check',
              'check-installation',
              save: false,
              enabled: !s.busy,
            ),
            _button(
              '删除推理引擎',
              'trash',
              'uninstall-engine',
              save: false,
              enabled: !s.busy && _mode == 'managed',
            ),
          ]),
          if (job != null && !(installed && job['status'] == 'failed'))
            _installationProgress(job),
          if (installed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                hasVoice
                    ? '组件已就绪；启动服务只需 GPT / SoVITS 模型，参考音频用于生成。'
                    : '引擎组件已就绪。先导入 GPT / SoVITS 模型以启动服务；参考音频在生成时配置。',
                style: RmText.sans(11.5, color: context.rm.accent.base),
              ),
            ),
          Divider(height: 20, color: context.rm.border),
          _sectionTitle('服务控制'),
          if (_mode == 'managed')
            _group([
              _button(
                '启动服务',
                'play',
                'start-engine',
                primary: true,
                enabled: installed && hasModels && !s.busy && !owned,
              ),
              _button(
                '停止服务',
                'stop',
                'stop-engine',
                save: false,
                enabled: owned,
              ),
              _button(
                '重启服务',
                'refresh',
                'restart-engine',
                enabled: installed && hasModels && !s.busy && owned,
              ),
            ]),
          if (hasVoice)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _button(
                '检查声音配置',
                'check',
                'validate-config',
                enabled: installed && !s.busy,
              ),
            ),
          if (_error.isNotEmpty || _feedback.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error.isNotEmpty ? _error : _feedback,
                style: RmText.sans(
                  11.5,
                  color: _error.isNotEmpty ? context.rm.danger : context.rm.fg3,
                ),
              ),
            ),
        ],
      );
      return TimingDialogFrame(
        title: '安装与设置推理引擎',
        icon: 'settings',
        description: '独立 GPT-SoVITS · 同机 API',
        width: 1120,
        busy: false,
        onClose: () => unawaited(_requestClose()),
        headerActions: [
          SpeechApiStatus(
            session: s,
            onPressed: () => _action('check-engine', save: false),
          ),
        ],
        body: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 850
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    settings,
                    const SizedBox(height: 16),
                    SpeechEngineConsole(session: s, initiallyExpanded: true),
                  ],
                )
              : EditorColumns(
                  main: settings,
                  side: SpeechEngineConsole(
                    session: s,
                    initiallyExpanded: true,
                    fill: true,
                  ),
                  sideWidth: box.maxWidth * .4,
                  gap: 20,
                ),
        ),
        actions: [
          _button('保存设置', 'save', 'save', primary: true, enabled: !s.busy),
          RmButton(
            label: installed && !hasVoice ? '配置声音' : '完成',
            variant: RmButtonVariant.primary,
            leading: const RmIcon('check', size: 12),
            onPressed: () => unawaited(_requestClose()),
          ),
        ],
      );
    },
  );
}

/// Console polling belongs to the visible, expanded panel, not the service.
class SpeechEngineConsole extends StatefulWidget {
  const SpeechEngineConsole({
    super.key,
    required this.session,
    this.initiallyExpanded = false,
    this.fill = false,
  });
  final bool initiallyExpanded, fill;
  final SpeechGenerationSession session;
  @override
  State<SpeechEngineConsole> createState() => _SpeechEngineConsoleState();
}

class _SpeechEngineConsoleState extends State<SpeechEngineConsole> {
  bool _expanded = false, _reading = false;
  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) _toggle();
  }

  String _text = '';
  Timer? _timer;
  int _epoch = 0;
  Future<void> _read() async {
    if (!_expanded || _reading) return;
    final epoch = _epoch;
    _reading = true;
    try {
      await widget.session.start();
      final value = await widget.session.call('engine-logs');
      if (mounted && _expanded && epoch == _epoch) {
        setState(() => _text = '${value['text'] ?? ''}');
      }
    } catch (_) {
    } finally {
      _reading = false;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _epoch++;
    _timer?.cancel();
    if (_expanded) {
      unawaited(_read());
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_read()),
      );
    }
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final output = Container(
      key: const ValueKey('speech-console-log'),
      height: widget.fill ? null : 260,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.rm.raised,
        border: Border.all(color: context.rm.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: SelectableText(
          _text.isEmpty ? '尚无控制台输出。' : _text,
          style: RmText.mono(10.5, color: context.rm.fg2),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: RmButton(
                  key: const ValueKey('speech-console-toggle'),
                  label: _expanded ? '收起控制台' : '控制台输出',
                  leading: const RmIcon('list', size: 12),
                  onPressed: _toggle,
                ),
              ),
            ),
            RmButton(
              label: '清空输出',
              onPressed: () async {
                _epoch++;
                await widget.session.call('clear-engine-logs');
                if (mounted) setState(() => _text = '');
              },
            ),
          ],
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          if (widget.fill) Expanded(child: output) else output,
        ],
      ],
    );
  }
}

class SpeechInstallIndicator extends StatelessWidget {
  const SpeechInstallIndicator({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<SpeechGenerationSession?>(
    valueListenable: SpeechGenerationSession.activeInstallation,
    builder: (_, session, _) => session == null
        ? const SizedBox.shrink()
        : ListenableBuilder(
            listenable: session,
            builder: (_, _) {
              final job = session.installationJob;
              if (!session.installing) return const SizedBox.shrink();
              final fraction =
                  ((speechMap(job?['installation'])['fraction'] ??
                              speechMap(job?['download'])['fraction'])
                          as num?)
                      ?.toDouble();
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: RmButton(
                  key: const ValueKey('speech-background-install'),
                  size: RmButtonSize.sm,
                  label: compact
                      ? null
                      : '引擎安装${fraction == null ? '中' : ' ${(fraction * 100).round()}%'}',
                  leading: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      value: fraction?.clamp(0, 1),
                      color: context.rm.accent.base,
                    ),
                  ),
                  tooltip: '${job?['progress'] ?? '正在安装语音引擎'} · 点击查看',
                  onPressed: () => showSpeechEngineDialog(context, session),
                ),
              );
            },
          ),
  );
}

/// Both native close and Flutter exit requests use this same decision.
Future<bool> confirmSpeechInstallationExit(
  BuildContext context, {
  SpeechGenerationSession? session,
}) async {
  final active = session ?? SpeechGenerationSession.activeInstallation.value;
  if (active == null || !active.installing) return true;
  var pausing = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => StatefulBuilder(
          builder: (_, update) => TimingDialogFrame(
            title: '暂停安装并退出？',
            icon: 'import',
            width: 500,
            busy: pausing,
            description: '已下载的文件会保留，下次可继续安装',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '推理引擎仍在安装。退出前将保存安装进度并暂停下载。',
                  style: RmText.body(color: dialog.rm.fg2),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: RmText.sans(12, color: dialog.rm.danger)),
                ],
              ],
            ),
            actions: [
              RmButton(
                label: '继续安装',
                onPressed: pausing ? null : () => Navigator.pop(dialog, false),
              ),
              RmButton(
                key: const ValueKey('speech-pause-and-exit'),
                label: pausing ? '正在暂停…' : '暂停并退出',
                variant: RmButtonVariant.primary,
                leading: const RmIcon('pause', size: 12),
                onPressed: pausing
                    ? null
                    : () async {
                        update(() => pausing = true);
                        try {
                          if (active.installing) {
                            await active.call('pause-install');
                          }
                          if (dialog.mounted) Navigator.pop(dialog, true);
                        } catch (e) {
                          if (dialog.mounted) {
                            update(() {
                              pausing = false;
                              error = '暂停未完成，请重试：$e';
                            });
                          }
                        }
                      },
              ),
            ],
          ),
        ),
      ) ??
      false;
}
