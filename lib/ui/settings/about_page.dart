/// About (§11.8): what the app is, whose data it uses, under which licence.
library;

import 'package:flutter/material.dart';

import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/ui/theme/tokens.dart';

Future<void> openAbout(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Informazioni')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Gap.screen),
          children: [
            Text('PiedeMove', style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Percorsi in trasporto pubblico a Torino per chi viaggia con un '
              'titolo gratuito: i metri a piedi sono il costo, non il prezzo del '
              'biglietto. Tutto il calcolo avviene sul telefono.',
              style: text.bodyMedium,
            ),
            const _Section('Dati'),
            const _Source(
              title: 'GTT — orari e tempo reale',
              subtitle: 'Open data GTT, licenza CC-BY.\n${Feeds.gttStaticGtfs}',
            ),
            const _Source(
              title: 'OpenStreetMap',
              subtitle:
                  'Strade, binari e ingressi della metro.\n'
                  '© contributori OpenStreetMap, licenza ODbL.',
            ),
            const _Source(
              title: 'OpenFreeMap e OpenMapTiles',
              subtitle: 'Mappa di sfondo e stili.',
            ),
            const _Source(
              title: 'Photon (Komoot)',
              subtitle: 'Ricerca di indirizzi e luoghi, su dati OpenStreetMap.',
            ),
            const _Source(
              title: 'Regione Piemonte',
              subtitle:
                  'Bus extraurbani, solo orari programmati (CC-BY 4.0). '
                  'In arrivo.',
            ),
            const _Section('Niente Google'),
            Text(
              'Nessun dato e nessuna API di Google: né mappe, né percorsi, né '
              'ricerca. Nessun account, nessuna pubblicità, nessun tracciamento; '
              'preferiti, luoghi salvati e impostazioni restano sul telefono.',
              style: text.bodyMedium,
            ),
            const _Section('Licenza'),
            Text(
              'PiedeMove è software libero. Codice sorgente e licenza: '
              'github.com/piedemove.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: Gap.screen),
            Text('Versione 1.0.0', style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Gap.screen, bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _Source extends StatelessWidget {
  const _Source({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
  );
}
