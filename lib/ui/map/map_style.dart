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
///
/// Context (rest of a ridden pattern) and ridden (the part actually ridden) are
/// zoom-interpolated; ridden is >= [riddenToContextMin] x context at every stop.
const contextBaseWidths = <(double, double)>[(11, 0.7), (14, 1.2), (17, 2.0)];
const riddenToContextMin = 2.0;
/// White casing added to a stroke, per side pair: ridden reads over the basemap.
const riddenCasingExtra = 2.0, contextCasingExtra = 1.0;
const kindRidden = 'ridden', kindContext = 'context';
const travelledOpacity = 0.4;

/// Sheet snap fractions: peek is the resting position, so the map stays usable.
const sheetPeek = 0.15, sheetHalf = 0.5, sheetFull = 0.92;
const sheetSnaps = <double>[sheetPeek, sheetHalf, sheetFull];

/// Camera padding when fitting a focus: the sheet rests at peek.
const focusFitSide = 40.0, focusFitTop = 160.0, focusFitBottomExtra = 24.0;

/// Ambient/focus base stroke width by zoom (before the n-route and rail factors).
const ambientBaseWidths = <(double, double)>[(11, 1.4), (14, 2.6), (17, 4.5)];

/// Focus stop dots, diameters in dp (circle radius = diameter / 2).
/// Origin/destination and the first/last stop of a ride are [endDot]; the stops
/// in between [midDot] from [midDotFullZoom], shrinking to [midDotMinFactor] of
/// it at z11 so a dense route stays a line. Ends are their own layer above mids.
const endDot = 14.0, midDot = 8.0;
const midDotFullZoom = 15.0, midDotMinZoom = 11.0, midDotMinFactor = 0.5;
const dotRingWidth = 2.0;

/// Own position dot (FIX_MASTER phase 4). Diameters in dp; the accuracy circle
/// is in metres and scales with zoom. Heading wedge sprite is [meWedgeSize] dp.
const meDotDiameter = 16.0, meRingWidth = 3.0, meWedgeSize = 44.0;
const meAccuracyOpacity = 0.15, meAccuracyStrokeOpacity = 0.35;
const meColor = '#1A73E8';

/// Walk legs (phase 5): dotted, round caps, white casing. Dash lengths are in
/// line widths, so [walkDash] keeps the same absolute spacing for the casing.
const walkWidth = 5.0, walkCasingExtra = 3.0;
const walkDotSpacingPx = 9.0;
List<double> walkDash(double width) => [0.5 / width, (walkDotSpacingPx - 0.5) / width];

// -- ambient + focus line dressing (audit 2026-09: no literals in layer code)
/// Casing under ambient lines: this much wider, at this share of the tier.
const ambientCasingExtra = 2.0, ambientCasingOpacity = 0.8;

/// Focus-line casing opacity.
const focusCasingOpacity = 0.8;

/// Picker candidates (§9.8): this much wider than ambient, this opaque.
const pickedExtra = 4.0, pickedOpacity = 0.9;

/// One-way arrows along lines (§9.6).
const arrowGlyph = '›';
const arrowTextSize = 16.0, arrowHaloWidth = 1.0, arrowSpacing = 90.0;

/// Dashed stop-to-road connectors.
const connectorOpacity = 0.5, connectorWidth = 1.2;
const connectorDash = <double>[2.0, 2.0];

/// White dotted casing under walking legs.
const walkCasingColor = '#FFFFFF', walkCasingOpacity = 0.9;
