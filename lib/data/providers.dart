/// Riverpod wiring for the on-device data: the index and what hangs off it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'clustering.dart';
import 'index_source.dart';
import 'transit_index.dart';

/// Coarse progress for the first-run screen; nothing else reads it.
final indexStageProvider = StateProvider<IndexStage>((_) => IndexStage.cached);

final transitIndexProvider = FutureProvider<TransitIndex>((ref) async {
  final dir = await getApplicationSupportDirectory();
  return IndexStore(dir).load(
    onStage: (s) => ref.read(indexStageProvider.notifier).state = s,
  );
});

/// Display-only clusters; routing never uses them.
final stopClustersProvider = Provider<StopClusters?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  return ix == null ? null : StopClusters.build(ix);
});

/// Route types served by each stop, for the map dot colour.
final stopModesProvider = Provider<List<Set<int>>>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return const [];
  return [
    for (var s = 0; s < ix.stopCount; s++)
      {
        for (var i = ix.stopPatternOffset[s]; i < ix.stopPatternOffset[s + 1]; i++)
          ix.routeTypeOfPattern(ix.stopPattern[i]),
      },
  ];
});
