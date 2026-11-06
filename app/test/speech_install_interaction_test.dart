import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/speech_engine_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'speech_generation_test.dart' show FakeSpeech;

class InstallSpeech extends FakeSpeech {
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> input = const {},
  ]) async {
    actions.add(action);
    if (action == 'engine-logs') return {'text': 'preserved output'};
    if (action == 'pause-install') {
      state['jobs'][0]['status'] = 'paused';
      notifyListeners();
    }
    return super.call(action, input);
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('console reads again after reopening and only clears manually', (
    t,
  ) async {
    final speech = InstallSpeech();
    addTearDown(speech.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SpeechEngineConsole(session: speech, initiallyExpanded: true),
        ),
      ),
    );
    await t.pump();
    expect(find.text('preserved output'), findsOneWidget);
    await t.tap(find.text('收起控制台'));
    await t.pump();
    expect(speech.actions, isNot(contains('clear-engine-logs')));
    await t.tap(find.text('控制台输出'));
    await t.pump();
    expect(find.text('preserved output'), findsOneWidget);
    await t.tap(find.text('清空输出'));
    await t.pump();
    expect(speech.actions.where((a) => a == 'clear-engine-logs').length, 1);
    await t.pumpWidget(const SizedBox());
    expect(speech.actions.where((a) => a == 'clear-engine-logs').length, 1);
  });

  testWidgets(
    'closing an installing engine offers pause and resumes the same workflow',
    (t) async {
      t.view.physicalSize = const Size(1400, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final speech = InstallSpeech();
      addTearDown(speech.dispose);
      speech.state['engine']['installed'] = false;
      speech.state['engine']['presets'] = [];
      speech.state['jobs'] = [
        {
          'id': 'install',
          'kind': 'install',
          'status': 'running',
          'progress': '下载模型 10 / 100 MiB',
          'download': {'fraction': .1},
        },
      ];
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => RmButton(
                label: '打开',
                onPressed: () =>
                    unawaited(showSpeechEngineDialog(context, speech)),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('下载模型 10 / 100 MiB'), findsOneWidget);
      expect(find.widgetWithText(RmButton, '检查模型'), findsNothing);
      await t.tap(find.widgetWithText(RmButton, '完成'));
      await t.pumpAndSettle();
      expect(find.text('安装还在进行'), findsOneWidget);
      await t.tap(find.text('暂停并关闭'));
      await t.pumpAndSettle();
      expect(speech.actions, contains('pause-install'));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(find.text('安装已暂停'), findsOneWidget);
      expect(find.widgetWithText(RmButton, '继续安装'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
