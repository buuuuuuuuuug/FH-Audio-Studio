import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_tooltip.dart';

/// Stable generation feedback shared by the studio and replacement workbench.
class SpeechGenerationStatus extends StatelessWidget {
  const SpeechGenerationStatus({
    super.key,
    required this.text,
    this.running = false,
    this.failed = false,
    this.onCancel,
    this.onPause,
    this.onResume,
    this.onRetry,
  });
  final String text;
  final bool running, failed;
  final VoidCallback? onCancel, onPause, onResume, onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            container: true,
            liveRegion: true,
            child: RmTooltip(
              message: text,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: context.rm.hover,
                  border: Border.all(
                    color: failed ? context.rm.danger : context.rm.border,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 12,
                      child: running
                          ? const CircularProgressIndicator(strokeWidth: 1.5)
                          : Center(
                              child: Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: failed
                                      ? context.rm.danger
                                      : context.rm.fg4,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RmText.sans(
                          11,
                          color: failed ? context.rm.danger : context.rm.fg3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        for (final action in [
          if (onResume != null) ('play', '继续生成', onResume!),
          if (onPause != null) ('pause', '暂停生成', onPause!),
          if (onRetry != null) ('refresh', '重试生成', onRetry!),
          if (onCancel != null) ('stop', '取消生成', onCancel!),
        ]) ...[
          const SizedBox(width: 6),
          SizedBox.square(
            dimension: 32,
            child: RmButton.icon(
              icon: RmIcon(action.$1, size: 12),
              tooltip: action.$2,
              onPressed: action.$3,
            ),
          ),
        ],
      ],
    ),
  );
}
