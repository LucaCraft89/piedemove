/// Design tokens: one definition per colour, spacing and walk tier.
///
/// Mode colours are the GATE 1 defaults (bus green, tram orange, metro red,
/// funicular purple, regional teal) with a dark variant each. Dark is tuned
/// first: the light variants are the darkened twins, not the other way round.
library;

import 'package:flutter/material.dart';

import 'package:piedemove/data/transit_index.dart';

class ModeColors {
  const ModeColors({
    required this.bus,
    required this.tram,
    required this.metro,
    required this.funicular,
    required this.regional,
  });

  final Color bus;
  final Color tram;
  final Color metro;
  final Color funicular;
  final Color regional;

  static const dark = ModeColors(
    bus: Color(0xFF4ADE80),
    tram: Color(0xFFFB923C),
    metro: Color(0xFFF87171),
    funicular: Color(0xFFC084FC),
    regional: Color(0xFF2DD4BF),
  );

  static const light = ModeColors(
    bus: Color(0xFF15803D),
    tram: Color(0xFFC2410C),
    metro: Color(0xFFB91C1C),
    funicular: Color(0xFF7E22CE),
    regional: Color(0xFF0F766E),
  );

  Color ofRouteType(int routeType) => switch (routeType) {
        RouteType.tram => tram,
        RouteType.metro => metro,
        RouteType.funicular => funicular,
        _ => bus,
      };

  /// Mixed stops take the most distinctive mode: metro > funicular > tram > bus.
  Color ofModes(Set<int> routeTypes) {
    for (final t in const [
      RouteType.metro,
      RouteType.funicular,
      RouteType.tram,
    ]) {
      if (routeTypes.contains(t)) return ofRouteType(t);
    }
    return bus;
  }
}

/// Walking metres are the cost of a journey, so they are never grey.
/// Three tiers, per `piedemove-lines` §9.10.
class WalkColors {
  const WalkColors(this.short, this.medium, this.long);

  final Color short; // <= 250 m
  final Color medium; // <= 600 m
  final Color long; // beyond

  static const dark = WalkColors(
    Color(0xFF38BDF8),
    Color(0xFFFBBF24),
    Color(0xFFF472B6),
  );
  static const light = WalkColors(
    Color(0xFF0369A1),
    Color(0xFFB45309),
    Color(0xFFBE185D),
  );

  Color ofMetres(double m) =>
      m <= 250 ? short : (m <= 600 ? medium : long);
}

@immutable
class PmTokens extends ThemeExtension<PmTokens> {
  const PmTokens({required this.modes, required this.walk, required this.live});

  final ModeColors modes;
  final WalkColors walk;

  /// Live data always stands out against muted "Programmato".
  final Color live;

  static const darkTokens = PmTokens(
    modes: ModeColors.dark,
    walk: WalkColors.dark,
    live: Color(0xFF22D3EE),
  );
  static const lightTokens = PmTokens(
    modes: ModeColors.light,
    walk: WalkColors.light,
    live: Color(0xFF0E7490),
  );

  @override
  PmTokens copyWith({ModeColors? modes, WalkColors? walk, Color? live}) =>
      PmTokens(
        modes: modes ?? this.modes,
        walk: walk ?? this.walk,
        live: live ?? this.live,
      );

  @override
  PmTokens lerp(PmTokens? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension PmTheme on BuildContext {
  PmTokens get tokens => Theme.of(this).extension<PmTokens>()!;
}

/// Airy spacing: 16 dp screen padding, 12 dp between elements, 48 dp rows.
class Gap {
  static const screen = 16.0;
  static const element = 12.0;
  static const row = 48.0;
  static const tapTarget = 44.0;
}
