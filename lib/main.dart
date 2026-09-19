import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/home/home_page.dart';
import 'ui/theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: PiedeMoveApp()));
}

class PiedeMoveApp extends StatelessWidget {
  const PiedeMoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PiedeMove',
      debugShowCheckedModeBanner: false,
      // Italian by default; the English switch lands with settings (§11.7).
      locale: const Locale('it'),
      supportedLocales: const [Locale('it'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: lightTheme(),
      darkTheme: darkTheme(),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
