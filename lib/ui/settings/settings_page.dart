/// Settings (§11.7) and the Filtri sheet: the same planning controls in both.
///
/// Language needs l10n first, so the app stays Italian here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/app/app_update.dart';

import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/settings/settings.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';
import 'package:piedemove/ui/settings/about_page.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

Future<void> openSettings(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );

/// The Filtri pill: the planning limits alone, without leaving the map.
Future<void> showFilters(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(Gap.screen, 0, Gap.screen, Gap.screen),
          child: SingleChildScrollView(child: PlanningControls(replan: true)),
        ),
      ),
    );

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      // The last row must clear the system navigation bar.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Gap.screen),
          children: [
          const PlanningControls(),
          const _Header('Viaggio live'),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Avvisami prima di scendere'),
            subtitle: Text('Una vibrazione quando mancano queste fermate.'),
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('1 fermata prima')),
              ButtonSegment(value: 2, label: Text('2 fermate prima')),
            ],
            selected: {settings.alightWarnStops},
            onSelectionChanged: (v) =>
                controller.edit((s) => s.copyWith(alightWarnStops: v.first)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.alightSound,
            title: const Text('Suono con "scendi ora"'),
            subtitle: const Text(
                'Oltre alla vibrazione, il suono di notifica del telefono.'),
            onChanged: (on) =>
                controller.edit((s) => s.copyWith(alightSound: on)),
          ),
          const _Header('Aspetto'),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system, label: Text('Telefono')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Scuro')),
              ButtonSegment(value: ThemeMode.light, label: Text('Chiaro')),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (m) =>
                controller.edit((s) => s.copyWith(themeMode: m.first)),
          ),
          const _Header('Stile mappa'),
          SegmentedButton<MapStyleKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: MapStyleKind.auto, label: Text('Auto')),
              ButtonSegment(value: MapStyleKind.light, label: Text('Chiaro')),
              ButtonSegment(value: MapStyleKind.dark, label: Text('Scuro')),
              ButtonSegment(value: MapStyleKind.colour, label: Text('Colori')),
              ButtonSegment(
                  value: MapStyleKind.highContrast, label: Text('Contrasto')),
            ],
            selected: {settings.mapStyle},
            onSelectionChanged: (m) =>
                controller.edit((s) => s.copyWith(mapStyle: m.first)),
          ),
          const _Header('Lingua'),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Italiano'),
            subtitle: Text('L\'inglese arriva con le traduzioni.'),
            enabled: false,
          ),
          const _Header('Stato dei dati'),
          const _DataStatus(),
          const _Header('Avanzate'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.advanced,
            title: const Text('Modalità dati grezzi'),
            subtitle: const Text(
                'Mostra il record originale in fermate, linee, veicoli e '
                'avvisi, e le sorgenti qui sotto.'),
            onChanged: (on) =>
                controller.edit((s) => s.copyWith(advanced: on)),
          ),
          if (settings.advanced) const _FeedSources(),
          const _Header('Informazioni'),
          const _VersionRow(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('Dati, licenze e privacy'),
            onTap: () => openAbout(context),
          ),
          ],
        ),
      ),
    );
  }
}

/// Max extra time, walk cap, walk speed, transfer time and modes — one widget,
/// used by both Settings and the Filtri sheet.
class PlanningControls extends ConsumerWidget {
  const PlanningControls({super.key, this.replan = false});

  /// True in the Filtri sheet: changing a limit re-runs the current search.
  final bool replan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);

    void replanNow() {
      if (replan) ref.read(tripPlanProvider.notifier).replanSoon();
    }

    // Taps replan at once; sliders only update while dragging and replan when
    // released (a drag is dozens of onChanged calls).
    void changed(PmSettings Function(PmSettings) change) {
      controller.edit(change);
      replanNow();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Limiti del percorso'),
        _SliderRow(
          label: 'Minuti in più accettati',
          value: '+${settings.maxExtraMinutes} min',
          slider: Slider(
            value: settings.maxExtraMinutes.toDouble(),
            min: 5,
            max: 60,
            divisions: 11,
            onChangeEnd: (_) => replanNow(),
            onChanged: (v) =>
                controller.edit((s) => s.copyWith(maxExtraMinutes: v.round())),
          ),
        ),
        _SliderRow(
          label: 'Cammino massimo',
          value: '${settings.walkCapMetres.round()} m',
          slider: Slider(
            value: settings.walkCapMetres,
            min: 200,
            max: 2000,
            divisions: 18,
            onChangeEnd: (_) => replanNow(),
            onChanged: (v) => controller.edit(
                (s) => s.copyWith(walkCapMetres: (v / 100).round() * 100),),
          ),
        ),
        _SliderRow(
          label: 'Tempo minimo di cambio',
          value: '${settings.minTransferSeconds ~/ 60} min',
          slider: Slider(
            value: settings.minTransferSeconds.toDouble(),
            min: 0,
            max: 300,
            divisions: 5,
            onChangeEnd: (_) => replanNow(),
            onChanged: (v) => controller.edit(
                (s) => s.copyWith(minTransferSeconds: v.round()),),
          ),
        ),
        const _Header('Velocità a piedi'),
        Wrap(
          spacing: 8,
          children: [
            for (final (speed, label) in const [
              (walkSpeedSlow, 'Lenta'),
              (walkSpeedNormal, 'Normale'),
              (walkSpeedFast, 'Veloce'),
            ])
              ChoiceChip(
                label: Text('$label (${speed.toStringAsFixed(1)} m/s)'),
                selected: (settings.walkSpeed - speed).abs() < 0.01,
                onSelected: (_) => changed((s) => s.copyWith(walkSpeed: speed)),
              ),
            ChoiceChip(
              label: const Text('Personalizzata'),
              selected: isCustomWalkSpeed(settings.walkSpeed),
              // Starts between normal and fast, then the slider takes over.
              onSelected: (_) => changed((s) => s.copyWith(walkSpeed: 1.4)),
            ),
          ],
        ),
        if (isCustomWalkSpeed(settings.walkSpeed))
          _SliderRow(
            label: 'Velocità scelta',
            value: '${settings.walkSpeed.toStringAsFixed(1)} m/s',
            slider: Slider(
              value: settings.walkSpeed.clamp(walkSpeedMin, walkSpeedMax),
              min: walkSpeedMin,
              max: walkSpeedMax,
              divisions: 17,
              onChangeEnd: (_) => replanNow(),
            onChanged: (v) => controller.edit(
                (s) => s.copyWith(walkSpeed: (v * 10).round() / 10),
              ),
            ),
          ),
        const _Header('Mezzi'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (type, label) in const [
              (RouteType.bus, 'Bus'),
              (RouteType.tram, 'Tram'),
              (RouteType.metro, 'Metro'),
              (RouteType.funicular, 'Funicolare'),
            ])
              FilterChip(
                avatar: Icon(modeIcon(type), size: 16),
                label: Text(label),
                selected: settings.modes.contains(type),
                onSelected: (on) {
                  controller.toggleMode(type, on);
                  if (replan && ref.read(tripPlanProvider).result != null) {
                    ref.read(tripPlanProvider.notifier).plan();
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.slider,
  });

  final String label;
  final String value;
  final Widget slider;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          slider,
        ],
      );
}

/// Per-feed last fetch, status, bytes, plus a refresh button (§11.7).
class _DataStatus extends ConsumerWidget {
  const _DataStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rt = ref.watch(realtimeProvider);
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule),
          title: const Text('Orari GTT'),
          subtitle: Text(ix == null
              ? 'non caricati'
              : 'versione ${ix.feedVersion} · ${ix.stopCount} fermate'),
        ),
        for (final kind in RtFeedKind.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_feedIcon(kind)),
            title: Text(_feedLabel(kind)),
            subtitle: Text(_healthLine(rt.health[kind], now)),
            trailing: IconButton(
              tooltip: 'Aggiorna',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.read(realtimeProvider.notifier).pollOnce(kind),
            ),
          ),
      ],
    );
  }
}

/// The feed screen behind raw-data mode (§11.7): every source URL, verbatim.
class _FeedSources extends StatelessWidget {
  const _FeedSources();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in Feeds.all.entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(entry.key),
              subtitle: SelectableText(
                entry.value,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
        ],
      );
}

String _feedLabel(RtFeedKind kind) => switch (kind) {
      RtFeedKind.vehicles => 'Posizioni dei veicoli',
      RtFeedKind.tripUpdates => 'Ritardi delle corse',
      RtFeedKind.alerts => 'Avvisi di servizio',
    };

IconData _feedIcon(RtFeedKind kind) => switch (kind) {
      RtFeedKind.vehicles => Icons.directions_bus,
      RtFeedKind.tripUpdates => Icons.timer,
      RtFeedKind.alerts => Icons.warning_amber,
    };

String _healthLine(FeedHealth? health, DateTime now) {
  if (health == null) return 'mai aggiornato';
  final parts = <String>[];
  if (health.lastSuccess != null) {
    final ago = now.difference(health.lastSuccess!);
    parts.add(ago.inMinutes < 1
        ? 'aggiornato ora'
        : 'aggiornato ${ago.inMinutes} min fa');
  } else {
    parts.add('mai aggiornato');
  }
  if (health.status != null) parts.add('HTTP ${health.status}');
  if (health.bytes != null) parts.add('${health.bytes} byte');
  if (health.lastError != null) parts.add(health.lastError!);
  return parts.join(' · ');
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.screen, bottom: 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

/// This build's version, and a manual "is there a newer beta?" check.
class _VersionRow extends ConsumerStatefulWidget {
  const _VersionRow();

  @override
  ConsumerState<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends ConsumerState<_VersionRow> {
  String? _installed;
  String? _status;
  AppRelease? _found;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    installedVersion().then((v) {
      if (mounted) setState(() => _installed = v);
    });
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final r = await checkForUpdate(force: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _found = r;
      _status = r == null ? 'Hai già l\'ultima versione.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.system_update_outlined),
      title: Text('Versione ${_installed ?? '…'}'),
      subtitle: Text(found != null
          ? 'Disponibile ${found.version}: tocca per scaricarla'
          : _status ?? 'Tocca per cercare aggiornamenti'),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onTap: _busy
          ? null
          : () => found != null ? openUrl(found.apkUrl) : _check(),
    );
  }
}

