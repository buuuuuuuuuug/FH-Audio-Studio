import 'package:flutter/material.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'speech_engine_dialog.dart';

/// Shared first-launch hierarchy: compact instructions and a separate action
/// footer, using the workbench's existing panel, text and accent tokens.
class SpeechSetupGuidance extends StatelessWidget {
  const SpeechSetupGuidance({
    super.key,
    required this.session,
    required this.onSettings,
    this.conversion = false,
  });

  final SpeechGenerationSession session;
  final VoidCallback onSettings;
  final bool conversion;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey(conversion ? 'rvc-setup-guidance' : 'speech-setup-guidance'),
    decoration: BoxDecoration(
      color: context.rm.panel,
      border: Border.all(color: context.rm.border),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
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
                      conversion ? '先安装 RVC 推理引擎' : '先配置推理引擎',
                      style: RmText.sans(
                        16,
                        weight: FontWeight.w600,
                        color: context.rm.fg,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      conversion
                          ? '将已有录音转换为目标音色，保留原句内容与节奏。'
                          : '安装本地服务，或连接已有的同机 GPT-SoVITS API。',
                      style: RmText.sans(12, color: context.rm.fg3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              SpeechApiStatus(
                session: session,
                conversion: conversion,
                onPressed: onSettings,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.rm.border),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (final step
                  in conversion
                      ? const [
                          ('1', '安装推理引擎', '选择设备和下载源，安装独立推理组件。'),
                          ('2', '导入音色模型', '导入 RVC 模型，可选配套索引并调整参数。'),
                          ('3', '转换与试听', '导入录音或选择游戏原音，转换后试听、编辑与替换。'),
                        ]
                      : const [
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
              label: conversion ? '安装与设置 RVC 引擎' : '安装与设置推理引擎',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('settings', size: 12),
              onPressed: onSettings,
            ),
          ),
        ),
      ],
    ),
  );
}
