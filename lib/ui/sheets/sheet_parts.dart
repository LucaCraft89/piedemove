/// Pieces every entity sheet shares: grabber, header with back, alert tiles.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/settings/settings.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';

class SheetHeader extends ConsumerWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Default: close the entity sheet and drop the focus.
  final VoidCallback? onClose;

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
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
              if (subtitle != null)
                Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        ?trailing,
        IconButton(
          tooltip: 'Chiudi',
          onPressed: onClose ?? ref.read(focusProvider.notifier).close,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

/// The star every stop and line sheet carries (§11.3).
class FavouriteButton extends ConsumerWidget {
  const FavouriteButton(this.favouriteKey, {super.key});

  final String favouriteKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(favouritesProvider).contains(favouriteKey);
    return IconButton(
      tooltip: on ? 'Togli dai preferiti' : 'Aggiungi ai preferiti',
      onPressed: () =>
          ref.read(favouritesProvider.notifier).toggle(favouriteKey),
      icon: Icon(on ? Icons.star : Icons.star_border),
      color: on ? Theme.of(context).colorScheme.primary : null,
    );
  }
}

/// Raw-data expander (§11.7): present only with advanced mode on. Long-press
/// copies the record.
class RawData extends ConsumerWidget {
  const RawData(this.text, {super.key, this.label = 'Dati grezzi'});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(settingsProvider).advanced) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.labelLarge),
      children: [
        GestureDetector(
          onLongPress: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copiato')),
            );
          },
          child: SizedBox(
            width: double.infinity,
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
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
