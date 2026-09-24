/// One entity reference, one `openEntity`, one sheet (§11.5).
///
/// Every tap site — map, search, trip steps, other sheets, the home list —
/// calls [openEntity]. No widget builds its own navigation. The stack lives in
/// [entityNavProvider]; back steps out one level and closes at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/map/map_style.dart';
import 'package:piedemove/ui/sheets/alert_sheet.dart';
import 'package:piedemove/ui/sheets/line_sheet.dart';
import 'package:piedemove/ui/sheets/stop_sheet.dart';
import 'package:piedemove/ui/sheets/vehicle_sheet.dart';

@immutable
sealed class EntityRef {
  const EntityRef();
}

class StopRef extends EntityRef {
  const StopRef(this.stop);
  final int stop;
}

class LineRef extends EntityRef {
  const LineRef(this.route, {this.direction = 0});
  final int route;
  final int direction;
}

class VehicleRef extends EntityRef {
  const VehicleRef(this.vehicleId);
  final String vehicleId;
}

class AlertRef extends EntityRef {
  const AlertRef(this.alertId);
  final String alertId;
}

class EntityNav extends StateNotifier<List<EntityRef>> {
  EntityNav() : super(const []);

  void push(EntityRef entity) => state = [...state, entity];

  /// Pops one level; false once the stack is empty and the sheet must close.
  bool pop() {
    if (state.length <= 1) {
      state = const [];
      return false;
    }
    state = state.sublist(0, state.length - 1);
    return true;
  }

  void clear() => state = const [];
}

final entityNavProvider =
    StateNotifierProvider<EntityNav, List<EntityRef>>((_) => EntityNav());

/// Opens [entity]. The sheet itself is [EntitySheet], drawn by the home page
/// over the map (not a modal), so the map stays usable at peek.
void openEntity(BuildContext context, WidgetRef ref, EntityRef entity) {
  // Called from a search page or a picker: come back to the map first.
  final nav = Navigator.of(context);
  if (nav.canPop()) nav.popUntil((r) => r.isFirst);
  ref.read(entityNavProvider.notifier).push(entity);
}

/// Peek / half / expanded, resting at peek for a focus entity (a line or
/// vehicle) and at half for a stop or alert. It takes only its own height.
class EntitySheet extends ConsumerStatefulWidget {
  const EntitySheet({super.key});

  @override
  ConsumerState<EntitySheet> createState() => _EntitySheetState();
}

class _EntitySheetState extends ConsumerState<EntitySheet> {
  late final double _initial = switch (ref.read(entityNavProvider).lastOrNull) {
    LineRef() || VehicleRef() => sheetPeek,
    _ => sheetHalf,
  };

  @override
  Widget build(BuildContext context) {
    final stack = ref.watch(entityNavProvider);
    final entity = stack.lastOrNull;
    if (entity == null) return const SizedBox.shrink();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!ref.read(entityNavProvider.notifier).pop()) {
          ref.read(focusProvider.notifier).close();
        }
      },
      child: DraggableScrollableSheet(
        initialChildSize: _initial,
        minChildSize: sheetPeek,
        maxChildSize: sheetFull,
        snap: true,
        snapSizes: sheetSnaps,
        builder: (context, controller) => Material(
          elevation: 8,
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          // Every sheet body ends above the system navigation bar.
          child: SafeArea(
            top: false,
            child: switch (entity) {
            StopRef(:final stop) =>
              StopBody(stop: stop, controller: controller),
            LineRef(:final route, :final direction) => LineBody(
                route: route,
                direction: direction,
                controller: controller,
              ),
            VehicleRef(:final vehicleId) =>
              VehicleBody(vehicleId: vehicleId, controller: controller),
            AlertRef(:final alertId) =>
              AlertBody(alertId: alertId, controller: controller),
            },
          ),
        ),
      ),
    );
  }
}
