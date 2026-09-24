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

/// Focus layers (own source, FIX_MASTER phase 2). Unrelated ride context stays
/// thin; ground already travelled fades (§9.11).
const contextLineWidth = 1.6;
const travelledOpacity = 0.4;

/// Sheet snap fractions: peek is the resting position, so the map stays usable.
const sheetPeek = 0.15, sheetHalf = 0.5, sheetFull = 0.92;
const sheetSnaps = <double>[sheetPeek, sheetHalf, sheetFull];

/// Camera padding when fitting a focus: the sheet rests at peek.
const focusFitSide = 40.0, focusFitTop = 160.0, focusFitBottomExtra = 24.0;

/// Ambient/focus base stroke width by zoom (before the n-route and rail factors).
const ambientBaseWidths = <(double, double)>[(11, 1.4), (14, 2.6), (17, 4.5)];

/// Focus stop dots: (zoom, small radius, ring width). Termini/boarding stops
/// keep [focusEndDotRadius] at every zoom.
const focusDotByZoom = <(double, double, double)>[(11, 1.5, 0.5), (15, 3.5, 2.0)];
const focusEndDotRadius = 7.0;
