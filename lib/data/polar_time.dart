/// Time conversions for Polar sample data.
///
/// Polar devices stamp samples in **nanoseconds since 2000-01-01T00:00:00**, and
/// when the device clock was set with `setLocalTime` the stamps count from the
/// *local* midnight of that epoch, not UTC (see TimeSystemExplained.md in the
/// SDK). heild always sets the sensor clock to the phone's local time, so the
/// phone's zone offset is subtracted to get Unix time. Offline HR samples carry
/// no timestamp at all (1 Hz from the recording start) and PPI samples are
/// cumulative pulse-to-pulse intervals from the start.
library;

/// 2000-01-01T00:00:00Z in Unix milliseconds.
const polarEpochUnixMs = 946684800000;

/// Converts a Polar nanosecond timestamp to Unix milliseconds.
///
/// [zoneOffsetFor] returns the local offset at a given Unix time; it defaults
/// to the phone's zone. Two passes handle the (rare) case where the naive
/// result lands on the other side of a DST switch.
int polarNsToUnixMs(int ns, {Duration Function(int unixMs)? zoneOffsetFor}) {
  final offsetFor =
      zoneOffsetFor ??
      (ms) => DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset;
  final naive = ns ~/ 1000000 + polarEpochUnixMs;
  final first = naive - offsetFor(naive).inMilliseconds;
  return naive - offsetFor(first).inMilliseconds;
}

/// Parses the SDK's `LocalDateTime.toString()` (no zone) as phone-local time.
int localIsoToUnixMs(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

/// Timestamps of an offline HR recording: one sample per second from the start.
List<int> hrTimestamps(int startMs, int count) =>
    List<int>.generate(count, (i) => startMs + i * 1000, growable: false);

/// Timestamps of a PPI recording.
///
/// Uses the device stamps when present (non-zero), otherwise accumulates the
/// intervals from the recording start: each sample ends `ppi` ms after the
/// previous one.
List<int> ppiTimestamps(
  int startMs,
  List<int> ppiMs,
  List<int> deviceNs, {
  Duration Function(int unixMs)? zoneOffsetFor,
}) {
  final out = List<int>.filled(ppiMs.length, 0);
  var t = startMs;
  for (var i = 0; i < ppiMs.length; i++) {
    final ns = i < deviceNs.length ? deviceNs[i] : 0;
    if (ns > 0) {
      t = polarNsToUnixMs(ns, zoneOffsetFor: zoneOffsetFor);
    } else {
      t += ppiMs[i];
    }
    out[i] = t;
  }
  return out;
}

/// Start of the minute containing [unixMs].
int minuteFloor(int unixMs) => unixMs - unixMs % 60000;
