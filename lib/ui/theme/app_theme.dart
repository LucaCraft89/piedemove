/// The two themes. Dark is tuned first; light mirrors it.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

// ponytail: system font for now. Google Sans Flex is bundled at GATE 1, once
// its licence and axes are verified with fonttools.
ThemeData _base(Brightness brightness, Color seed, PmTokens tokens) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [tokens],
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
  );
}

ThemeData darkTheme() =>
    _base(Brightness.dark, const Color(0xFF4ADE80), PmTokens.darkTokens);

ThemeData lightTheme() =>
    _base(Brightness.light, const Color(0xFF15803D), PmTokens.lightTokens);
