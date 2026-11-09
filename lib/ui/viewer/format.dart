import 'package:intl/intl.dart';

import '../../polar/models.dart';

final fmtTime = DateFormat.Hm();
final fmtDateTime = DateFormat('d MMM HH:mm');
final fmtDate = DateFormat('EEE d MMM');
final fmtDateLong = DateFormat.yMMMEd();

String fmtMs(int ms) =>
    fmtDateTime.format(DateTime.fromMillisecondsSinceEpoch(ms));
String fmtTimeMs(int ms) =>
    fmtTime.format(DateTime.fromMillisecondsSinceEpoch(ms));

String fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
  if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
  return '${d.inSeconds} s';
}

String fmtAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return fmtDateTime.format(t);
}

/// Short name and unit of what the viewer shows for a type.
String typeUnit(PolarDataType t) => switch (t) {
  PolarDataType.hr => 'bpm',
  PolarDataType.ppi => 'ms',
  PolarDataType.acc => 'mG',
  _ => '',
};

const viewerTypes = [PolarDataType.hr, PolarDataType.ppi, PolarDataType.acc];
