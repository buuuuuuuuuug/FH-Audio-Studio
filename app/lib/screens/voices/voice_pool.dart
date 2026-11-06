part of '../voice_replacement.dart';

extension _VoicePool on _VoiceReplacementState {
  Future<void> _folderCommand(
    String action, {
    String? folder,
    List<String>? ids,
    String? renameTo,
    bool? deleteAssets,
  }) async {
    if (_locked) return;
    var name = folder;
    String? target;
    if (action == 'create') {
      final prefix = folder == null || folder == '未分类' ? '' : '$folder/';
      name = '$prefix新建文件夹';
      var suffix = 2;
      while (_assetFolders.contains(name)) {
        name = '$prefix新建文件夹 ($suffix)';
        suffix++;
      }
    }
    if (action == 'rename') {
      target =
          renameTo ??
          await _askText('重命名素材文件夹', '子文件夹和素材会一同移动', initial: folder ?? '');
    }
    if (name == null || action == 'rename' && target == null) return;
    if (!mounted) return;
    if (action == 'delete') {
      final affected = _assets
          .where(
            (a) =>
                a['category'] == name ||
                '${a['category']}'.startsWith('$name/'),
          )
          .toList();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => TimingDialogFrame(
            title: '删除素材文件夹？',
            icon: 'trash',
            busy: false,
            width: 460,
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('删除“$name”及其子文件夹。', style: RmText.body(color: ctx.rm.fg2)),
                if (affected.isNotEmpty)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      '同时从素材池移除 ${affected.length} 条素材',
                      style: RmText.sans(12, color: ctx.rm.fg),
                    ),
                    subtitle: Text(
                      deleteAssets == true
                          ? '相关替换也会移除；原始导入文件保留。'
                          : '不勾选时，素材移到“未分类”。',
                      style: RmText.sans(11, color: ctx.rm.fg3),
                    ),
                    value: deleteAssets == true,
                    onChanged: (v) => update(() => deleteAssets = v),
                  ),
              ],
            ),
            actions: [
              RmButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
              RmButton(
                label: '删除文件夹',
                leading: const RmIcon('trash', size: 12),
                variant: RmButtonVariant.dangerPrimary,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      );
      if (accepted != true || !mounted) return;
    }
    await _guard(() async {
      final data = await _call('folders', {
        'input': {
          'action': action,
          'name': name!.replaceAll(' / ', '/'),
          'target': target,
          'assets': ids,
          if (action == 'delete') 'delete_assets': deleteAssets == true,
        },
      });
      _update(() {
        _assetFolders.clear();
        _assetFolders.add('未分类');
        _hydrate(stingerMap(data['plan']));
        if (action == 'delete') {
          final valid = _assets.map((a) => a['id']).toSet();
          for (final data in [_edits, _saved, ..._undo, ..._redo]) {
            for (final bank in data.values) {
              (bank as Map).removeWhere(
                (_, e) => !valid.contains(e['asset_id']),
              );
            }
          }
          _selectedAssets.removeWhere((id) => !valid.contains(id));
          _assetWaveData.removeWhere((id, _) => !valid.contains(id));
          if (!valid.contains(_selectedAsset)) {
            _selectedAsset = _selectedAssets.firstOrNull;
          }
          _previewPaths.clear();
          _packageReady = false;
          unawaited(_persistDraft());
        }
        if (action == 'move' || action == 'create') {
          _openAssetFolders.add(name!);
          if (action == 'create') {
            _renamingFolder = name;
            _folderName.text = name.split('/').last;
            _folderName.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _folderName.text.length,
            );
          }
        }
      });
    });
  }

  Future<void> _removeMaterial(Map<String, dynamic> asset) async {
    if (_locked) return;
    await _removeMaterials({'${asset['id']}'});
  }

  Future<void> _removeMaterials(Set<String> ids) async {
    if (_locked || ids.isEmpty) return;
    final used = <String>{};
    for (final data in [_edits, _saved]) {
      for (final bank in data.entries) {
        for (final e in stingerMap(bank.value).entries) {
          if (ids.contains(stingerMap(e.value)['asset_id'])) {
            used.add('${bank.key}:${e.key}');
          }
        }
      }
    }
    if (used.isNotEmpty &&
        !await _confirm(
          '删除素材？',
          '所选 ${ids.length} 条素材用于 ${used.length} 条替换，将删除工程内音频副本并清除这些替换。导入前的原文件保留。',
          '删除素材',
        )) {
      return;
    }
    if (!mounted) return;
    await _guard(() async {
      if (ids.any((id) => _playing == 'asset:$id')) {
        _playGeneration++;
        await _voicePlayer.stop();
      }
      final result = await _call('remove-assets', {
        'input': {'assets': ids.toList()},
      });
      _speech?.dismissPreviews(assetIds: ids);
      if (ids.any((id) => _playing == 'asset:$id')) {
        _playGeneration++;
        await _voicePlayer.pause();
      }
      _update(() {
        _hydrate(stingerMap(result['plan']));
        for (final data in [_edits, _saved, ..._undo, ..._redo]) {
          for (final bank in data.values) {
            (bank as Map).removeWhere((_, e) => ids.contains(e['asset_id']));
          }
        }
        _selectedAssets.removeAll(ids);
        if (ids.contains(_selectedAsset)) {
          _selectedAsset = _selectedAssets.firstOrNull;
        }
        for (final id in ids) {
          _assetWaves.remove(id);
          _assetWaveData.remove(id);
          _previewPaths.remove('asset:$id');
        }
        _previewPaths.clear();
        if (ids.any((id) => _playing == 'asset:$id')) _playing = null;
        _packageReady = false;
        _notice = '素材及工程内音频副本已删除，外部原文件保留。';
      });
      await _persistDraft();
    });
  }

  void _selectMaterial(
    Map<String, dynamic> asset,
    List<Map<String, dynamic>> visible,
  ) {
    final id = '${asset['id']}';
    _workspaceFocus.requestFocus();
    _update(() {
      _selectingAssets = true;
      final selected = SongSelection(ids: _selectedAssets, anchor: _assetAnchor)
          .click(
            id,
            visible.map((a) => '${a['id']}').toList(),
            range: HardwareKeyboard.instance.isShiftPressed,
          );
      _assetAnchor = selected.anchor;
      _selectedAssets
        ..clear()
        ..addAll(selected.ids);
      _selectedAsset = selected.ids.contains(id)
          ? id
          : selected.ids.firstOrNull;
    });
  }

  void _exitAssetSelection() => _update(() {
    _selectingAssets = false;
    _selectedAssets.clear();
    _selectedAsset = null;
    _assetAnchor = null;
  });

  Future<void> _moveSelectedAssets() async {
    if (_selectedAssets.isEmpty || _locked) return;
    var folder = _assetFolders.contains(_assetCategory)
        ? _assetCategory
        : '未分类';
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => TimingDialogFrame(
          title: '移动所选素材',
          icon: 'folder',
          width: 440,
          busy: false,
          description: '${_selectedAssets.length} 条素材',
          body: RmSelect<String>(
            value: folder,
            items: {
              for (final f in (_assetFolders.toList()..sort()))
                f: f.replaceAll('/', ' / '),
            },
            onChanged: (v) => update(() => folder = v),
          ),
          actions: [
            RmButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
            RmButton(
              label: '移动',
              variant: RmButtonVariant.primary,
              leading: const RmIcon('folder', size: 12),
              onPressed: () => Navigator.pop(ctx, folder),
            ),
          ],
        ),
      ),
    );
    if (target != null && mounted) {
      await _folderCommand('move', folder: target, ids: _orderedSelectedAssets);
    }
  }

  Widget _pool() {
    final rm = context.rm, query = _assetSearch.text.toLowerCase();
    final used = {
      for (final bank in _edits.values)
        for (final edit in (bank as Map).values) '${edit['asset_id']}',
    };
    final visible = _assets
        .where(
          (a) =>
              '${a['name']} ${a['category']}'.toLowerCase().contains(query) &&
              (_assetStatus == 'all' ||
                  (_assetStatus == 'used') == used.contains(a['id'])),
        )
        .toList();
    int position(Map<String, dynamic> a) =>
        _assets.indexWhere((v) => v['id'] == a['id']);
    visible.sort((a, b) {
      final value = switch (_assetSort) {
        'duration' => stingerNumber(
          a['duration'],
        ).compareTo(stingerNumber(b['duration'])),
        'added' => position(a).compareTo(position(b)),
        'name' => '${a['name']}'.toLowerCase().compareTo(
          '${b['name']}'.toLowerCase(),
        ),
        _ =>
          '${a['original_filename'] ?? p.basename('${a['source']}')}'
              .toLowerCase()
              .compareTo(
                '${b['original_filename'] ?? p.basename('${b['source']}')}'
                    .toLowerCase(),
              ),
      };
      return _assetDescending ? -value : value;
    });
    final byFolder = <String, List<Map<String, dynamic>>>{};
    for (final asset in visible) {
      byFolder.putIfAbsent('${asset['category']}', () => []).add(asset);
    }
    final folders = <String>{
      ..._assetFolders,
      ...visible.map((a) => '${a['category']}'),
    };
    for (final folder in folders.toList()) {
      final parts = folder.split('/');
      for (var i = 1; i < parts.length; i++) {
        folders.add(parts.take(i).join('/'));
      }
    }
    final ordered = folders.toList()
      ..sort((a, b) {
        final unclassifiedA = a == '未分类' || a.startsWith('未分类/');
        final unclassifiedB = b == '未分类' || b.startsWith('未分类/');
        return unclassifiedA != unclassifiedB
            ? (unclassifiedA ? 1 : -1)
            : a.compareTo(b);
      });
    _displayAssetOrder = [
      for (final folder in ordered)
        for (final asset in byFolder[folder] ?? <Map<String, dynamic>>[])
          '${asset['id']}',
    ];
    bool shown(String folder) {
      final parts = folder.split('/');
      for (var i = 1; i < parts.length; i++) {
        if (!_openAssetFolders.contains(parts.take(i).join('/'))) return false;
      }
      return query.isEmpty ||
          byFolder.keys.any((p) => p == folder || p.startsWith('$folder/'));
    }

    return ExternalAudioDropTarget(
      label: '松开以导入语音素材',
      enabled: !_locked,
      onDrop: _importPaths,
      child: _panel(
        '素材池',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlaylistSearchField(
                    key: const ValueKey('voice-asset-filter'),
                    controller: _assetSearch,
                    onChanged: (_) => _update(() {}),
                    hint: '搜索素材名称',
                  ),
                  const SizedBox(height: 7),
                  LayoutBuilder(
                    builder: (context, box) => Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: RmButton(
                              size: RmButtonSize.md,
                              label: box.maxWidth < 170 ? '导入' : '导入素材',
                              tooltip: '导入素材',
                              horizontalPadding: 6,
                              leading: const RmIcon('plus', size: 12),
                              onPressed: _locked ? null : _import,
                            ),
                          ),
                        ),
                        RmButton.icon(
                          key: const ValueKey('voice-new-folder'),
                          icon: const RmIcon('folder-plus', size: 13),
                          tooltip: '新建素材文件夹',
                          onPressed: _locked
                              ? null
                              : () => _folderCommand('create'),
                        ),
                        const SizedBox(width: 6),
                        RmButton.icon(
                          key: const ValueKey('voice-open-materials'),
                          icon: const RmIcon('folder-open', size: 13),
                          tooltip: '打开素材目录',
                          onPressed: () => _openDirectory('sources/voices'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: RmSelect<String>(
                      key: const ValueKey('voice-pool-sort'),
                      menuWidth: 180,
                      horizontalPadding: 5,
                      value: _assetSort,
                      items: const {
                        'filename': '文件名称',
                        'name': '素材名称',
                        'duration': '音频时长',
                        'added': '加入顺序',
                      },
                      onChanged: (v) => _update(() => _assetSort = v),
                    ),
                  ),
                  const SizedBox(width: 5),
                  SizedBox(
                    width: 58,
                    child: RmButton(
                      label: _assetDescending ? '倒序' : '正序',
                      horizontalPadding: 4,
                      leading: RmIcon(
                        _assetDescending ? 'chevron-down' : 'chevron-up',
                        size: 11,
                      ),
                      onPressed: () =>
                          _update(() => _assetDescending = !_assetDescending),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: RmSelect<String>(
                      key: const ValueKey('voice-pool-status'),
                      menuWidth: 160,
                      horizontalPadding: 5,
                      value: _assetStatus,
                      items: const {
                        'all': '全部状态',
                        'used': '已使用',
                        'unused': '未使用',
                      },
                      onChanged: (v) => _update(() => _assetStatus = v),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: _selectingAssets
                        ? Text(
                            '已选 ${_selectedAssets.length}',
                            style: RmText.sans(10.5, color: rm.fg3),
                          )
                        : RmTooltip(
                            message: 'Ctrl 多选 · Shift 连选 · Esc 退出',
                            child: Text(
                              'Ctrl 多选 · Shift 连选',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.sans(10, color: rm.fg3),
                            ),
                          ),
                  ),
                  const SizedBox(width: 6),
                  RmButton(
                    key: const ValueKey('voice-pool-multiselect'),
                    label: _selectingAssets ? '退出多选' : '多选',
                    size: RmButtonSize.md,
                    onPressed: _locked
                        ? null
                        : () {
                            _workspaceFocus.requestFocus();
                            if (_selectingAssets) {
                              _exitAssetSelection();
                            } else {
                              _update(() => _selectingAssets = true);
                            }
                          },
                  ),
                ],
              ),
            ),
            if (_selectingAssets)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
                child: Row(
                  children: [
                    Expanded(
                      child: RmButton(
                        key: const ValueKey('voice-material-select-all'),
                        label: '全选',
                        size: RmButtonSize.md,
                        horizontalPadding: 6,
                        onPressed: _locked
                            ? null
                            : () => _update(() {
                                _selectedAssets.addAll(
                                  visible.map((a) => '${a['id']}'),
                                );
                                _selectedAsset = _selectedAssets.firstOrNull;
                              }),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: RmButton(
                        key: const ValueKey('voice-material-clear-selection'),
                        label: '清空',
                        size: RmButtonSize.md,
                        horizontalPadding: 6,
                        onPressed: _locked
                            ? null
                            : () => _update(() {
                                _selectedAssets.clear();
                                _selectedAsset = null;
                              }),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: RmButton(
                        key: const ValueKey('voice-material-move'),
                        label: '移动',
                        tooltip: '移动到文件夹',
                        size: RmButtonSize.md,
                        horizontalPadding: 6,
                        onPressed: _locked || _selectedAssets.isEmpty
                            ? null
                            : _moveSelectedAssets,
                      ),
                    ),
                    const SizedBox(width: 6),
                    RmButton.icon(
                      key: const ValueKey('voice-material-delete-selected'),
                      icon: const RmIcon('trash', size: 12),
                      tooltip: '删除所选素材',
                      foregroundColor: context.rm.danger,
                      onPressed: _locked || _selectedAssets.isEmpty
                          ? null
                          : () => _removeMaterials({..._selectedAssets}),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, color: rm.border),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  for (final folder in ordered.where(shown)) ...[
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _VoiceGroupHeader(
                        height: 32,
                        child: _folderRow(
                          folder,
                          _assets.where((a) => a['category'] == folder).length,
                        ),
                      ),
                    ),
                    if (_openAssetFolders.contains(folder) || query.isNotEmpty)
                      SliverList.builder(
                        itemCount: byFolder[folder]?.length ?? 0,
                        itemBuilder: (context, i) =>
                            _materialCard(byFolder[folder]![i], visible),
                      ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              child: Row(
                children: [
                  RmIcon('info', size: 11, color: rm.fg4),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '拖入条目替换 · 双击素材编辑',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(10, color: rm.fg3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${_assets.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RmText.mono(10, color: rm.fg3),
              ),
            ),
            const SizedBox(width: 4),
            _paneToggle('pool'),
          ],
        ),
      ),
    );
  }

  Widget _folderRow(String folder, int count) {
    final rm = context.rm, open = _openAssetFolders.contains(folder);
    final editing = _renamingFolder == folder, hover = _hoverFolder == folder;
    Future<void> rename() async {
      final leaf = _folderName.text.trim();
      final parent = folder.contains('/')
          ? folder.substring(0, folder.lastIndexOf('/') + 1)
          : '';
      final value = '$parent$leaf';
      _update(() => _renamingFolder = null);
      if (leaf.isNotEmpty && !leaf.contains('/') && value != folder) {
        await _folderCommand('rename', folder: folder, renameTo: value);
      }
    }

    return DragTarget<_VoiceDrag>(
      onWillAcceptWithDetails: (_) => !_locked,
      onAcceptWithDetails: (d) =>
          unawaited(_folderCommand('move', folder: folder, ids: d.data.ids)),
      builder: (context, candidates, rejected) => MouseRegion(
        onEnter: (_) => _update(() => _hoverFolder = folder),
        onExit: (_) => _update(() => _hoverFolder = null),
        child: Material(
          color: candidates.isEmpty ? rm.panel : rm.accent.bg,
          child: InkWell(
            onTap: editing
                ? null
                : () => _update(() {
                    _assetCategory = folder;
                    if (!_openAssetFolders.add(folder)) {
                      _openAssetFolders.remove(folder);
                    }
                  }),
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: rm.border)),
              ),
              padding: EdgeInsets.only(
                left: 4 + math.min(4, folder.split('/').length - 1) * 10,
                right: 4,
              ),
              child: Row(
                children: [
                  RmIcon(
                    open ? 'chevron-down' : 'chevron-right',
                    size: 12,
                    color: rm.fg3,
                  ),
                  const SizedBox(width: 2),
                  RmIcon(
                    open ? 'folder-open' : 'folder',
                    size: 13,
                    color: rm.accent.base,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: editing
                        ? CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.escape,
                              ): () =>
                                  _update(() => _renamingFolder = null),
                            },
                            child: TapRegion(
                              groupId: #voiceFolderRename,
                              onTapOutside: (_) =>
                                  _update(() => _renamingFolder = null),
                              child: SizedBox(
                                height: 24,
                                child: TextField(
                                  key: ValueKey('voice-rename-folder-$folder'),
                                  groupId: #voiceFolderRename,
                                  controller: _folderName,
                                  autofocus: true,
                                  style: RmText.sans(11.5, color: rm.fg),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    filled: true,
                                    fillColor: rm.raised,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 3,
                                    ),
                                    enabledBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: rm.accent.ring,
                                      ),
                                    ),
                                    focusedBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: rm.accent.base,
                                      ),
                                    ),
                                  ),
                                  onTapOutside: (_) =>
                                      _update(() => _renamingFolder = null),
                                  onSubmitted: (_) => rename(),
                                ),
                              ),
                            ),
                          )
                        : Text(
                            folder.split('/').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(
                              11.5,
                              color: rm.fg2,
                              weight: FontWeight.w500,
                            ),
                          ),
                  ),
                  if (editing)
                    TextFieldTapRegion(
                      groupId: #voiceFolderRename,
                      child: _toolIcon('check', '完成重命名', rename),
                    )
                  else if (hover && folder != '未分类') ...[
                    _toolIcon(
                      'folder-plus',
                      '新建子文件夹',
                      _locked
                          ? null
                          : () => _folderCommand('create', folder: folder),
                    ),
                    _toolIcon(
                      'pencil',
                      '重命名文件夹',
                      _locked
                          ? null
                          : () => _update(() {
                              _renamingFolder = folder;
                              _folderName.text = folder.split('/').last;
                              _folderName.selection = TextSelection(
                                baseOffset: 0,
                                extentOffset: _folderName.text.length,
                              );
                            }),
                    ),
                    _toolIcon(
                      'trash',
                      '删除文件夹',
                      _locked
                          ? null
                          : () => _folderCommand('delete', folder: folder),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 4),
                      child: Text(
                        '$count',
                        style: RmText.mono(10, color: rm.fg3),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _materialCard(
    Map<String, dynamic> asset,
    List<Map<String, dynamic>> visible, {
    bool dragging = false,
  }) {
    final id = '${asset['id']}',
        selected = _selectedAssets.contains('${asset['id']}');
    final duration = stingerEditedDuration(
      asset,
      stingerNumber(asset['duration']),
    );
    final card = Padding(
      key: ValueKey('voice-material-$id'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: TrackCard(
        title: '${asset['name']}',
        order: _assets.indexWhere((a) => a['id'] == id) + 1,
        numberOnly: true,
        artist: stingerTime(duration),
        durationSec: duration,
        showDuration: false,
        locked: false,
        custom: true,
        neutral: _edits.values.any(
          (bank) => stingerMap(
            bank,
          ).values.any((e) => stingerMap(e)['asset_id'] == id),
        ),
        dragging: dragging,
        selectionMode: _selectingAssets && !dragging,
        selected: _selectingAssets && selected,
        tooltip: '双击编辑 · Ctrl 多选 · Shift 连选',
        onActivate: dragging || _locked
            ? null
            : () => _update(() => _selectedAsset = id),
        onSelect: dragging || _locked
            ? null
            : (_, _) => _selectMaterial(asset, visible),
        onOpenEditor: dragging || _locked ? null : () => _assetInfo(asset),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _previewButton(
              'asset:$id',
              dragging || _locked ? null : () => _play('asset', asset: id),
            ),
            _toolIcon(
              'trash',
              '移除素材',
              dragging || _locked ? null : () => _removeMaterial(asset),
              danger: true,
              key: ValueKey('voice-delete-material-$id'),
            ),
          ],
        ),
      ),
    );
    if (dragging) return card;
    return PlaylistDraggable<_VoiceDrag>(
      data: _VoiceDrag(
        selected && _selectedAssets.length > 1 ? _orderedSelectedAssets : [id],
      ),
      maxSimultaneousDrags: _locked ? 0 : 1,
      feedback: PlaylistDragPreview(
        itemNoun: '条素材',
        cards: [
          for (final item
              in (selected && _selectedAssets.length > 1
                  ? [
                      for (final id in _orderedSelectedAssets)
                        _assets.firstWhere((a) => a['id'] == id),
                    ]
                  : [asset]))
            _materialCard(item, visible, dragging: true),
        ],
      ),
      childWhenDragging: Opacity(opacity: .35, child: card),
      child: card,
    );
  }
}
