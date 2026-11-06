part of '../voice_replacement.dart';

extension _VoiceExport on _VoiceReplacementState {
  Future<void> _exportText() async {
    if (!_readyFile || _pending == null || _exportEntries.isEmpty) return;
    final source = _pending!['path'], bank = _bank['id'];
    final indices = _exportEntries.toList()..sort();
    Future<Map<String, dynamic>> render(
      List<String> fields,
      bool matched, [
      String? format,
    ]) => _call('export-text', {
      'input': {
        'sources': [source],
        'bank_id': bank,
        'indices': indices,
        'fields': fields,
        'matched_only': matched,
        'format': ?format,
      },
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => VoiceTextExportDialog(
        name: '${_bank['name']}',
        count: indices.length,
        load: () =>
            render(['name', 'content', 'translation', 'duration'], false),
        xlsx: (fields, matched) async => base64Decode(
          '${(await render(fields, matched, 'xlsx'))['xlsx_base64']}',
        ),
        tablePreview: _csvPreview,
        notify: _toast,
        onExported: () {
          if (mounted) _update(() => _selectingExport = false);
        },
      ),
    );
  }

  Widget _csvPreview(
    BuildContext ctx,
    List<String> headers,
    List<List<String>> rows,
  ) {
    if (headers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('请重新生成预览。', style: RmText.sans(12, color: ctx.rm.fg3)),
      );
    }
    final widths = <int, TableColumnWidth>{
      for (var i = 0; i < headers.length; i++)
        i: FixedColumnWidth(
          headers[i] == '序号'
              ? 60
              : headers[i].contains('时长')
              ? 90
              : 230,
        ),
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: widths.values.fold<double>(
          0,
          (v, w) => v + (w as FixedColumnWidth).value,
        ),
        child: SingleChildScrollView(
          child: Table(
            columnWidths: widths,
            border: TableBorder(
              horizontalInside: BorderSide(color: ctx.rm.border),
              verticalInside: BorderSide(color: ctx.rm.border),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(color: ctx.rm.hover),
                children: [
                  for (final label in headers)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      child: Text(
                        label,
                        style: RmText.sans(
                          11.5,
                          color: ctx.rm.fg,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              for (final row in rows.take(20))
                TableRow(
                  children: [
                    for (var i = 0; i < headers.length; i++)
                      RmTooltip(
                        message: i < row.length ? row[i] : '',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            i < row.length ? row[i] : '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(
                              11.5,
                              color: ctx.rm.fg2,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
