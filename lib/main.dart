import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings/settings.dart';
import 'ui/home/home_page.dart';
import 'ui/theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: PiedeMoveApp()));
}

class PiedeMoveApp extends ConsumerWidget {
  const PiedeMoveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'PiedeMove',
      debugShowCheckedModeBanner: false,
      // Italian only for now: the English switch needs l10n (§11.7).
      locale: const Locale('it'),
      supportedLocales: const [Locale('it'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: lightTheme(),
      darkTheme: darkTheme(),
      themeMode: ref.watch(settingsProvider).themeMode,
      home: const HomePage(),
    );
  }
}
