import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/speech_generation.dart';
import '../state/editor_options.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'feature_tour.dart';
import 'rm_button.dart';
import 'rm_icon.dart';
import 'setting_toggle_row.dart';
import 'timing_dialog_frame.dart';

class SpeechExperimentSetting extends ConsumerWidget {
  const SpeechExperimentSetting({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(editorOptionsProvider).speechEnabled;
    final studio = ref.watch(studioProvider);
    return Column(
      children: [
        SettingToggleRow(
          title: '启用语音生成',
          description: '',
          padding: EdgeInsets.zero,
          value: enabled,
          onChanged: studio.projectEditingLocked
              ? null
              : (value) async {
                  final project = studio.projectDir;
                  final session = ref.read(
                    speechGenerationProvider(
                      jsonEncode([studio.repoRoot, project]),
                    ),
                  );
                  if (!value && session.busy) {
                    final accepted = await showDialog<bool>(
                      context: context,
                      useRootNavigator: false,
                      builder: (ctx) => TimingDialogFrame(
                        title: value ? '开启语音生成？' : '停止生成并关闭？',
                        icon: 'volume',
                        busy: false,
                        width: 560,
                        description: value
                            ? '实验功能 · GPT-SoVITS'
                            : '已完成的音频和声音预设会保留',
                        body: Text(
                          value
                              ? '安装独立本地引擎或连接已有的同机 API，再选择模型、参考音频并保存声音预设。\n\n语音生成页可试用和编辑声音；语音替换页可直接生成替换草稿，试听确认后仍需保存、构建并写入游戏。\n\n首次安装需要网络与较多空间；生成效果需要人工试听。'
                              : '关闭后会取消当前工程的生成任务，隐藏生成入口。已有外部 API 服务不会被关闭。',
                          style: RmText.body(color: ctx.rm.fg2),
                        ),
                        actions: [
                          RmButton(
                            label: '取消',
                            onPressed: () => Navigator.pop(ctx, false),
                          ),
                          RmButton(
                            label: value ? '开启功能' : '停止并关闭',
                            variant: RmButtonVariant.primary,
                            leading: const RmIcon('check', size: 12),
                            onPressed: () => Navigator.pop(ctx, true),
                          ),
                        ],
                      ),
                    );
                    if (accepted != true ||
                        !context.mounted ||
                        ref.read(studioProvider).projectDir != project) {
                      return;
                    }
                  }
                  if (!value) await session.call('stop-engine');
                  ref
                      .read(editorOptionsProvider.notifier)
                      .update(speechEnabled: value);
                  if (value) await session.start();
                },
        ),
      ],
    ).tourAnchor('speech-experiment');
  }
}
