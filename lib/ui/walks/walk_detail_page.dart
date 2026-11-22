import 'package:flutter/material.dart';

import '../../main.dart';
import '../../walk/models.dart';
import '../viewer/format.dart';
import '../widgets/common.dart';
import 'walk_map.dart';

/// One finished walk: the route on the map, its numbers, and Delete.
class WalkDetailPage extends StatefulWidget {
  const WalkDetailPage({super.key, required this.walkId});
  final int walkId;

  @override
  State<WalkDetailPage> createState() => _WalkDetailPageState();
}

class _WalkDetailPageState extends State<WalkDetailPage> {
  late final Future<(WalkRow?, List<WalkPoint>)> _load = () async {
    final repo = appController.repo;
    return (
      await repo.walk(widget.walkId),
      await repo.walkPoints(widget.walkId),
    );
  }();

  Future<void> _delete() async {
    final ok = await confirmSimple(
      context,
      title: 'Delete this walk?',
      body: 'The walk and its GPS points are removed from the phone.',
    );
    if (!ok) return;
    await appController.walk.delete(widget.walkId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk'),
        actions: [
          IconButton(
            tooltip: 'Delete',
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _load,
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) return const LinearProgressIndicator();
          final (w, points) = data;
          if (w == null) return const Center(child: Text('No such walk'));
          final seconds = w.duration.inSeconds;
          final alts = [for (final p in points) ?p.altM];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: WalkMap(points: points)),
              Section(
                title: fmtDateLong.format(
                  DateTime.fromMillisecondsSinceEpoch(w.startMs),
                ),
                children: [
                  KeyValueList({
                    'Time':
                        '${fmtTimeMs(w.startMs)} – ${fmtTimeMs(w.endMs)} '
                        '(${fmtDuration(w.duration)})',
                    'Distance': fmtDistance(w.distanceM),
                    'Average speed': seconds == 0
                        ? '–'
                        : '${(w.distanceM / seconds * 3.6).toStringAsFixed(1)} km/h',
                    if (alts.isNotEmpty)
                      'Altitude':
                          '${alts.reduce((a, b) => a < b ? a : b).round()} – '
                          '${alts.reduce((a, b) => a > b ? a : b).round()} m',
                    'Points': '${w.pointCount}',
                    'Uploaded': w.sentMs == null ? 'not yet' : fmtMs(w.sentMs!),
                  }),
                ],
              ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}
