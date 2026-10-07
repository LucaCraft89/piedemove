/// First run (once): what makes PiedeMove different, why it asks for
/// location and notifications, and Casa/Lavoro. Skippable at any page; the
/// location permission is asked here, not in the rider's face at launch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/location/trip_notification.dart';
import 'package:piedemove/places/shortcuts.dart';
import 'package:piedemove/ui/search/search_page.dart';
import 'package:piedemove/ui/theme/tokens.dart';

const _seenKey = 'pm.introSeen';

/// True once the intro was finished or skipped; true too if storage fails
/// (never trap the rider in it).
Future<bool> introSeen() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_seenKey) ?? false;
  } catch (_) {
    return true;
  }
}

Future<void> _markSeen() async {
  try {
    await (await SharedPreferences.getInstance()).setBool(_seenKey, true);
  } catch (_) {}
}

Future<void> openIntro(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(
          fullscreenDialog: true, builder: (_) => const IntroPage()),
    );

class IntroPage extends ConsumerStatefulWidget {
  const IntroPage({super.key});

  @override
  ConsumerState<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends ConsumerState<IntroPage> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    await _markSeen();
    if (mounted) Navigator.of(context).pop();
  }

  void _next() => _page == 2
      ? _done()
      : _pages.nextPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: _done, child: const Text('Salta')),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (p) => setState(() => _page = p),
                  children: [
                    const _IntroStep(
                      icon: Icons.directions_walk,
                      title: 'Viaggi gratis: cammina meno',
                      body: 'Con l\'abbonamento libera circolazione il prezzo '
                          'è la strada a piedi. PiedeMove mostra tutte le linee '
                          'che fanno ogni tratta, aggiunge i cambi a due passi '
                          'tra fermate vicine e preferisce un\'attesa in più a '
                          'un chilometro a piedi.',
                    ),
                    _IntroStep(
                      icon: Icons.my_location,
                      title: 'Posizione e notifiche',
                      body: 'La posizione serve per partire da dove sei e per '
                          'il viaggio live: ti dice quando scendere, anche a '
                          'schermo spento, con una notifica e una vibrazione. '
                          'Tutto resta sul telefono.',
                      actions: [
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.my_location),
                          label: const Text('Consenti la posizione'),
                          onPressed: () =>
                              ref.read(locationProvider.notifier).activate(),
                        ),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.notifications_outlined),
                          label: const Text('Consenti le notifiche'),
                          onPressed: requestNotificationPermission,
                        ),
                      ],
                    ),
                    _IntroStep(
                      icon: Icons.home_outlined,
                      title: 'Casa e Lavoro',
                      body: 'Un tocco dalla schermata principale per andarci '
                          'da dove sei. Puoi cambiarli quando vuoi tenendo '
                          'premuto il pulsante.',
                      actions: [
                        for (final s in Shortcut.values)
                          _ShortcutButton(shortcut: s),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(Gap.screen),
                child: Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _page
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                        ),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _next,
                      child: Text(_page == 2 ? 'Inizia' : 'Avanti'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroStep extends StatelessWidget {
  const _IntroStep({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Gap.screen * 1.5),
      children: [
        const SizedBox(height: 32),
        Icon(icon, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: Gap.screen),
        Text(title,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.element),
        Text(body, style: theme.textTheme.bodyLarge),
        const SizedBox(height: Gap.screen),
        for (final a in actions)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: a),
      ],
    );
  }
}

/// "Imposta Casa" / "Casa: Via Roma 1" - picks a place in search.
class _ShortcutButton extends ConsumerWidget {
  const _ShortcutButton({required this.shortcut});

  final Shortcut shortcut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = ref.watch(shortcutPlacesProvider)[shortcut];
    final label = shortcutLabel(shortcut);
    return OutlinedButton.icon(
      icon: Icon(shortcut == Shortcut.home
          ? Icons.home_outlined
          : Icons.work_outline),
      label: Text(place == null ? 'Imposta $label' : '$label: ${place.name}',
          overflow: TextOverflow.ellipsis),
      onPressed: () async {
        final picked = await openSearch(context, pick: true);
        if (picked != null) {
          ref.read(shortcutPlacesProvider.notifier).set(shortcut, picked);
        }
      },
    );
  }
}
