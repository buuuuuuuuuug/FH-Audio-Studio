part of '../voice_replacement.dart';

extension _VoiceGeneration on _VoiceReplacementState {
  Future<void> _unapplyGenerated(
    Map<String, dynamic> target,
    String? assetId,
  ) async {
    if (!mounted || target.isEmpty || assetId == null) return;
    final next = stingerClone(_edits),
        bank = '${target['bank_id']}',
        index = '${target['index']}';
    final changes = stingerMap(next[bank]);
    if (stingerMap(changes[index])['asset_id'] != assetId) {
      return;
    }
    changes.remove(index);
    next[bank] = changes;
    _change(next);
  }

  Map<String, dynamic> _generationTargetSnapshot(Map<String, dynamic> target) {
    _cacheWorkspace();
    return {
      ...target,
      'expected': stingerMap(
        _edits['${target['bank_id']}'],
      )['${target['index']}'],
    };
  }

  SpeechGenerationSession _speechSession() {
    if (_speech case final session?) return session;
    final studio = ref.read(studioProvider);
    final session = ref.read(
      speechGenerationProvider(jsonEncode([studio.repoRoot, _project])),
    );
    final workspace = _session, project = _project;
    session.receive = (data) => workspace.acceptGeneration(project, data);
    session.addListener(_refreshGenerated);
    _speech = session;
    unawaited(session.start());
    return session;
  }

  void _refreshGenerated() {
    if (!mounted || _generationRevision == _session.generationRevision) return;
    final view = _session.view;
    if (view == null) return;
    _generationRevision = _session.generationRevision;
    _update(() {
      _assets = stingerMaps(view['assets']);
      _edits = stingerMap(view['edits']);
      _assetFolders.addAll(_assets.map((a) => '${a['category']}'));
      _openAssetFolders.add('生成语音');
      _packageReady = false;
      _notice = '${view['generationNotice'] ?? '生成语音已加入草稿，请试听后保存。'}';
    });
  }

  Map<String, dynamic> _speechEntry(
    Map<String, dynamic> entry, {
    bool target = true,
  }) => {
    ...entry,
    'text': '${entry['content'] ?? ''}',
    'language': speechLanguage(ref.read(studioProvider).targetLang),
    'display_language': speechLanguage(ref.read(studioProvider).sourceLang),
    if (target)
      'target': {
        'bank_id': _bank['id'],
        'sha256': _bank['sha256'],
        'index': entry['index'],
        'expected': _replacements['${entry['index']}'],
      },
  };

  Future<void> _openGeneration({bool material = false}) async {
    _cacheWorkspace();
    final session = _speechSession();
    await session.start();
    if (!mounted) return;
    final configuration = SpeechConfiguration(session);
    final ready =
        configuration.ready &&
        (session.engine['installed'] == true ||
            speechMap(session.engine['connection'])['mode'] == 'existing');
    configuration.dispose();
    if (!ready) {
      final navigate = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialog) => TimingDialogFrame(
          title: '请先配置语音生成',
          icon: 'settings',
          width: 500,
          busy: false,
          description: '尚未完成引擎与声音配置',
          body: Text(
            '请前往语音生成，安装或连接 GPT-SoVITS，再选择声音模型和参考音频。配置完成后即可在这里生成替换语音。',
            style: RmText.body(color: dialog.rm.fg2),
          ),
          actions: [
            RmButton(
              label: '暂不设置',
              onPressed: () => Navigator.pop(dialog, false),
            ),
            RmButton(
              label: '前往语音生成',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('spark', size: 12),
              onPressed: () => Navigator.pop(dialog, true),
            ),
          ],
        ),
      );
      if (navigate == true && mounted) context.go(RmRoutes.speech);
      return;
    }
    _refreshGenerated();
    final entries = material || _entry == null
        ? [
            {
              'name': '生成语音素材',
              'text': '',
              'language': speechLanguage(ref.read(studioProvider).targetLang),
            },
          ]
        : [
            for (final entry in _entries.where(
              (e) => _selectingExport
                  ? _exportEntries.contains(e['index'])
                  : e['index'] == _index,
            ))
              _speechEntry(entry),
          ];
    if (entries.isEmpty) {
      _update(() => _notice = '请先选择需要生成的音频条目。');
      return;
    }
    _update(() => _generationEntries = entries);
    unawaited(session.start());
  }
}
