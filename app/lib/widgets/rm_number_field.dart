import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_field.dart';
import 'rm_icon.dart';

/// The material editor's compact up/down input, shared by synthesis controls.
class RmNumberField extends StatelessWidget {
  const RmNumberField({
    super.key,
    required this.controller,
    required this.min,
    required this.max,
    required this.step,
    this.decimals = 2,
    this.enabled = true,
    this.onChanged,
    this.unit,
  });
  final TextEditingController controller;
  final double min, max, step;
  final int decimals;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final String? unit;

  void _move(double delta) {
    final value = ((double.tryParse(controller.text) ?? min) + delta).clamp(
      min,
      max,
    );
    controller.text = value.toStringAsFixed(decimals);
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    onChanged?.call(controller.text);
  }

  @override
  Widget build(BuildContext context) {
    Widget arrow(String icon, double delta) => SizedBox(
      width: 24,
      height: 16,
      child: InkWell(
        onTap: enabled ? () => _move(delta) : null,
        child: Center(
          child: RmIcon(
            icon,
            size: 11,
            color: enabled ? context.rm.fg3 : context.rm.fg4,
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: enabled
          ? {
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _move(step),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _move(-step),
            }
          : {},
      child: TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        style: RmText.mono(12, color: context.rm.fg),
        textAlignVertical: TextAlignVertical.center,
        decoration: rmFieldDecoration(context).copyWith(
          suffixText: unit,
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: 24,
            height: 32,
          ),
          suffixIcon: Column(
            mainAxisSize: MainAxisSize.min,
            children: [arrow('chevron-up', step), arrow('chevron-down', -step)],
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}
