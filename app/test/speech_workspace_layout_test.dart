import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [720.0, 1000.0, 1700.0]) {
    testWidgets('resource collapse restores view without rereading at $width', (
      t,
    ) async {
      var scans = 0;
      await base.open(
        t,
        Size(width, 900),
        [],
        responder: (a, o) async {
          if (a == 'scan') {
            scans++;
            return data.scan();
          }
          return {};
        },
      );
      final field = find.descendant(
        of: find.byKey(const ValueKey('voice-resource-filter')),
        matching: find.byType(TextField),
      );
      await t.enterText(field, 'Route');
      await t.pumpAndSettle();
      final before = scans;
      await t.tap(find.byKey(const ValueKey('voice-collapse-resources')));
      await t.pumpAndSettle();
      expect(
        t
            .getSize(find.byKey(const ValueKey('voice-resources-collapsed')))
            .width,
        36,
      );
      expect(find.byKey(const ValueKey('voice-resource-filter')), findsNothing);
      expect(find.byKey(const ValueKey('voice-pool-category')), findsNothing);
      await t.tap(find.byKey(const ValueKey('voice-expand-resources')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field).controller!.text, 'Route');
      expect(scans, before);
      expect(t.takeException(), isNull);
    });
  }
}
