import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [560.0, 640.0, 800.0]) {
    testWidgets('tabs remain reachable at $width', (t) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      t.view.physicalSize = Size(width, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: TabsBar(activeId: 'dashboard'),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      final scroll = find.byType(SingleChildScrollView);
      expect(scroll, findsOneWidget);
      await t.drag(scroll, const Offset(-900, 0));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('设置').hitTestable(), findsOneWidget);
    });
  }
}
