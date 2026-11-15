import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/speech_configuration.dart';
import '../../core/speech_generation.dart';
import '../../theme/app_theme.dart';
import 'speech_workbench_header.dart';
import '../../widgets/feature_tour.dart';
import 'rvc_configuration.dart';
import 'speech_results.dart';
import 'speech_setup_guidance.dart';

class RvcWorkbench extends StatefulWidget {
  const RvcWorkbench({
    super.key,
    required this.session,
    required this.onTextMode,
    this.preferences,
    this.featureTour = false,
  });
  final SpeechGenerationSession session;
  final VoidCallback onTextMode;
  final SharedPreferences? preferences;
  final bool featureTour;
  @override
  State<RvcWorkbench> createState() => _RvcWorkbenchState();
}

class _RvcWorkbenchState extends State<RvcWorkbench> {
  late final SpeechConfiguration _resultsConfiguration;
  double _ratio = .32, _startRatio = .32, _startX = 0;
  @override
  void initState() {
    super.initState();
    _ratio = widget.preferences?.getDouble('rvc.configurationRatio') ?? .32;
    _resultsConfiguration = SpeechConfiguration(widget.session);
    unawaited(widget.session.start());
  }

  @override
  void dispose() {
    _resultsConfiguration.dispose();
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
  Widget _configuration() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SpeechConfigurationHeader(
          session: widget.session,
          conversion: true,
          onSettings: () => showRvcEngineDialog(context, widget.session),
        ).tourAnchor('rvc-engine'),
        Divider(height: 1, color: context.rm.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: RvcConfigurationPanel(session: widget.session),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (_, _) {
      final workbench = Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SpeechWorkbenchHeader(
              description: 'RVC 将已有语音转换为指定音色，保留原句内容与节奏。',
              conversion: true,
              onSwitch: widget.onTextMode,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (_, box) {
                  if (widget.session.engine['installed'] != true) {
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 660),
                        child: SingleChildScrollView(
                          child: SpeechSetupGuidance(
                            session: widget.session,
                            conversion: true,
                            onSettings: () =>
                                showRvcEngineDialog(context, widget.session),
                          ),
                        ),
                      ),
                    );
                  }
                  final results = _card(
                    SpeechResults(
                      configuration: _resultsConfiguration,
                      conversion: true,
                    ),
                  );
                  if (box.maxWidth < 720) {
                    return Column(
                      children: [
                        SizedBox(
                          height: math.min(300, box.maxHeight * .45),
                          child: _configuration(),
                        ),
                        const SizedBox(height: 10),
                        Expanded(child: results),
                      ],
                    );
                  }
                  final available = box.maxWidth - 10,
                      left = (available * _ratio)
                          .clamp(280.0, available - 340)
                          .toDouble();
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: left, child: _configuration()),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (d) {
                            _startX = d.globalPosition.dx;
                            _startRatio = left / available;
                          },
                          onHorizontalDragUpdate: (d) => setState(
                            () => _ratio =
                                (_startRatio +
                                        (d.globalPosition.dx - _startX) /
                                            available)
                                    .clamp(
                                      280 / available,
                                      1 - 340 / available,
                                    ),
                          ),
                          onHorizontalDragEnd: (_) => widget.preferences
                              ?.setDouble('rvc.configurationRatio', _ratio),
                          onDoubleTap: () {
                            setState(() => _ratio = .32);
                            widget.preferences?.setDouble(
                              'rvc.configurationRatio',
                              _ratio,
                            );
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
                      Expanded(child: results),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
      final selected = speechMap(
        widget.session.engine['selection'],
      )['model_id'];
      final hasModel = speechMaps(
        widget.session.engine['files'],
      ).any((file) => file['kind'] == 'model' && file['id'] == selected);
      return widget.featureTour
          ? workbench.withFeatureTour(
              TourPage.rvc,
              enabled:
                  widget.session.engine['installed'] == true &&
                  hasModel &&
                  !widget.session.busy,
            )
          : workbench;
    },
  );
}
