import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/workspace_snapshot.dart';

void main() {
  test(
    'startup settings rewrite does not invalidate an unchanged project plan',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'audio-cache-settings-',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      final plan = File(p.join(project.path, '.fh-radio-studio', 'voices.json'))
        ..parent.createSync(recursive: true);
      plan.writeAsStringSync('{}');
      final cache = WorkspaceSnapshot(
        p.join(project.path, 'analysis', 'voices', 'view.json'),
        'JP',
        project.path,
      );
      await cache.write({'loaded': true}, [plan.path]);
      File(
        p.join(plan.parent.path, 'project.json'),
      ).writeAsStringSync('{"last_opened_at":"new"}');
      expect(await cache.read(), isNotNull);
      plan.writeAsStringSync('{"changed":true}');
      expect(await cache.read(), isNull);
    },
  );
  test(
    'workspace survives a new instance and rejects changed inputs or language',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'audio-workspace-cache-',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      final source = File(p.join(project.path, 'sources', 'voice.wav'))
        ..parent.createSync(recursive: true);
      source.writeAsStringSync('original');
      final path = p.join(project.path, 'analysis', 'view.json');
      final first = WorkspaceSnapshot(path, 'JP/CHS', project.path);
      await first.write({
        'assets': [
          {'source': 'fh-project:/sources/voice.wav'},
        ],
        'selected': 7,
      }, []);
      expect(
        (await WorkspaceSnapshot(
          path,
          'JP/CHS',
          project.path,
        ).read())?['selected'],
        7,
      );
      expect(
        await WorkspaceSnapshot(path, 'CN/CHS', project.path).read(),
        isNull,
      );
      source.writeAsStringSync('changed original audio');
      expect(await first.read(), isNull);
    },
  );

  test(
    'directory changes invalidate discovered resource list; corrupt cache is optional',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'audio-cache-directory-',
      );
      addTearDown(() => project.deleteSync(recursive: true));
      final banks = Directory(p.join(project.path, 'game', 'banks'))
        ..createSync(recursive: true);
      final cache = WorkspaceSnapshot(
        p.join(project.path, 'cache', 'view.json'),
        'key',
        project.path,
      );
      await cache.write({'files': []}, [banks.path]);
      expect(await cache.read(), isNotNull);
      File(p.join(banks.path, 'new.bank')).writeAsStringSync('new resource');
      expect(await cache.read(), isNull);
      File(cache.path).writeAsStringSync('incomplete');
      expect(await cache.read(), isNull);
    },
  );
}
