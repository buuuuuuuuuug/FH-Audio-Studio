import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class WaveformTimeGrid {
  WaveformTimeGrid(double span, double width) {
    final pixelsPerSecond = math.max(1, width) / math.max(.00001, span);
    var minor = .1;
    while (minor * pixelsPerSecond < 6) {
      minor *= 10;
    }
    while (minor * pixelsPerSecond > 60 && minor > .00001) {
      minor /= 10;
    }
    minorStep = minor;
    var label = minor * 5;
    while (label * pixelsPerSecond < 80) {
      label *= 2;
    }
    labelStep = label;
  }
  late final double minorStep, labelStep;
}

/// Time guides remain available before beat detection or with empty audio.
void paintWaveformGrid(
  Canvas canvas, {
  required RmTheme rm,
  required double width,
  required double start,
  required double end,
  required double top,
  required double height,
}) {
  if (width <= 0 || height <= 0) return;
  final span = math.max(.001, end - start);
  canvas.drawRect(
    Rect.fromLTWH(0, top, width, height),
    Paint()..color = rm.raised.withAlpha(45),
  );
  final step = WaveformTimeGrid(span, width).minorStep;
  for (var i = (start / step).ceil(); i * step <= end + .000001; i++) {
    final major = i % 5 == 0, x = (i * step - start) / span * width;
    canvas.drawLine(
      Offset(x, top),
      Offset(x, top + height),
      Paint()
        ..color = major
            ? rm.borderStrong.withAlpha(145)
            : rm.border.withAlpha(125)
        ..strokeWidth = major ? 1 : .5,
    );
  }
}
