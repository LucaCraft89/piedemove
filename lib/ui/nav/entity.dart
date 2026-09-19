/// One entity reference, one `openEntity`, one sheet (§11.5).
///
/// Every tap site — map, search, trip steps, other sheets, the home list —
/// calls [openEntity]. No widget builds its own navigation. The stack lives in
/// [entityNavProvider]; back steps out one level and closes at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Opens [entity], reusing the sheet when one is already up.
void openEntity(BuildContext context, WidgetRef ref, EntityRef entity) {
  final alreadyOpen = ref.read(entityNavProvider).isNotEmpty;
  ref.read(entityNavProvider.notifier).push(entity);
  if (alreadyOpen) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _EntitySheet(),
  ).whenComplete(ref.read(entityNavProvider.notifier).clear);
}

class _EntitySheet extends ConsumerWidget {
  const _EntitySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stack = ref.watch(entityNavProvider);
    final entity = stack.lastOrNull;
    if (entity == null) return const SizedBox.shrink();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!ref.read(entityNavProvider.notifier).pop()) {
          Navigator.of(context).pop();
        }
      },
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.15,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.15, 0.5, 0.92],
        expand: false,
        builder: (context, controller) => Material(
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
