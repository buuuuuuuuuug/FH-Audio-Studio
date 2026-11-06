import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/song_browse.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';

void main() {
  PoolTrack song(String id, {bool ready = false, bool roam = false}) =>
      PoolTrack(
        id: id,
        title: id,
        artist: '$id artist',
        source: 'D:/sources/$id.wav',
        durationSec: 60,
        bpm: 120,
        key: '',
        configured: ready,
        freeRoamOnly: roam,
        confirmed: ready ? 4 : 0,
        added: '',
        modifiedAt: DateTime(2026, 10, id.codeUnitAt(0) - 64),
      );
  final input = [
    song('A', ready: true),
    song('D'),
    song('C', roam: true),
    song('B'),
  ];
  for (final sort in SongSort.values) {
    for (final descending in [false, true]) {
      test(
        'unfinished first for $sort descending=$descending, retaining within-group order',
        () {
          final options = SongBrowse(sort: sort, descending: descending);
          final selected = browseSongs(input, options);
          final result = browseSongs(input, options, incompleteFirst: true);
          expect(result.take(2).every((s) => !s.readyForBuild), isTrue);
          expect(result.skip(2).every((s) => s.readyForBuild), isTrue);
          expect(result.take(2), selected.where((s) => !s.readyForBuild));
          expect(result.skip(2), selected.where((s) => s.readyForBuild));
          expect(input.map((s) => s.id), ['A', 'D', 'C', 'B']);
        },
      );
    }
  }
}
