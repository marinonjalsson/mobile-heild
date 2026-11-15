import 'dart:async';

import 'package:flutter/material.dart';

import '../../polar/models.dart';
import '../../state/sync_service.dart';
import 'format.dart';

/// Tells the wearer whether the sensor is recording, as confirmed by the
/// sensor itself at the end of the last sync. A sync stops the recordings to
/// fetch them, and the heart rate is 0 for the first seconds of a new one, so
/// green is what to wait for before starting an exercise: it comes
/// [SyncService.recordingSettle] after the confirmation.
class RecordingCard extends StatefulWidget {
  const RecordingCard(this.sync, {super.key});

  final SyncService sync;

  @override
  State<RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<RecordingCard> {
  SyncService get sync => widget.sync;

  /// Fires once when the settle time is over, to turn the card green.
  Timer? _settle;
  DateTime? _settleFor;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  /// True while a confirmed recording is still inside its settle time; arms
  /// the one-shot timer that rebuilds the card when it ends.
  bool _settling() {
    final at = sync.recordingAt;
    if (sync.recording != RecordingState.recording || at == null) return false;
    final left = SyncService.recordingSettle - DateTime.now().difference(at);
    if (left <= Duration.zero) return false;
    if (_settleFor != at) {
      _settleFor = at;
      _settle?.cancel();
      _settle = Timer(left + const Duration(milliseconds: 100), () {
        if (mounted) setState(() {});
      });
    }
    return true;
  }

  static String _name(PolarDataType t) => switch (t) {
    PolarDataType.hr => 'Heart rate',
    PolarDataType.acc => 'Movement',
    _ => t.label,
  };

  static String _when(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final today =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return today ? fmtTime.format(t) : fmtDateTime.format(t);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A sync on its way to the sensor is about to stop the recordings.
    final interrupting =
        sync.recording == RecordingState.paused ||
        sync.phase == SyncPhase.connecting ||
        sync.phase == SyncPhase.settingTime ||
        sync.phase == SyncPhase.stoppingRecordings;
    final (IconData icon, Color color, String title, String text) = interrupting
        ? (
            Icons.pause_circle,
            Colors.amber.shade800,
            'Syncing · recording is paused',
            'Wait for "Sensor is recording" before you start an exercise.',
          )
        : _settling()
        ? (
            Icons.hourglass_top,
            Colors.amber.shade800,
            'Recording is starting',
            'The sensor has started. Wait about 20 s, until this turns '
                'green, before you start an exercise.',
          )
        : switch (sync.recording) {
            RecordingState.recording => (
              Icons.fiber_manual_record,
              Colors.green.shade600,
              'Sensor is recording',
              '${viewerTypes.where(sync.recordingTypes.contains).map(_name).join(' and ')} · confirmed by '
                  'the sensor at ${_when(sync.recordingAt)}.',
            ),
            RecordingState.failed => (
              Icons.error,
              scheme.error,
              'Sensor is not recording everything',
              '${sync.recordingProblem ?? ''} Checked at '
                  '${_when(sync.recordingAt)}. Sync again once that is fixed.',
            ),
            _ => (
              Icons.help,
              scheme.outline,
              'Recording not confirmed yet',
              'Sync once: the sensor then reports what it is recording.',
            ),
          };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(text, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
