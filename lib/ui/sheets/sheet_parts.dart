/// Pieces every entity sheet shares: grabber, header with back, alert tiles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';

class SheetHeader extends ConsumerWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final deep = ref.watch(entityNavProvider).length > 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (deep)
          IconButton(
            tooltip: 'Indietro',
            onPressed: () => ref.read(entityNavProvider.notifier).pop(),
            icon: const Icon(Icons.arrow_back),
          ),
        if (leading != null) ...[leading!, const SizedBox(width: Gap.element)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              if (subtitle != null)
                Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class Grabber extends StatelessWidget {
  const Grabber({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(bottom: Gap.element),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// Compact alert rows; tapping opens the alert sheet.
class AlertTiles extends ConsumerWidget {
  const AlertTiles({super.key, required this.alerts});

  final List<RtAlert> alerts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (alerts.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final a in alerts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: Gap.row,
            leading: Icon(Icons.warning_amber, color: scheme.error),
            title: Text(
              a.header.isEmpty ? 'Avviso di servizio' : a.header,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => openEntity(context, ref, AlertRef(a.id)),
          ),
      ],
    );
  }
}

/// A section label, so the sheets read the same way everywhere.
class SheetSection extends StatelessWidget {
  const SheetSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.element, bottom: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}
