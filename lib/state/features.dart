import '../polar/models.dart';

/// Simplified mode (2026-11-15): the app only syncs. The sensor records heart
/// rate and movement, nothing is streamed live, and pulse intervals (HRV) are
/// neither recorded nor fetched. The live and PPI code stays in place behind
/// these two switches; turning them back on restores it.

/// Live sessions (streaming to the phone while connected). Off: no Live
/// button, no live cards, and live samples are never stored.
const liveEnabled = false;

/// The types the app records on the sensor, fetches and shows.
const supportedTypes = {PolarDataType.hr, PolarDataType.acc};

/// Walks (GPS between Start and Stop) go to the server like the sensor's
/// recordings: `POST /api/walk` on the heild site. Against a server that does
/// not have the route yet the walks just stay unsent and the upload run ends
/// with an error line.
const walkUploadEnabled = true;
