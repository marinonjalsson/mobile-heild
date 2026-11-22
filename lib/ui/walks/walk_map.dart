import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../walk/models.dart';

/// A walk drawn on OpenStreetMap tiles.
///
/// With [follow] the map keeps the newest fix in the middle (a walk that is
/// being recorded); without it the whole route is fitted once.
///
/// The tiles come from tile.openstreetmap.org, which thereby learns which
/// area is being looked at. Without network the route is drawn on nothing.
class WalkMap extends StatefulWidget {
  const WalkMap({super.key, required this.points, this.follow = false});

  final List<WalkPoint> points;
  final bool follow;

  @override
  State<WalkMap> createState() => _WalkMapState();
}

class _WalkMapState extends State<WalkMap> {
  final _controller = MapController();
  bool _ready = false;

  @override
  void didUpdateWidget(WalkMap old) {
    super.didUpdateWidget(old);
    if (widget.follow && _ready && widget.points.isNotEmpty) {
      final p = widget.points.last;
      _controller.move(LatLng(p.lat, p.lon), _controller.camera.zoom);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = [for (final p in widget.points) LatLng(p.lat, p.lon)];
    if (line.isEmpty) {
      return ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: const Center(child: Text('Waiting for GPS…')),
      );
    }
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: line.last,
        initialZoom: 16,
        initialCameraFit: widget.follow || line.length < 2
            ? null
            : CameraFit.coordinates(
                coordinates: line,
                padding: const EdgeInsets.all(32),
                maxZoom: 17,
              ),
        maxZoom: 19,
        onMapReady: () => _ready = true,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'is.loria.heild',
        ),
        PolylineLayer(
          polylines: [
            Polyline(points: line, strokeWidth: 4, color: scheme.primary),
          ],
        ),
        CircleLayer(
          circles: [
            CircleMarker(
              point: line.first,
              radius: 6,
              color: scheme.surface,
              borderColor: scheme.primary,
              borderStrokeWidth: 3,
            ),
            CircleMarker(
              point: line.last,
              radius: 7,
              color: scheme.primary,
              borderColor: scheme.surface,
              borderStrokeWidth: 2,
            ),
          ],
        ),
        const SimpleAttributionWidget(
          source: Text('OpenStreetMap contributors'),
        ),
      ],
    );
  }
}
