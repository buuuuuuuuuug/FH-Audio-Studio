import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'project_refs.dart';

/// A disposable view cache. Project plans and CLI parsing remain authoritative.
/// Validation uses filesystem metadata only, never game-file parsing or names.
class WorkspaceSnapshot {
  WorkspaceSnapshot(this.path, this.key, this.project);
  final String path, key, project;
  Future<void> _writes = Future.value();
  Future<Map<String, dynamic>?> read() => _readSnapshotAsync(path, key);

  Future<void> write(Map<String, dynamic> data, List<String> dependencies) {
    final args = (path, key, project, data, dependencies);
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => _writeSnapshotAsync(args));
  }
}

Future<Map<String, dynamic>?> _readSnapshotAsync(String path, String key) =>
    Isolate.run(() => _readSnapshot(path, key));

Map<String, dynamic>? _readSnapshot(String path, String key) {
  try {
    final raw = jsonDecode(File(path).readAsStringSync()) as Map;
    if (raw['version'] != 1 || raw['key'] != key) return null;
    for (final stamp in raw['dependencies'] as List) {
      if (jsonEncode(_stamp(stamp[0] as String)) != jsonEncode(stamp)) {
        return null;
      }
    }
    return Map<String, dynamic>.from(raw['view'] as Map);
  } on Object {
    return null;
  }
}

List<Object> _stamp(String path) {
  final stat = FileStat.statSync(path);
  return [
    path,
    stat.type.toString(),
    stat.size,
    stat.modified.microsecondsSinceEpoch,
  ];
}

Future<void> _writeSnapshotAsync(
  (String, String, String, Map<String, dynamic>, List<String>) args,
) => Isolate.run(() => _writeSnapshot(args));

void _writeSnapshot(
  (String, String, String, Map<String, dynamic>, List<String>) args,
) {
  final (path, key, project, view, supplied) = args;
  final dependencies = <String>{...supplied};
  void collect(Object? value) {
    if (value is Map) {
      for (final child in value.values) {
        collect(child);
      }
    } else if (value is List) {
      for (final child in value) {
        collect(child);
      }
    } else if (value is String) {
      if (isProjectRef(value)) {
        dependencies.add(resolveProjectRef(project, value));
      } else if (p.isAbsolute(value) &&
          FileSystemEntity.typeSync(value) == FileSystemEntityType.file) {
        dependencies.add(value);
      }
    }
  }

  collect(view);
  for (final dependency in dependencies.toList()) {
    final parent = p.dirname(dependency);
    // Project settings are atomically rewritten at startup. Their directory
    // timestamp must not invalidate an unchanged plan or this cache itself.
    if (parent != p.join(project, '.fh-radio-studio') &&
        parent != p.dirname(path)) {
      dependencies.add(parent);
    }
  }
  final sorted = dependencies.toList()..sort();
  final stamps = sorted.map(_stamp).toList();
  File(path).parent.createSync(recursive: true);
  final temp = File('$path.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
  try {
    temp.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'key': key,
        'dependencies': stamps,
        'view': view,
      }),
    );
    temp.renameSync(path);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}
