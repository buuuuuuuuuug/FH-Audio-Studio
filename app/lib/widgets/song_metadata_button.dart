import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';
import 'rm_field.dart';
import '../theme/tokens.dart';
import 'timing_dialog_frame.dart';

class SongMetadataButton extends StatelessWidget {
  const SongMetadataButton({
    super.key,
    required this.title,
    required this.artist,
    required this.onSave,
    this.enabled = true,
    this.bpm,
    this.onBpm,
  });
  final double? bpm;
  final ValueChanged<double>? onBpm;
  final String title;
  final String artist;
  final bool enabled;
  final Future<bool> Function(String title, String artist) onSave;

  @override
  Widget build(BuildContext context) => RmButton(
    label: '编辑歌曲信息',
    onPressed: enabled
        ? () => showDialog<void>(
            context: context,
            barrierColor: RmTokens.modalBackdrop,
            builder: (_) => _MetadataDialog(
              title: title,
              artist: artist,
              onSave: onSave,
              bpm: bpm,
              onBpm: onBpm,
            ),
          )
        : null,
  );
}

class _MetadataDialog extends StatefulWidget {
  const _MetadataDialog({
    required this.title,
    required this.artist,
    required this.onSave,
    this.bpm,
    this.onBpm,
  });
  final double? bpm;
  final ValueChanged<double>? onBpm;
  final String title;
  final String artist;
  final Future<bool> Function(String, String) onSave;
  @override
  State<_MetadataDialog> createState() => _MetadataDialogState();
}

class _MetadataDialogState extends State<_MetadataDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _artist = TextEditingController(text: widget.artist);
  late final _bpm = TextEditingController(
    text: widget.bpm?.toStringAsFixed(3) ?? '',
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _bpm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bpm = double.tryParse(_bpm.text.trim());
    if (widget.bpm != null &&
        (bpm == null || !bpm.isFinite || bpm < 20 || bpm > 400)) {
      setState(() => _error = 'BPM 请输入 20–400 之间的数值');
      return;
    }
    final values = [_title.text.trim(), _artist.text.trim()];
    if (values.any(
      (s) =>
          s.isEmpty ||
          s.runes.length > 256 ||
          s.runes.any((c) => c < 32 || c == 127),
    )) {
      setState(() => _error = '歌曲名和歌手不能为空，最多 256 个字符，不能包含换行。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.onSave(values[0], values[1]);
      if (!mounted) return;
      if (ok) {
        if (bpm != null) widget.onBpm?.call(bpm);
        Navigator.of(context).pop();
        return;
      }
      setState(() => _error = '保存失败，请查看底部提示或任务日志。');
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return TimingDialogFrame(
      title: '编辑歌曲信息',
      icon: 'music',
      description: '调整歌曲在软件和游戏中显示的信息',
      busy: _busy,
      width: 580,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('歌曲名', style: RmText.sans(12, color: rm.fg2)),
          const SizedBox(height: 8),
          TextField(
            controller: _title,
            enabled: !_busy,
            autofocus: true,
            style: RmText.sans(14, color: rm.fg),
            decoration: rmFieldDecoration(context, hint: '输入歌曲名'),
          ),
          const SizedBox(height: 16),
          Text('歌手', style: RmText.sans(12, color: rm.fg2)),
          const SizedBox(height: 8),
          TextField(
            controller: _artist,
            enabled: !_busy,
            style: RmText.sans(14, color: rm.fg),
            decoration: rmFieldDecoration(context, hint: '输入歌手'),
          ),
          const SizedBox(height: 16),
          if (widget.bpm != null) ...[
            Text('BPM · 每分钟节拍数', style: RmText.sans(12, color: rm.fg2)),
            const SizedBox(height: 8),
            TextField(
              controller: _bpm,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: RmText.mono(14, color: rm.fg),
              decoration: rmFieldDecoration(context, hint: '20–400'),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            '重新构建并写入游戏后生效，BPM 调整后请在歌曲页保存。音频文件和时间点保持不变。',
            style: RmText.body(color: rm.fg3),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: rm.danger)),
          ],
        ],
      ),
      actions: [
        RmButton(
          label: '取消',
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        RmButton(
          label: '保存歌曲信息',
          variant: RmButtonVariant.primary,
          onPressed: _busy ? null : _save,
        ),
      ],
    );
  }
}
