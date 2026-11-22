import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/walk_recorder.dart';
import '../../walk/models.dart';
import '../viewer/format.dart';
import '../widgets/common.dart';
import 'walk_detail_page.dart';
import 'walk_map.dart';

/// Walks: Start, walk, Stop. While one is being recorded the page shows its
/// numbers and the route so far; otherwise the walks recorded earlier.
class WalksPage extends StatelessWidget {
  const WalksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final walk = appController.walk;
    return Scaffold(
      appBar: AppBar(title: const Text('Walks')),
      body: ListenableBuilder(
        listenable: walk,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RecordCard(walk),
            Expanded(
              child: walk.recording
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: WalkMap(points: walk.points, follow: true),
                      ),
                    )
                  : _WalkList(walk),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordCard extends StatefulWidget {
  const _RecordCard(this.walk);
  final WalkRecorder walk;

  @override
  State<_RecordCard> createState() => _RecordCardState();
}

class _RecordCardState extends State<_RecordCard> {
  Timer? _tick;

  /// The elapsed time moves once a second, but only while a walk is being
  /// recorded: no timer otherwise.
  void _syncTick() {
    if (widget.walk.recording && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.walk.recording && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final walk = widget.walk;
    _syncTick();
    final scheme = Theme.of(context).colorScheme;
    final last = walk.last;
    final started = walk.startedAt;
    return Section(
      title: walk.recording ? 'Recording a walk' : 'Record a walk',
      children: [
        if (walk.recording && started != null)
          KeyValueList({
            'Time': fmtDuration(DateTime.now().difference(started)),
            'Distance': fmtDistance(walk.distanceM),
            'Points': '${walk.points.length}',
            'GPS': last == null
                ? 'Waiting for a fix…'
                : last.accM == null
                ? 'fix'
                : 'within ${last.accM!.round()} m',
          })
        else
          const Text(
            'Press Start, walk, and press Stop at the end. The phone can be '
            'in a pocket with the screen off.',
          ),
        if (walk.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(walk.error!, style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 12),
        walk.recording
            ? FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
                onPressed: walk.busy ? null : walk.stop,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              )
            : FilledButton.icon(
                onPressed: walk.busy ? null : walk.start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
      ],
    );
  }
}

class _WalkList extends StatelessWidget {
  const _WalkList(this.walk);
  final WalkRecorder walk;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WalkRow>>(
      key: ValueKey(walk.version),
      future: appController.repo.walks(),
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null) return const LinearProgressIndicator();
        if (rows.isEmpty) {
          return const Center(child: Text('No walks yet'));
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final w = rows[i];
            return ListTile(
              leading: const Icon(Icons.directions_walk),
              title: Text(
                fmtDateLong.format(
                  DateTime.fromMillisecondsSinceEpoch(w.startMs),
                ),
              ),
              subtitle: Text(
                '${fmtTimeMs(w.startMs)} · ${fmtDuration(w.duration)} · '
                '${fmtDistance(w.distanceM)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WalkDetailPage(walkId: w.id),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
