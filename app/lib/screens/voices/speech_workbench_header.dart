import 'package:flutter/material.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'speech_engine_dialog.dart';

/// Both engines keep their page title and mode action in the same place.
class SpeechWorkbenchHeader extends StatelessWidget {
  const SpeechWorkbenchHeader({
    super.key,
    required this.description,
    required this.conversion,
    this.error = false,
    this.onSwitch,
  });
  final String description;
  final bool conversion, error;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('语音生成', style: RmText.pageH1(color: context.rm.fg)),
            const SizedBox(height: 6),
            Text(
              description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(
                12,
                color: error ? context.rm.danger : context.rm.fg3,
              ),
            ),
          ],
        ),
      ),
      if (onSwitch != null) ...[
        const SizedBox(width: 12),
        RmButton(
          key: const ValueKey('speech-mode-switch'),
          leading: Text(
            'GPT-SoVITS',
            style: RmText.sans(
              12,
              weight: FontWeight.w600,
              color: conversion
                  ? context.rm.accent.onAccent.withAlpha(165)
                  : context.rm.accent.onAccent,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RmIcon('swap', size: 12, color: context.rm.accent.onAccent),
              const SizedBox(width: 8),
              Text(
                'RVC',
                style: RmText.sans(
                  12,
                  weight: FontWeight.w600,
                  color: conversion
                      ? context.rm.accent.onAccent
                      : context.rm.accent.onAccent.withAlpha(165),
                ),
              ),
            ],
          ),
          variant: RmButtonVariant.primary,
          horizontalPadding: 10,
          tooltip: conversion
              ? '当前 RVC，点击切换到 GPT-SoVITS'
              : '当前 GPT-SoVITS，点击切换到 RVC',
          onPressed: onSwitch,
        ),
      ],
    ],
  );
}

class SpeechConfigurationHeader extends StatelessWidget {
  const SpeechConfigurationHeader({
    super.key,
    required this.session,
    required this.onSettings,
    this.conversion = false,
  });
  final SpeechGenerationSession session;
  final VoidCallback onSettings;
  final bool conversion;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    child: LayoutBuilder(
      builder: (context, box) {
        final title = Text(
          conversion ? '音色配置' : '声音配置',
          style: RmText.sans(15, weight: FontWeight.w600, color: context.rm.fg),
        );
        final status = SpeechApiStatus(
          session: session,
          conversion: conversion,
          onPressed: onSettings,
        );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RmButton.icon(
              key: ValueKey(
                '${conversion ? 'rvc' : 'speech'}-open-engine-directory',
              ),
              icon: const RmIcon('folder-open', size: 12),
              tooltip: '打开 ${conversion ? 'RVC' : 'GPT-SoVITS'} 安装目录',
              onPressed: () => session.call('open-install-directory'),
            ),
            const SizedBox(width: 8),
            RmButton(
              key: ValueKey('${conversion ? 'rvc' : 'speech'}-engine-settings'),
              label: '推理引擎',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('settings', size: 12),
              onPressed: onSettings,
            ),
          ],
        );
        if (box.maxWidth >= 360) {
          return Row(
            children: [
              Expanded(child: title),
              status,
              const SizedBox(width: 8),
              actions,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: title),
                status,
              ],
            ),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    ),
  );
}
