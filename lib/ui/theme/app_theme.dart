/// The two themes. Dark is tuned first; light mirrors it.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

const _family = 'Google Sans Flex';

/// A variable font is one file: Flutter fakes the weights unless each style
/// also carries its `wght` axis value. Verified axes (fonttools):
/// wght 1-1000, wdth 25-151, opsz, GRAD, ROND, slnt. Licence: OFL 1.1.
TextStyle _v(TextStyle? s) => (s ?? const TextStyle()).copyWith(
  fontFamily: _family,
  fontVariations: [
    FontVariation('wght', (s?.fontWeight ?? FontWeight.w400).value.toDouble()),
  ],
);

/// Condensed: the width axis, for times and distances in tight rows.
TextStyle pmCondensed(TextStyle s, {double width = 88}) => s.copyWith(
  fontFamily: _family,
  fontVariations: [
    FontVariation('wdth', width),
    FontVariation('wght', (s.fontWeight ?? FontWeight.w400).value.toDouble()),
  ],
);

TextTheme _varFont(TextTheme b) => TextTheme(
  displayLarge: _v(b.displayLarge), displayMedium: _v(b.displayMedium),
  displaySmall: _v(b.displaySmall), headlineLarge: _v(b.headlineLarge),
  headlineMedium: _v(b.headlineMedium), headlineSmall: _v(b.headlineSmall),
  titleLarge: _v(b.titleLarge), titleMedium: _v(b.titleMedium),
  titleSmall: _v(b.titleSmall), bodyLarge: _v(b.bodyLarge),
  bodyMedium: _v(b.bodyMedium), bodySmall: _v(b.bodySmall),
  labelLarge: _v(b.labelLarge), labelMedium: _v(b.labelMedium),
  labelSmall: _v(b.labelSmall),
);

ThemeData _base(Brightness brightness, Color seed, PmTokens tokens) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: _family,
    textTheme: _varFont(
      brightness == Brightness.dark
          ? Typography.material2021().white
          : Typography.material2021().black,
    ),
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
