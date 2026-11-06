part of '../voice_replacement.dart';

// Route widgets are disposable. The workspace and its draft belong to the
// project and source game directory and remain available while visiting another
// tool or song page. Draft files remain project-owned across directory changes.
class VoiceWorkspaceSession {
  int generationRevision = 0;
  Future<void> acceptGeneration(
    String project,
    Map<String, dynamic> data,
  ) async {
    final current = view;
    if (current == null) return;
    final plan = stingerMap(data['plan']);
    if (data['removed_asset_ids'] case final List removed) {
      final ids = removed.toSet();
      current['assets'] = stingerMaps(
        current['assets'],
      ).where((a) => !ids.contains(a['id'])).toList();
      for (final raw in [
        current['edits'],
        current['saved'],
        ...(current['undo'] as List? ?? []),
        ...(current['redo'] as List? ?? []),
      ]) {
        if (raw is Map) {
          for (final bank in raw.values) {
            if (bank is Map) {
              bank.removeWhere(
                (_, e) => ids.contains(stingerMap(e)['asset_id']),
              );
            }
          }
        }
      }
      current['ready'] = false;
      current['generationNotice'] = '生成文件及其替换已删除。';
      generationRevision++;
      await writeDraft(
        project,
        stingerMap(current['edits']),
        stingerMap(current['saved']),
      );
      return;
    }
    final assets = {
      for (final a in stingerMaps(current['assets'])) '${a['id']}': a,
    };
    for (final a
        in data['asset'] is Map
            ? [stingerMap(data['asset'])]
            : stingerMaps(plan['assets'])) {
      assets['${a['id']}'] = a;
    }
    current['assets'] = assets.values.toList();
    final target = stingerMap(data['target']);
    if (target.isNotEmpty) {
      final edits = stingerClone(stingerMap(current['edits']));
      final bankId = '${target['bank_id']}', index = '${target['index']}';
      final changes = stingerMap(edits[bankId]);
      final existing = changes[index];
      final sameJob =
          data['previous_edit'] != null &&
          jsonEncode(existing) == jsonEncode(data['previous_edit']);
      if (jsonEncode(existing) == jsonEncode(data['expected']) || sameJob) {
        final undo = current['undo'] as List;
        undo.add(stingerClone(stingerMap(current['edits'])));
        if (undo.length > 100) undo.removeAt(0);
        (current['redo'] as List).clear();
        changes[index] = data['edit'];
        edits[bankId] = changes;
        current['edits'] = edits;
        current['ready'] = false;
        current['generationNotice'] = '生成语音已采用到草稿，请试听后保存。';
        data['applied_to_target'] = true;
        await writeDraft(project, edits, stingerMap(current['saved']));
      } else {
        current['generationNotice'] = '生成已加入素材池；目标条目在生成期间有修改，未覆盖。';
        data['applied_to_target'] = false;
      }
    }
    generationRevision++;
  }

  Map<String, dynamic>? view;
  bool loaded = false;
  Future<Map<String, dynamic>>? scan;
  String? _scanKey;
  Future<void> _writes = Future.value();
  Future<void> flushDrafts() => _writes;

  Future<Map<String, dynamic>> readScan(
    Future<Map<String, dynamic>> Function() load, {
    String? key,
  }) async {
    final previous = scan;
    if (previous != null && _scanKey != key) {
      try {
        await previous;
      } on Object {
        // A different language request must retry instead of inheriting it.
      }
    }
    if (scan == null) _scanKey = key;
    final pending = scan ??= load();
    try {
      return await pending;
    } finally {
      // A rejected scan is not a cache value. Preserve shared in-flight work,
      // but let the next request retry after either success or failure.
      if (identical(scan, pending)) scan = null;
    }
  }

  Future<void> writeDraft(
    String project,
    Map<String, dynamic> edits,
    Map<String, dynamic> saved,
  ) {
    final text = jsonEncode({'version': 1, 'edits': edits, 'saved': saved});
    final file = File(p.join(project, 'analysis', 'voices', 'draft.json'));
    final clean = jsonEncode(edits) == jsonEncode(saved);
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      if (clean) {
        if (await file.exists()) await file.delete();
      } else {
        await writeTextAtomically(file, text);
      }
    });
  }

  Future<Map<String, dynamic>?> readDraft(String project) async {
    final file = File(p.join(project, 'analysis', 'voices', 'draft.json'));
    if (!await file.exists()) return null;
    final data = stingerMap(jsonDecode(await file.readAsString()));
    return data['version'] == 1 ? data : null;
  }
}

final voiceWorkspaceSessionProvider =
    Provider.family<VoiceWorkspaceSession, String>(
      (ref, project) => VoiceWorkspaceSession(),
    );

extension _VoiceSession on _VoiceReplacementState {
  void _rebaseUpdatedBanks(Map<String, dynamic> plan) {
    for (final item in stingerMap(plan['banks']).entries) {
      final bank = stingerMap(item.value);
      var sha = stingerMap(_catalogs[item.key]?['bank'])['sha256'];
      if (sha == null || sha == bank['sha256']) continue;
      for (final step in stingerMaps(bank['update_history'])) {
        if (step['from_sha256'] != sha) continue;
        final mapping = stingerMap(step['mapping']);
        for (final state in [_edits, _saved, ..._undo, ..._redo]) {
          if (!state.containsKey(item.key)) continue;
          final old = stingerMap(state[item.key]);
          state[item.key] = {
            for (final e in old.entries)
              if (mapping.containsKey(e.key)) '${mapping[e.key]}': e.value,
          };
        }
        sha = step['to_sha256'];
      }
      _notice = bank['update_notice'] as String?;
      _previewPaths.clear();
      _exportEntries.clear();
    }
  }

  void _cacheWorkspace() {
    _session.view = {
      'textLanguages': _textLanguages,
      'files': _files,
      'assets': _assets,
      'entries': _entries,
      'edits': _edits,
      'saved': _saved,
      'bank': _bank,
      'pending': _pending,
      'catalogs': _catalogs,
      'undo': _undo,
      'redo': _redo,
      'folders': _assetFolders.toList(),
      'openFolders': _openAssetFolders.toList(),
      'expanded': _expanded.toList(),
      'previews': _previewPaths,
      // Only completed data belongs to the project cache. Worker requests are
      // owned by the current route and are cancelled when that route closes.
      'waveData': _assetWaveData,
      'preferred': _preferredBank,
      'index': _index,
      'ready': _packageReady,
      'fileQuery': _fileSearch.text,
      'entryQuery': _entrySearch.text,
      'assetQuery': _assetSearch.text,
      'assetSort': _assetSort,
      'assetDescending': _assetDescending,
      'assetStatus': _assetStatus,
      'assetCategory': _assetCategory,
      'generationEntries': _generationEntries,
      'language': _language,
      'assetSelecting': _selectingAssets,
      'selectedAssets': _selectedAssets.toList(),
      'assetSelected': _selectedAsset,
      'assetAnchor': _assetAnchor,
      'entrySelecting': _selectingExport,
      'selectedEntries': _exportEntries.toList(),
      'entryAnchor': _entryAnchor,
      'fileOffset': _fileScroll.hasClients ? _fileScroll.offset : 0.0,
      'entryOffset': _entryScroll.hasClients ? _entryScroll.offset : 0.0,
    };
    _persistView();
  }

  void _restoreWorkspace(Map<String, dynamic> data) {
    _textLanguages = _requestedTextLanguages = data['textLanguages'] as String?;
    _files = stingerMaps(data['files']);
    _assets = stingerMaps(data['assets']);
    _entries = stingerMaps(data['entries']);
    _edits = stingerMap(data['edits']);
    _saved = stingerMap(data['saved']);
    _bank = stingerMap(data['bank']);
    _pending = data['pending'] == null ? null : stingerMap(data['pending']);
    for (final e in stingerMap(data['catalogs']).entries) {
      _catalogs[e.key] = stingerMap(e.value);
    }
    _undo.addAll(stingerMaps(data['undo']));
    _redo.addAll(stingerMaps(data['redo']));
    _assetFolders
      ..clear()
      ..addAll(List<String>.from(data['folders']));
    _openAssetFolders
      ..clear()
      ..addAll(List<String>.from(data['openFolders']));
    _expanded
      ..clear()
      ..addAll(List<String>.from(data['expanded']));
    _previewPaths.addAll(Map<String, String>.from(data['previews']));
    _assetWaveData.addAll(
      Map<String, Map<String, dynamic>>.from(data['waveData'] ?? {}),
    );
    _preferredBank = data['preferred'] as String?;
    _index = data['index'] as int;
    _packageReady = data['ready'] == true;
    _fileSearch.text = '${data['fileQuery'] ?? ''}';
    _entrySearch.text = '${data['entryQuery'] ?? ''}';
    _assetSearch.text = '${data['assetQuery'] ?? ''}';
    _assetSort = '${data['assetSort'] ?? 'added'}';
    _assetDescending = data['assetDescending'] == true;
    _assetStatus = '${data['assetStatus'] ?? 'all'}';
    _assetCategory = '${data['assetCategory'] ?? ''}';
    if (ref.read(editorOptionsProvider).speechEnabled &&
        data['generationEntries'] != null) {
      _generationEntries = stingerMaps(data['generationEntries']);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _speechSession();
      });
    }
    _language = '${data['language'] ?? '当前语言'}';
    _selectingAssets = data['assetSelecting'] == true;
    _selectedAssets.addAll(List<String>.from(data['selectedAssets'] ?? []));
    _selectedAsset = data['assetSelected'] as String?;
    _assetAnchor = data['assetAnchor'] as String?;
    _selectingExport = data['entrySelecting'] == true;
    _exportEntries.addAll(List<int>.from(data['selectedEntries'] ?? []));
    _entryAnchor = data['entryAnchor'] as int?;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final item in [
        (_fileScroll, 'fileOffset'),
        (_entryScroll, 'entryOffset'),
      ]) {
        if (item.$1.hasClients) {
          item.$1.jumpTo(
            stingerNumber(
              data[item.$2],
            ).clamp(0, item.$1.position.maxScrollExtent),
          );
        }
      }
    });
  }

  Future<void> _persistDraft() async {
    _cacheWorkspace();
    if (widget.request != null) return;
    try {
      await _session.writeDraft(_project, _edits, _saved);
    } on Object catch (e) {
      _update(() => _error = '草稿缓存失败，请保存修改：$e');
    }
  }

  Future<void> _recoverDraft() async {
    if (widget.request != null) return;
    try {
      final draft = await _session.readDraft(_project);
      if (draft == null || !mounted) return;
      final before = stingerMap(draft['saved']);
      final changes = stingerMap(draft['edits']);
      _update(() {
        for (final e in changes.entries) {
          if (_saved.containsKey(e.key) &&
              jsonEncode(before[e.key]) == jsonEncode(_saved[e.key])) {
            _edits[e.key] = e.value;
          }
        }
        if (_dirty) _notice = '已恢复未保存的语音草稿。保存后才会用于构建。';
      });
    } on Object catch (e) {
      _update(() => _error = '无法读取上次草稿，原文件已保留：$e');
    }
  }
}
