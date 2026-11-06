import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/fh_radio_studio_cli.dart';
import '../core/speech_configuration.dart';
import '../core/speech_generation.dart';
import '../state/app_state.dart';
import '../state/editor_options.dart';
import '../state/router.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_tooltip.dart';
import '../widgets/feature_tour.dart';
import 'voice_replacement.dart';
import 'voices/speech_configuration_panel.dart';
import 'voices/speech_results.dart';

class SpeechStudioScreen extends ConsumerWidget {
  const SpeechStudioScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studio = ref.watch(studioProvider);
    if (!ref.watch(editorOptionsProvider).speechEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go(RmRoutes.dashboard);
      });
      return const SizedBox.shrink();
    }
    if (studio.projectDir.isEmpty) {
      return Center(
        child: Text('请先打开工程。', style: RmText.sans(13, color: context.rm.fg2)),
      );
    }
    final key = jsonEncode([studio.repoRoot, studio.projectDir]);
    final session = ref.watch(speechGenerationProvider(key));
    final workspace = ref.read(
      voiceWorkspaceSessionProvider(
        jsonEncode([
          studio.projectDir,
          studio.gameDir,
          localDevelopmentConfig()['audio_scan_root'] as String? ??
              studio.gameDir,
        ]),
      ),
    );
    final project = studio.projectDir;
    session.receive = (data) => workspace.acceptGeneration(project, data);
    return SpeechStudioWorkbench(
      key: ValueKey(key),
      session: session,
      preferences: ref.read(sharedPreferencesProvider),
      featureTour: true,
    );
  }
}

class SpeechStudioWorkbench extends StatefulWidget {
  const SpeechStudioWorkbench({
    super.key,
    required this.session,
    this.preferences,
    this.featureTour = false,
  });
  final SpeechGenerationSession session;
  final SharedPreferences? preferences;
  final bool featureTour;
  @override
  State<SpeechStudioWorkbench> createState() => _SpeechStudioWorkbenchState();
}

class _SpeechStudioWorkbenchState extends State<SpeechStudioWorkbench> {
  late final SpeechConfiguration _configuration;
  double _ratio = .32, _dragRatio = .32, _dragX = 0;
  bool _configuredOnce = false;
  @override
  void initState() {
    super.initState();
    _ratio = widget.preferences?.getDouble('speech.configurationRatio') ?? .32;
    _configuration = SpeechConfiguration(widget.session);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await widget.session.start();
    if (!mounted) return;
    try {
      await widget.session.checkApi(autoStart: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _configuration.dispose();
    super.dispose();
  }

  Widget _card(Widget child) => Container(
    decoration: BoxDecoration(
      color: context.rm.panel,
      border: Border.all(color: context.rm.border),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
  void _remember() =>
      widget.preferences?.setDouble('speech.configurationRatio', _ratio);
  Widget _configurationCard() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: LayoutBuilder(
            builder: (context, box) {
              final title = Text(
                '声音配置',
                style: RmText.sans(
                  15,
                  color: context.rm.fg,
                  weight: FontWeight.w600,
                ),
              );
              final api = SpeechApiStatus(session: widget.session);
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RmButton.icon(
                    key: const ValueKey('speech-open-engine-directory'),
                    icon: const RmIcon('folder-open', size: 12),
                    tooltip: '打开 GPT-SoVITS 安装目录',
                    onPressed: () =>
                        widget.session.call('open-install-directory'),
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    key: const ValueKey('speech-engine-settings'),
                    label: '推理引擎',
                    variant: RmButtonVariant.primary,
                    leading: const RmIcon('settings', size: 12),
                    onPressed: () => showSpeechEngineDialog(
                      context,
                      widget.session,
                      configuration: _configuration.snapshot(),
                    ),
                  ),
                ],
              );
              return box.maxWidth >= 360
                  ? Row(
                      children: [
                        Expanded(child: title),
                        api,
                        const SizedBox(width: 8),
                        actions,
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(child: title),
                            api,
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    );
            },
          ),
        ).tourAnchor('speech-api'),
        Divider(height: 1, color: context.rm.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SpeechConfigurationPanel(configuration: _configuration),
                Divider(height: 22, color: context.rm.border),
                SpeechEngineConsole(session: widget.session),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Widget _setupGuidanceCard() => _card(
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '先配置推理引擎',
                      style: RmText.sans(
                        16,
                        weight: FontWeight.w600,
                        color: context.rm.fg,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '安装本地服务，或连接已有的同机 GPT-SoVITS API。',
                      style: RmText.sans(12, color: context.rm.fg3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              SpeechApiStatus(session: widget.session),
            ],
          ),
        ),
        Divider(height: 1, color: context.rm.border),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (final step in const [
                ('1', '安装或连接引擎', '选择下载源安装组件，或填写已有 API 地址。'),
                ('2', '配置声音预设', '选择 GPT、SoVITS 模型及参考音频。'),
                ('3', '生成与试听', '输入文本，生成后试听、编辑并加入素材池。'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          step.$1,
                          style: RmText.mono(12, color: context.rm.accent.base),
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, box) {
                            final title = Text(
                              step.$2,
                              style: RmText.sans(
                                12.5,
                                weight: FontWeight.w600,
                                color: context.rm.fg,
                              ),
                            );
                            final detail = Text(
                              step.$3,
                              style: RmText.sans(12, color: context.rm.fg3),
                            );
                            return box.maxWidth < 480
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      title,
                                      const SizedBox(height: 4),
                                      detail,
                                    ],
                                  )
                                : Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(width: 112, child: title),
                                      Expanded(child: detail),
                                    ],
                                  );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.rm.border)),
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: RmButton(
              label: '安装与设置推理引擎',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('settings', size: 12),
              onPressed: () => showSpeechEngineDialog(context, widget.session),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, _configuration]),
    builder: (_, _) {
      if (_configuration.ready &&
          (widget.session.apiReady || widget.session.presets.isNotEmpty)) {
        _configuredOnce = true;
      }
      final workbench = Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('语音生成', style: RmText.pageH1(color: context.rm.fg)),
                      const SizedBox(height: 6),
                      Text(
                        widget.session.apiState == 'error'
                            ? widget.session.apiDetail
                            : !_configuredOnce
                            ? 'GPT-SoVITS 根据参考音频生成文本语音；配置引擎和声音后即可使用。'
                            : 'GPT-SoVITS 根据参考音频生成文本语音，支持试听、编辑与游戏语音替换。',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RmText.sans(
                          12,
                          color: widget.session.apiState == 'error'
                              ? context.rm.danger
                              : context.rm.fg3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child:
                  !_configuredOnce &&
                      widget.session.engine['installed'] != true &&
                      speechMap(widget.session.engine['connection'])['mode'] !=
                          'existing'
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 660),
                        child: _setupGuidanceCard(),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (_, box) {
                        final width = math.max(620.0, box.maxWidth),
                            available = width - 10;
                        final left = (available * _ratio)
                            .clamp(280.0, math.max(280.0, available - 320))
                            .toDouble();
                        final content = SizedBox(
                          width: width,
                          height: box.maxHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: left,
                                child: _configurationCard(),
                              ),
                              RmTooltip(
                                message: '拖动调整宽度；双击恢复默认',
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.resizeColumn,
                                  child: GestureDetector(
                                    dragStartBehavior: DragStartBehavior.down,
                                    key: const ValueKey(
                                      'speech-column-divider',
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragStart: (d) {
                                      _dragX = d.globalPosition.dx;
                                      _dragRatio = left / available;
                                    },
                                    onHorizontalDragUpdate: (d) => setState(
                                      () => _ratio =
                                          (_dragRatio +
                                                  (d.globalPosition.dx -
                                                          _dragX) /
                                                      available)
                                              .clamp(
                                                280 / available,
                                                (available - 320) / available,
                                              ),
                                    ),
                                    onHorizontalDragEnd: (_) => _remember(),
                                    onDoubleTap: () {
                                      setState(() => _ratio = .32);
                                      _remember();
                                    },
                                    child: SizedBox(
                                      width: 10,
                                      child: Center(
                                        child: Container(
                                          width: 1,
                                          color: context.rm.border,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: _card(
                                  SpeechResults(configuration: _configuration),
                                ).tourAnchor('speech-generate'),
                              ),
                            ],
                          ),
                        );
                        return width > box.maxWidth
                            ? SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: content,
                              )
                            : content;
                      },
                    ),
            ),
          ],
        ),
      );
      return widget.featureTour
          ? workbench.withFeatureTour(
              TourPage.speech,
              enabled:
                  _configuration.ready &&
                  (_configuration.parameters['no_prompt'] == true ||
                      '${_configuration.data['prompt_text'] ?? ''}'
                          .trim()
                          .isNotEmpty) &&
                  widget.session.apiReady &&
                  !widget.session.busy,
            )
          : workbench;
    },
  );
}
