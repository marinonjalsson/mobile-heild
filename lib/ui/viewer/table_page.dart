import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
import '../widgets/common.dart';
import 'format.dart';

/// Recordings stored on the phone, with raw-sample drill-down.
class TablePage extends StatefulWidget {
  const TablePage({super.key});

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  PolarDataType? _filter;

  @override
  Widget build(BuildContext context) {
    final repo = appController.repo;
    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: ListenableBuilder(
        listenable: appController.sync,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  for (final t in viewerTypes)
                    ChoiceChip(
                      label: Text(t.label),
                      selected: _filter == t,
                      onSelected: (_) => setState(() => _filter = t),
                    ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<RecordingRow>>(
                key: ValueKey((_filter, appController.sync.dataVersion)),
                future: repo.recordings(type: _filter, limit: 500),
                builder: (context, snap) {
                  final rows = snap.data;
                  if (rows == null) return const LinearProgressIndicator();
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text('No recordings stored yet.'),
                    );
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      return ListTile(
                        leading: Icon(_icon(r.type)),
                        title: Text(
                          '${r.type.label} · ${fmtMs(r.startMs)}'
                          '${r.source == 'live' ? ' · live' : ''}',
                        ),
                        subtitle: Text(
                          '${fmtDuration(r.duration)} · ${r.sampleCount} samples'
                          '${r.rateHz == null ? '' : ' · ${r.rateHz} Hz'}'
                          '${r.range == null ? '' : ' ±${r.range} g'}',
                        ),
                        trailing: Icon(
                          r.sent ? Icons.cloud_done : Icons.cloud_off,
                          color: r.sent
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).hintColor,
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RecordingDetailPage(r.id),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(PolarDataType t) => switch (t) {
    PolarDataType.hr => Icons.favorite,
    PolarDataType.ppi => Icons.monitor_heart,
    PolarDataType.acc => Icons.directions_run,
    _ => Icons.sensors,
  };
}

/// One recording: metadata, actions, paged raw rows.
class RecordingDetailPage extends StatefulWidget {
  const RecordingDetailPage(this.id, {super.key});
  final int id;

  @override
  State<RecordingDetailPage> createState() => _RecordingDetailPageState();
}

class _RecordingDetailPageState extends State<RecordingDetailPage> {
  static const _page = 200;
  RecordingRow? _rec;
  final _hr = <HrRow>[];
  final _ppi = <PpiRow>[];
  final _acc = <AccChunkRow>[];
  bool _more = true;
  bool _loading = false;

  Repository get repo => appController.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _rec = await repo.recording(widget.id);
    if (mounted) setState(() {});
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final r = _rec;
    if (r == null || _loading || !_more) return;
    setState(() => _loading = true);
    int got;
    switch (r.type) {
      case PolarDataType.hr:
        final rows = await repo.hrRows(r.id, limit: _page, offset: _hr.length);
        _hr.addAll(rows);
        got = rows.length;
      case PolarDataType.ppi:
        final rows = await repo.ppiRows(
          r.id,
          limit: _page,
          offset: _ppi.length,
        );
        _ppi.addAll(rows);
        got = rows.length;
      case PolarDataType.acc:
        final rows = await repo.accChunks(
          r.id,
          limit: _page,
          offset: _acc.length,
        );
        _acc.addAll(rows);
        got = rows.length;
      default:
        got = 0;
    }
    if (mounted) {
      setState(() {
        _more = got == _page;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _rec;
    if (r == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 13);
    final count = switch (r.type) {
      PolarDataType.hr => _hr.length,
      PolarDataType.ppi => _ppi.length,
      _ => _acc.length,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('${r.type.label} · ${fmtMs(r.startMs)}'),
        actions: [
          IconButton(
            tooltip: r.sent ? 'Mark as not sent to mon' : 'Mark as sent to mon',
            icon: Icon(r.sent ? Icons.cloud_done : Icons.cloud_upload_outlined),
            onPressed: () async {
              await repo.markSent(r.id, !r.sent);
              _rec = await repo.recording(r.id);
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'Delete from phone',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await confirmSimple(
                context,
                title: 'Delete recording?',
                body:
                    'Removes ${r.sampleCount} samples of ${r.type.label} from the phone. '
                    'The sensor copy was already deleted when it was fetched.',
              );
              if (!ok || !context.mounted) return;
              await repo.deleteRecording(r.id);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: KeyValueList({
              'Start': fmtMs(r.startMs),
              'End': fmtMs(r.endMs),
              'Duration': fmtDuration(r.duration),
              'Samples': '${r.sampleCount}',
              'Source': r.source == 'live'
                  ? 'streamed live to the phone'
                  : 'recorded on the sensor',
              if (r.rateHz != null) 'Rate': '${r.rateHz} Hz',
              if (r.range != null) 'Range': '±${r.range} g',
              'Sensor file': r.path ?? '—',
              'Fetched': fmtMs(r.fetchedMs),
              'Sent to mon': r.sentMs == null ? 'no' : fmtMs(r.sentMs!),
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: count + 1,
              itemBuilder: (context, i) {
                if (i == count) {
                  if (!_more) {
                    return const SizedBox(height: 24);
                  }
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: _loading
                          ? const CircularProgressIndicator()
                          : OutlinedButton(
                              onPressed: _loadMore,
                              child: const Text('Load more'),
                            ),
                    ),
                  );
                }
                switch (r.type) {
                  case PolarDataType.hr:
                    final s = _hr[i];
                    return _row(
                      '${fmtTimeMs(s.tsMs)}:${_sec(s.tsMs)}  ${s.hr.toString().padLeft(3)} bpm${s.contact == false ? '  (no contact)' : ''}',
                      mono,
                    );
                  case PolarDataType.ppi:
                    final s = _ppi[i];
                    return _row(
                      '${fmtTimeMs(s.tsMs)}:${_sec(s.tsMs)}  ${s.ppi.toString().padLeft(4)} ms  ±${s.errorEstimate.toString().padLeft(3)}  hr ${s.hr.toString().padLeft(3)}${s.blocker ? '  blocker' : ''}${s.skinContact ? '' : '  no skin'}',
                      mono,
                    );
                  default:
                    final c = _acc[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${fmtTimeMs(c.startMs)}:${_sec(c.startMs)} – ${fmtTimeMs(c.endMs)}:${_sec(c.endMs)}  ${c.sampleCount} samples @ ${c.rateHz} Hz',
                        style: mono,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showChunk(c),
                    );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String text, TextStyle style) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
    child: Text(text, style: style),
  );

  static String _sec(int ms) => (DateTime.fromMillisecondsSinceEpoch(
    ms,
  ).second).toString().padLeft(2, '0');

  Future<void> _showChunk(AccChunkRow c) async {
    final Int32List xyz = await repo.accChunkSamples(c.id);
    if (!mounted) return;
    final buf = StringBuffer('t(ms)    x      y      z\n');
    final step = 1000 / c.rateHz;
    final n = xyz.length ~/ 3;
    for (var i = 0; i < n; i++) {
      buf.writeln(
        '${(i * step).round().toString().padLeft(5)} ${xyz[i * 3].toString().padLeft(6)} ${xyz[i * 3 + 1].toString().padLeft(6)} ${xyz[i * 3 + 2].toString().padLeft(6)}',
      );
    }
    await showTextDialog(
      context,
      'ACC ${fmtTimeMs(c.startMs)} · $n samples (mG)',
      buf.toString(),
    );
  }
}
