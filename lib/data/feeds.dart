/// Feed endpoints. Verified 2026-09-17. See the `piedemove-data` skill.
library;

class Feeds {
  static const gttStaticGtfs = 'https://www.gtt.to.it/open_data/gtt_gtfs.zip';
  static const gttTripUpdates =
      'https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx';
  static const gttVehiclePositions =
      'https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx';
  static const gttAlerts =
      'https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx';

  /// Phase 9, scheduled only.
  static const piemonteBusGtfs =
      'https://api.smartdatanet.it/api/Servizioprogrammatodeltrasportopubblicoregionepiemonteautobus_22942/attachment/22941/1/GTFS_BUS_IT_PIE.zip';

  static const all = <String, String>{
    'gtt static': gttStaticGtfs,
    'gtt trip updates': gttTripUpdates,
    'gtt vehicle positions': gttVehiclePositions,
    'gtt alerts': gttAlerts,
  };
}
