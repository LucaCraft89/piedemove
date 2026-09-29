/// The end of a live trip (§12): "Sei arrivato" with the trip at a glance -
/// arrival against the plan, time, walking and the lines ridden - instead of
/// the strip just vanishing. "Fine" closes it; "Ritorno" plans the way back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/location/trip_summary.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/live_strip.dart' show StatTile;
import 'package:piedemove/ui/trip/trip_format.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

class ArrivalSheet extends ConsumerWidget {
  const ArrivalSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(tripSummaryProvider);
    if (s == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    void close() => ref.read(tripSummaryProvider.notifier).state = null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          elevation: 8,
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Gap.screen),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.flag, color: context.tokens.live, size: 32),
                      const SizedBox(width: Gap.element),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Sei arrivato',
                                style: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            if (s.destination != null)
                              Text(s.destination!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.element),
                  Text(
                    'Alle ${hhmm(s.arrivedAt)} · ${punctualityLabel(s.minutesLate)}'
                    ' (previsto ${hhmm(s.plannedArrival)})',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.element),
                  Row(
                    children: [
                      StatTile(
                        icon: Icons.timer_outlined,
                        value: durationLabel(s.duration.inSeconds),
                        label: 'in viaggio',
                      ),
                      const SizedBox(width: 8),
                      StatTile(
                        icon: Icons.directions_walk,
                        value: metresLabel(s.walkMetres, approximate: true),
                        label: 'a piedi',
                      ),
                      const SizedBox(width: 8),
                      StatTile(
                        icon: Icons.swap_horiz,
                        value: transfersLabel(s.transfers),
                        label: s.rides.length == 1
                            ? '1 mezzo'
                            : '${s.rides.length} mezzi',
                      ),
                    ],
                  ),
                  if (s.rides.isNotEmpty) ...[
                    const SizedBox(height: Gap.element),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final (i, r) in s.rides.indexed) ...[
                          if (i > 0)
                            Icon(Icons.chevron_right,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant),
                          LineGroupBadge(lines: r),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: Gap.screen),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.u_turn_left),
                          label: const Text('Ritorno'),
                          onPressed: () {
                            close();
                            ref.read(tripPlanProvider.notifier)
                              ..swap()
                              ..setWhen(WhenMode.now)
                              ..plan();
                          },
                        ),
                      ),
                      const SizedBox(width: Gap.element),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            close();
                            ref.read(tripPlanProvider.notifier).clear();
                          },
                          child: const Text('Fine'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
