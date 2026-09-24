/// Style numbers for the map layers, in one place (FIX_MASTER ground rule 3).
library;

/// Unsnapped hops: thin dotted, marked approximate (§9.3). Round caps turn the
/// dash pattern into dots.
/// Tram, metro and funicular strokes are this much wider than a bus stroke.
const railWidthFactor = 1.6;

const approxLineWidth = 1.8;
const approxLineDash = <double>[0.1, 2.2];
const approxLineOpacity = 0.75;

/// Filter that keeps the solid line layers to snapped geometry. A feature with
/// no `approx` property (focus and journey features) counts as snapped.
const notApproxFilter = ['!=', ['get', 'approx'], 1];
const isApproxFilter = ['==', ['get', 'approx'], 1];

/// GeoJSON source simplification off and a wide tile buffer, so no line is
/// thinned or clipped at a tile edge.
const lineSourceTolerance = 0.0;
const lineSourceBuffer = 256.0;
