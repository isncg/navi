import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  FlutterError.onError = (details) {
    dev.log('FlutterError: ${details.exceptionAsString()}', name: 'Navi');
  };
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Navi',
      home: MapPage(),
    );
  }
}

class _TrackPoint {
  final LatLng point;
  final DateTime time;
  final double totalDistance;
  final int segment;

  const _TrackPoint(this.point, this.time, this.totalDistance, {this.segment = 0});
}

class _SavedRecording {
  final String name;
  final String path;
  final int pointCount;
  final double totalDistance;

  const _SavedRecording({
    required this.name,
    required this.path,
    required this.pointCount,
    required this.totalDistance,
  });
}

class _Measurement {
  final LatLng from;
  final LatLng to;
  const _Measurement(this.from, this.to);
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  LatLng _center = const LatLng(39.9042, 116.4074);
  bool _located = false;
  bool _failed = false;
  final _mapController = MapController();

  bool _recording = false;
  final _track = <_TrackPoint>[];
  int _elapsedSeconds = 0;
  int _currentSegment = 0;
  Timer? _timer;
  StreamSubscription<Position>? _posSub;

  bool _waypointMode = false;
  final _waypoints = <LatLng>[];
  final _savedWaypoints = <List<LatLng>>[];
  int _cameraVersion = 0;

  final _savedRecordings = <_SavedRecording>[];
  List<_TrackPoint>? _loadedTrack;
  String? _loadedTrackName;

  final _distanceCalc = const Distance();

  final _logs = <String>[];
  bool _showLogs = false;
  bool _cartographicMode = false;
  LatLng? _gridOrigin;

  bool _measureMode = false;
  bool _eraserMode = false;
  final _measurements = <_Measurement>[];
  LatLng? _dragFrom;
  LatLng? _dragTo;
  Offset? _dragLastScreen;

  void _log(String msg, {Object? error}) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final text = '[$ts] $msg${error != null ? ' $error' : ''}';
    dev.log(msg, name: 'Navi', error: error);
    if (!mounted) return;
    setState(() => _logs.add(text));
  }

  @override
  void initState() {
    super.initState();
    _log('App started');
    _locate();
    _loadSavedRecordings();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() => _failed = false);
    _log('Locating...');

    final service = await Geolocator.isLocationServiceEnabled();
    _log('Location service enabled: $service');
    if (!service) {
      _log('Location service disabled', error: 'turn on GPS');
      if (!mounted) return;
      setState(() => _failed = true);
      return;
    }

    var perm = await Geolocator.checkPermission();
    _log('Permission status: $perm');
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      _log('Permission after request: $perm');
      if (perm == LocationPermission.denied) {
        _log('Permission denied by user');
        if (!mounted) return;
        setState(() => _failed = true);
        return;
      }
    }
    if (perm == LocationPermission.deniedForever) {
      _log('Permission denied forever');
      if (!mounted) return;
      setState(() => _failed = true);
      return;
    }

    try {
      _log('Requesting position...');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _locationSettings(),
      );
      _log('Position: ${position.latitude}, ${position.longitude} accuracy=${position.accuracy}m');
      if (!mounted) return;
      setState(() {
        _center = LatLng(position.latitude, position.longitude);
        _located = true;
      });
      _moveToCurrent();
    } catch (e, st) {
      _log('Position error', error: '$e\n$st');
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _moveToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(_center, 18);
    });
  }

  void _toggleRecording() {
    if (_recording) {
      _stopRecording();
    } else {
      _startRecording();
    }
  }

  LocationSettings _locationSettings({int distanceFilter = 0}) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
        forceLocationManager: true,
        timeLimit: const Duration(seconds: 15),
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: distanceFilter,
      timeLimit: const Duration(seconds: 15),
    );
  }

  void _startRecording() {
    _track.clear();
    _elapsedSeconds = 0;
    _currentSegment = 0;

    final now = DateTime.now();
    _track.add(_TrackPoint(_center, now, 0));

    _posSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(distanceFilter: 2),
    ).listen((pos) {
      if (!mounted) return;
      try {
        final p = LatLng(pos.latitude, pos.longitude);
        final last = _track.last;
        final d = _distanceCalc.as(LengthUnit.Meter, last.point, p);
        final total = last.totalDistance + d;
        final gap = pos.timestamp.difference(last.time);
        if (gap.inSeconds > 10 || d > 1000) {
          _currentSegment++;
          _log('GPS gap detected, new segment $_currentSegment');
        }
        setState(() {
          _track.add(_TrackPoint(p, pos.timestamp, total, segment: _currentSegment));
        });
      } catch (e) {
        _log('Stream position error', error: e);
      }
    }, onError: (e) {
      _log('Stream error', error: e);
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });

    setState(() => _recording = true);
  }

  void _stopRecording() {
    _posSub?.cancel();
    _posSub = null;
    _timer?.cancel();
    _timer = null;
    setState(() => _recording = false);
    if (_track.length >= 2) _saveRecording();
  }

  Future<Directory> _trackDir() async {
    Directory parent;
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      parent = ext ?? await getApplicationDocumentsDirectory();
    } else {
      parent = await getApplicationDocumentsDirectory();
    }
    final trackDir = Directory('${parent.path}/navi_tracks');
    if (!await trackDir.exists()) await trackDir.create(recursive: true);
    return trackDir;
  }

  Future<void> _saveRecording() async {
    final now = DateTime.now();
    final name = '${now.year}-${_pad(now.month)}-${_pad(now.day)}_'
        '${_pad(now.hour)}-${_pad(now.minute)}-${_pad(now.second)}';
    final buf = StringBuffer();
    buf.writeln('#$name');
    for (final t in _track) {
      buf.writeln('${t.point.latitude.toStringAsFixed(6)} '
          '${t.point.longitude.toStringAsFixed(6)} '
          '${t.time.millisecondsSinceEpoch} '
          '${t.segment}');
    }
    try {
      final dir = await _trackDir();
      final file = File('${dir.path}/$name.track');
      await file.writeAsString(buf.toString());
      _log('Track saved: $name (${_track.length} pts)');
      _loadSavedRecordings();
    } catch (e) {
      _log('Save failed', error: e);
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  Future<void> _loadSavedRecordings() async {
    try {
      final dir = await _trackDir();
      final files = await dir.list().toList();
      final recordings = <_SavedRecording>[];
      for (final f in files) {
        if (f is File && f.path.endsWith('.track')) {
          try {
            final lines = await f.readAsLines();
            if (lines.isEmpty) continue;
            final name = lines.first.startsWith('#')
                ? lines.first.substring(1)
                : f.path.split('/').last.replaceAll('.track', '');
            double totalDist = 0;
            LatLng? prev;
            for (int i = 1; i < lines.length; i++) {
              final parts = lines[i].split(' ');
              if (parts.length < 2) continue;
              final point = LatLng(double.parse(parts[0]), double.parse(parts[1]));
              if (prev != null) {
                totalDist += _distanceCalc.as(LengthUnit.Meter, prev, point);
              }
              prev = point;
            }
            recordings.add(_SavedRecording(
              name: name,
              path: f.path,
              pointCount: lines.length - 1,
              totalDistance: totalDist,
            ));
          } catch (_) {}
        }
      }
      recordings.sort((a, b) => b.name.compareTo(a.name));
      if (mounted) setState(() => _savedRecordings.replaceRange(0, _savedRecordings.length, recordings));
    } catch (_) {}
  }

  Future<void> _loadRecording(_SavedRecording rec) async {
    try {
      final lines = await File(rec.path).readAsLines();
      if (lines.isEmpty) return;
      final points = <_TrackPoint>[];
      double cum = 0;
      LatLng? prev;
      for (int i = 1; i < lines.length; i++) {
        final parts = lines[i].split(' ');
        if (parts.length < 3) continue;
        final point = LatLng(double.parse(parts[0]), double.parse(parts[1]));
        final time = DateTime.fromMillisecondsSinceEpoch(int.parse(parts[2]));
        final seg = parts.length > 3 ? int.parse(parts[3]) : 0;
        if (prev != null) {
          cum += _distanceCalc.as(LengthUnit.Meter, prev, point);
        }
        prev = point;
        points.add(_TrackPoint(point, time, cum, segment: seg));
      }
      if (mounted) {
        setState(() {
          _loadedTrack = points;
          _loadedTrackName = rec.name;
        });
      }
      _log('Loaded track: ${rec.name}');
    } catch (e) {
      _log('Load failed', error: e);
    }
  }

  Future<void> _deleteRecording(_SavedRecording rec) async {
    try {
      await File(rec.path).delete();
      _loadSavedRecordings();
      if (_loadedTrackName == rec.name) {
        setState(() {
          _loadedTrack = null;
          _loadedTrackName = null;
        });
      }
    } catch (e) {
      _log('Delete failed', error: e);
    }
  }

  String _fmtDuration(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _fmtDistance(double m) {
    if (m < 1000) return '${m.toStringAsFixed(0)} m';
    return '${(m / 1000).toStringAsFixed(2)} km';
  }

  String _toDms(double deg, {required bool isLat}) {
    final dir = isLat
        ? (deg >= 0 ? 'N' : 'S')
        : (deg >= 0 ? 'E' : 'W');
    final d = deg.abs();
    final degrees = d.truncate();
    final minutes = ((d - degrees) * 60).truncate();
    final seconds = ((d - degrees) * 60 - minutes) * 60;
    return '$degrees°${minutes.toString().padLeft(2, '0')}\'${seconds.toStringAsFixed(1).padLeft(4, '0')}"$dir';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: _located ? 18 : 16,
              interactionOptions: InteractionOptions(
                flags: (_measureMode && !_eraserMode)
                    ? InteractiveFlag.all & ~InteractiveFlag.drag & ~InteractiveFlag.pinchMove & ~InteractiveFlag.rotate
                    : InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: (_waypointMode || _eraserMode)
                  ? (tapPos, latlng) {
                      if (_eraserMode) {
                        _eraseMeasurement(latlng);
                        return;
                      }
                      setState(() => _waypoints.add(latlng));
                    }
                  : null,
              onMapEvent: (ev) {
                if (ev is MapEventMoveEnd ||
                    ev is MapEventFlingAnimationEnd ||
                    ev is MapEventScrollWheelZoom) {
                  setState(() => _cameraVersion++);
                }
              },
            ),
            children: [
              if (_cartographicMode)
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.10, 0.33, 0.03, 0, 35,
                    0.12, 0.37, 0.04, 0, 42,
                    0.15, 0.45, 0.05, 0, 60,
                    0,    0,    0,    1, 0,
                  ]),
                  child: TileLayer(
                    urlTemplate:
                        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  ),
                )
              else
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                ),
              if (_cartographicMode) _buildGridLayer(),
              if (_located) _buildLocationMarker(),
              if (_track.length >= 2) _buildTrackPolyline(),
              if (_track.length >= 2) MarkerLayer(markers: _buildTrackLabels()),
              if (_loadedTrack != null && _loadedTrack!.length >= 2) ...[
                _buildLoadedTrackPolyline(),
                MarkerLayer(markers: _buildLoadedTrackLabels()),
                if (_loadedTrack!.isNotEmpty) _buildLoadedTrackEndpoints(),
              ],
              if (_waypoints.length >= 2) _buildWaypointLines(),
              if (_waypoints.length >= 2) MarkerLayer(markers: _buildWaypointLabels()),
              if (_waypoints.isNotEmpty) _buildWaypointLayer(),
              if (_measurements.isNotEmpty) _buildMeasurementPolyline(),
              if (_measurements.isNotEmpty) MarkerLayer(markers: _buildMeasurementLabels()),
              if (_dragFrom != null && _dragTo != null) ...[
                _buildDragPolyline(),
                MarkerLayer(markers: _buildDragLabels()),
              ],
              for (int s = 0; s < _savedWaypoints.length; s++) ...[
                _buildSavedWaypointLines(s),
                MarkerLayer(markers: _buildSavedWaypointLabels(s)),
                _buildSavedWaypointLayer(s),
              ],
            ],
          ),
              if (_recording) _buildTimerBar(),
          if (_loadedTrack != null) _buildLoadedTrackBar(),
          if (_waypointMode) _buildWaypointBar(),
          if (_cartographicMode) _buildZoomLabel(),
          if (!_located) const Center(child: CircularProgressIndicator()),
          if (_showLogs) _buildLogPanel(),
          if (_measureMode && !_eraserMode) _buildDragCapture(),
        ],
      ),
      floatingActionButton: _buildFabs(),
    );
  }

  Widget _buildZoomLabel() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Z${_mapController.camera.zoom.toStringAsFixed(1)}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerBar() {
    final dist = _track.isNotEmpty ? _track.last.totalDistance : 0.0;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _fmtDuration(_elapsedSeconds),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const Spacer(),
              Text(
                _fmtDistance(dist),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _segmentColors = [
    Colors.cyanAccent,
    Colors.yellowAccent,
    Colors.orangeAccent,
    Colors.greenAccent,
    Colors.pinkAccent,
  ];

  static const _loadedSegmentColors = [
    Colors.purpleAccent,
    Colors.pink,
    Colors.deepOrangeAccent,
    Colors.tealAccent,
  ];

  List<Polyline> _buildSegmentPolylines(
    List<_TrackPoint> points,
    List<Color> colors,
  ) {
    if (points.isEmpty) return [];
    final lines = <Polyline>[];
    int start = 0;
    int seg = points.first.segment;
    for (int i = 1; i < points.length; i++) {
      if (points[i].segment != seg) {
        lines.add(Polyline(
          points: points.sublist(start, i).map((t) => t.point).toList(),
          color: colors[seg % colors.length],
          strokeWidth: 3,
        ));
        start = i;
        seg = points[i].segment;
      }
    }
    lines.add(Polyline(
      points: points.sublist(start).map((t) => t.point).toList(),
      color: colors[seg % colors.length],
      strokeWidth: 3,
    ));
    return lines;
  }

  Widget _buildTrackPolyline() {
    return PolylineLayer(
      polylines: _buildSegmentPolylines(_track, _segmentColors),
    );
  }

  List<Marker> _buildTrackLabels() {
    final labels = <Marker>[];
    int prevIdx = 0;
    for (int i = 0; i < _track.length; i++) {
      final t = _track[i];
      final d = _track[i].totalDistance - _track[prevIdx].totalDistance;
      final td = t.time.difference(_track[prevIdx].time);
      if (i > 0 && (d >= 100 || td.inSeconds >= 30 || i == _track.length - 1)) {
        final elapsed = t.time.difference(_track.first.time);
        final dur = _fmtDuration(elapsed.inSeconds);
        final dist = _fmtDistance(t.totalDistance);
        labels.add(Marker(
          point: t.point,
          width: 180,
          height: 32,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.cyanAccent.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$dur  $dist',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ));
        prevIdx = i;
      }
    }
    return labels;
  }

  Widget _buildFabs() {
    if (!_located) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            onPressed: _failed ? _locate : null,
            icon: Icon(_failed ? Icons.refresh : Icons.location_searching),
            label: Text(_failed ? '重试' : '定位中...'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.small(
            heroTag: 'logs',
            onPressed: () => setState(() => _showLogs = !_showLogs),
            backgroundColor: _showLogs ? Colors.green : null,
            child: const Icon(Icons.terminal),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_savedWaypoints.isNotEmpty)
          FloatingActionButton.small(
            heroTag: 'clearSaved',
            onPressed: () => setState(() => _savedWaypoints.clear()),
            backgroundColor: Colors.red.shade800,
            child: const Icon(Icons.layers_clear),
          ),
        if (_savedWaypoints.isNotEmpty) const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'record',
          onPressed: _toggleRecording,
          backgroundColor: _recording ? Colors.red : null,
          child: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'locate',
          onPressed: () {
            if (!_recording) _locate();
          },
          child: const Icon(Icons.my_location),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'waypoint',
          onPressed: () {
            setState(() {
              _waypointMode = !_waypointMode;
              if (!_waypointMode) _waypoints.clear();
            });
          },
          backgroundColor: _waypointMode ? Colors.orange : null,
          child: const Icon(Icons.straighten),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'measure',
          onPressed: () => setState(() {
            _measureMode = !_measureMode;
            _eraserMode = false;
            _dragFrom = null;
          }),
          backgroundColor: _measureMode ? Colors.yellow.shade700 : null,
          child: const Icon(Icons.arrow_right_alt),
        ),
        if (_measureMode) ...[
          const SizedBox(height: 12),
          FloatingActionButton.small(
            heroTag: 'eraser',
            onPressed: () => setState(() => _eraserMode = !_eraserMode),
            backgroundColor: _eraserMode ? Colors.red : null,
            child: const Icon(Icons.auto_fix_high),
          ),
        ],
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'saved',
          onPressed: _showSavedTracksDialog,
          child: const Icon(Icons.folder_open),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'cartographic',
          onPressed: () => setState(() {
            _cartographicMode = !_cartographicMode;
            if (_cartographicMode && _gridOrigin == null && _located) {
              _gridOrigin = _center;
            }
          }),
          backgroundColor: _cartographicMode ? Colors.blueGrey : null,
          child: const Icon(Icons.layers),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'logs',
          onPressed: () => setState(() => _showLogs = !_showLogs),
          backgroundColor: _showLogs ? Colors.green : null,
          child: const Icon(Icons.terminal),
        ),
      ],
    );
  }

  Widget _buildLoadedTrackEndpoints() {
    final pts = _loadedTrack!;
    final start = pts.first;
    final end = pts.last;
    final total = pts.last.totalDistance;
    return MarkerLayer(
      markers: [
        Marker(
          point: start.point,
          width: 120,
          height: 44,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 18),
              Container(
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                width: 14,
                height: 14,
              ),
              _strokeText('起点  ${_fmtDuration(0)}', fill: Colors.green, fontSize: 9),
            ],
          ),
        ),
        Marker(
          point: end.point,
          width: 120,
          height: 44,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 18),
              Container(
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                width: 14,
                height: 14,
              ),
              _strokeText('终点  ${_fmtDistance(total)}', fill: Colors.red, fontSize: 9),
            ],
          ),
        ),
      ],
    );
  }

  double _gridSpacingM() {
    final z = _mapController.camera.zoom;
    if (z >= 20) return 1;
    if (z >= 17) return 10;
    if (z >= 13) return 100;
    if (z >= 10) return 1000;
    if (z >= 6) return 10000;
    return 100000;
  }

  PolylineLayer _buildGridLayer() {
    final camera = _mapController.camera;
    if (camera.zoom < 8) return PolylineLayer(polylines: []);
    final bounds = camera.visibleBounds;
    final spacingM = _gridSpacingM();
    final origin = _gridOrigin;
    final oLat = origin?.latitude ?? 0.0;
    final oLng = origin?.longitude ?? 0.0;
    final latDeg = spacingM / 111320.0;
    final refLat = (camera.center.latitude / latDeg).round() * latDeg;
    final lngDeg = spacingM / (111320.0 * math.cos(refLat * math.pi / 180));

    final lines = <Polyline>[];

    double lat = oLat;
    while (lat >= bounds.south) lat -= latDeg;
    lat += latDeg;
    while (lat <= bounds.north) {
      final distM = ((lat - oLat) * 111320.0).round().abs();
      final major = distM % (spacingM * 10).round() == 0;
      lines.add(Polyline(
        points: [LatLng(lat, bounds.west), LatLng(lat, bounds.east)],
        color: Colors.white30,
        strokeWidth: major ? 2.5 : 1.0,
      ));
      lat += latDeg;
    }

    double lng = oLng;
    while (lng >= bounds.west) lng -= lngDeg;
    lng += lngDeg;
    while (lng <= bounds.east) {
      final distM = ((lng - oLng) * 111320.0 * math.cos(refLat * math.pi / 180)).round().abs();
      final major = distM % (spacingM * 10).round() == 0;
      lines.add(Polyline(
        points: [LatLng(bounds.south, lng), LatLng(bounds.north, lng)],
        color: Colors.white30,
        strokeWidth: major ? 2.5 : 1.0,
      ));
      lng += lngDeg;
    }

    return PolylineLayer(polylines: lines);
  }

  Widget _buildLoadedTrackBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.purple.shade900,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _loadedTrackName ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => setState(() {
                  _loadedTrack = null;
                  _loadedTrackName = null;
                }),
                child: const Icon(Icons.close, color: Colors.white54, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadedTrackPolyline() {
    return PolylineLayer(
      polylines: _buildSegmentPolylines(_loadedTrack!, _loadedSegmentColors),
    );
  }

  List<Marker> _buildLoadedTrackLabels() {
    final pts = _loadedTrack!;
    final labels = <Marker>[];
    int prevIdx = 0;
    for (int i = 0; i < pts.length; i++) {
      final t = pts[i];
      final d = pts[i].totalDistance - pts[prevIdx].totalDistance;
      final td = t.time.difference(pts[prevIdx].time);
      if (i > 0 && (d >= 100 || td.inSeconds >= 30 || i == pts.length - 1)) {
        final elapsed = t.time.difference(pts.first.time);
        final dur = _fmtDuration(elapsed.inSeconds);
        final dist = _fmtDistance(t.totalDistance);
        labels.add(Marker(
          point: t.point,
          width: 120,
          height: 16,
          child: _strokeText(
            '$dur  $dist',
            fill: Colors.purpleAccent,
            fontSize: 10,
          ),
        ));
        prevIdx = i;
      }
    }
    return labels;
  }

  void _showSavedTracksDialog() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Container(
        constraints: const BoxConstraints(maxHeight: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Text('保存的轨迹', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${_savedRecordings.length} 条'),
                ],
              ),
            ),
            if (_savedRecordings.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无保存的轨迹', style: TextStyle(color: Colors.grey)),
              )
            else
              Flexible(
                child: ListView.builder(
                  itemCount: _savedRecordings.length,
                  itemBuilder: (_, i) {
                    final rec = _savedRecordings[i];
                    final isLoaded = _loadedTrackName == rec.name;
                    return ListTile(
                      leading: Icon(
                        Icons.route,
                        color: isLoaded ? Colors.purpleAccent : null,
                      ),
                      title: Text(rec.name, style: TextStyle(fontWeight: isLoaded ? FontWeight.bold : null)),
                      subtitle: Text('${rec.pointCount} 点  ${_fmtDistance(rec.totalDistance)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoaded)
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () {
                                setState(() {
                                  _loadedTrack = null;
                                  _loadedTrackName = null;
                                });
                                Navigator.pop(context);
                              },
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.download, size: 20),
                              onPressed: () {
                                _loadRecording(rec);
                                Navigator.pop(context);
                              },
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () {
                              _deleteRecording(rec);
                              Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 260),
        decoration: const BoxDecoration(
          color: Color(0xE5000000),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text(
                    'LOGS',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _showLogs = false),
                  icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                ),
              ],
            ),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: _logs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                  child: Text(
                    _logs[i],
                    style: TextStyle(
                      color: _logs[i].contains('error') ? Colors.redAccent : Colors.white70,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragCapture() {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          setState(() {
            _dragFrom = _screenLatLng(e.localPosition);
            _dragTo = _dragFrom;
            _dragLastScreen = e.localPosition;
          });
        },
        onPointerMove: (e) {
          if (_dragFrom != null) {
            setState(() {
              _dragLastScreen = e.localPosition;
              _dragTo = _screenLatLng(e.localPosition);
            });
          }
        },
        onPointerUp: (e) {
          if (_dragFrom != null && _dragTo != null && _dragFrom != _dragTo) {
            setState(() {
              _measurements.add(_Measurement(_dragFrom!, _dragTo!));
              _dragFrom = null;
              _dragTo = null;
              _dragLastScreen = null;
            });
          } else {
            setState(() {
              _dragFrom = null;
              _dragTo = null;
              _dragLastScreen = null;
            });
          }
        },
      ),
    );
  }

  LatLng _screenLatLng(Offset screenPos) {
    try {
      final camera = _mapController.camera;
      return camera.screenOffsetToLatLng(screenPos);
    } catch (_) {
      return _center;
    }
  }

  void _eraseMeasurement(LatLng tap) {
    double bestDist = double.infinity;
    int bestIdx = -1;
    for (int i = 0; i < _measurements.length; i++) {
      final m = _measurements[i];
      final dist = _distToSegment(tap, m.from, m.to);
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }
    if (bestDist < 20 && bestIdx >= 0) {
      setState(() => _measurements.removeAt(bestIdx));
    }
  }

  double _distToSegment(LatLng p, LatLng a, LatLng b) {
    final px = p.longitude;
    final py = p.latitude;
    final ax = a.longitude;
    final ay = a.latitude;
    final bx = b.longitude;
    final by = b.latitude;
    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final t = ((apx * abx + apy * aby) / (abx * abx + aby * aby)).clamp(0.0, 1.0);
    final cx = ax + t * abx;
    final cy = ay + t * aby;
    final dx = px - cx;
    final dy = py - cy;
    final distDeg = math.sqrt(dx * dx + dy * dy);
    return distDeg * 111320.0;
  }

  Widget _buildDragPolyline() {
    return PolylineLayer(polylines: _arrowPolylines(_dragFrom!, _dragTo!, Colors.yellow));
  }

  List<Marker> _buildDragLabels() {
    return _arrowLabel(_dragFrom!, _dragTo!, Colors.yellow);
  }

  Widget _buildMeasurementPolyline() {
    final lines = <Polyline>[];
    for (final m in _measurements) {
      lines.addAll(_arrowPolylines(m.from, m.to, Colors.yellowAccent));
    }
    return PolylineLayer(polylines: lines);
  }

  List<Marker> _buildMeasurementLabels() {
    final markers = <Marker>[];
    for (final m in _measurements) {
      markers.addAll(_arrowLabel(m.from, m.to, Colors.yellowAccent));
    }
    return markers;
  }

  List<Polyline> _arrowPolylines(LatLng from, LatLng to, Color color) {
    return [
      Polyline(points: [from, to], color: color, strokeWidth: 2.5),
    ];
  }

  List<Marker> _arrowLabel(LatLng from, LatLng to, Color color) {
    final dist = _distanceCalc.as(LengthUnit.Meter, from, to);
    final bearing = _distanceCalc.bearing(from, to);
    final az = (bearing + 360) % 360;
    final direction = _bearingToCardinal(az);
    final angleRad = bearing * math.pi / 180;
    final cosLat = math.cos(to.latitude * math.pi / 180);
    final backM = 32.0;
    final perpM = 16.0;

    var textRot = angleRad - math.pi / 2;
    if (az > 180) {
      textRot += math.pi;
    }
    final backLng = -math.sin(angleRad) * backM / (111320.0 * cosLat);
    final backLat = -math.cos(angleRad) * backM / 111320.0;
    var perpLng = math.cos(angleRad) * perpM / (111320.0 * cosLat);
    var perpLat = -math.sin(angleRad) * perpM / 111320.0;
    if (perpLat < 0) {
      perpLng = -perpLng;
      perpLat = -perpLat;
    }
    final labelLng = to.longitude + backLng + perpLng;
    final labelLat = to.latitude + backLat + perpLat;

    return [
      Marker(
        point: to,
        width: 18,
        height: 14,
        child: Transform.rotate(
          angle: angleRad,
          child: CustomPaint(
            size: const Size(18, 14),
            painter: _ArrowHeadPainter(color),
          ),
        ),
      ),
      Marker(
        point: LatLng(labelLat, labelLng),
        width: 120,
        height: 16,
        child: Transform.rotate(
          angle: textRot,
          child: _strokeText(
            '${_fmtDistance(dist)}  ${az.toStringAsFixed(1)}°$direction',
            fill: color,
            fontSize: 10,
          ),
        ),
      ),
    ];
  }

  Widget _buildWaypointBar() {
    final totalDist = _waypointTotalDistance();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _recording ? Colors.black87 : Colors.orange.shade900,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.straighten, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                '路  ${_waypoints.length}点',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                _fmtDistance(totalDist),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _waypoints.length >= 2
                    ? () => setState(() {
                          _savedWaypoints.add(List.from(_waypoints));
                          _waypoints.clear();
                        })
                    : null,
                child: Icon(Icons.save,
                    color: _waypoints.length >= 2 ? Colors.white : Colors.white30,
                    size: 20),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => setState(() => _waypoints.removeLast()),
                child: const Icon(Icons.undo, color: Colors.white54, size: 18),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _waypoints.clear()),
                child: const Icon(Icons.delete_outline, color: Colors.white54, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _waypointTotalDistance() {
    double d = 0;
    for (int i = 1; i < _waypoints.length; i++) {
      d += _distanceCalc.as(LengthUnit.Meter, _waypoints[i - 1], _waypoints[i]);
    }
    return d;
  }

  Widget _strokeText(String text, {Color fill = Colors.white, double fontSize = 11}) {
    return Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = Colors.black87,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: fill,
          ),
        ),
      ],
    );
  }

  double _screenDistance(LatLng a, LatLng b) {
    try {
      final camera = _mapController.camera;
      final p1 = camera.latLngToScreenOffset(a);
      final p2 = camera.latLngToScreenOffset(b);
      final dx = p1.dx - p2.dx;
      final dy = p1.dy - p2.dy;
      return math.sqrt(dx * dx + dy * dy);
    } catch (_) {
      return double.infinity;
    }
  }

  Widget _buildWaypointLines() {
    final lines = <Polyline>[];
    for (int i = 1; i < _waypoints.length; i++) {
      lines.add(Polyline(
        points: [_waypoints[i - 1], _waypoints[i]],
        color: i.isOdd ? Colors.orange : Colors.deepOrange,
        strokeWidth: 3,
        pattern: StrokePattern.dotted(),
      ));
    }
    return PolylineLayer(polylines: lines);
  }

  Widget _buildWaypointLayer() {
    final markers = <Marker>[];
    for (int i = 0; i < _waypoints.length; i++) {
      final p = _waypoints[i];
      final tooClose = (i > 0 && _screenDistance(_waypoints[i - 1], p) < 28) ||
          (i < _waypoints.length - 1 && _screenDistance(p, _waypoints[i + 1]) < 28);
      if (tooClose) continue;
      final lat = _toDms(p.latitude, isLat: true);
      final lng = _toDms(p.longitude, isLat: false);
      final color = i == 0 ? Colors.green : Colors.orange;
      markers.add(Marker(
        point: p,
        width: 200,
        height: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
              ),
              width: 24,
              height: 24,
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            _strokeText(lat, fill: color, fontSize: 9),
            _strokeText(lng, fill: color, fontSize: 9),
          ],
        ),
      ));
    }
    return MarkerLayer(markers: markers);
  }

  List<Marker> _buildWaypointLabels() {
    final labels = <Marker>[];
    for (int i = 1; i < _waypoints.length; i++) {
      final p1 = _waypoints[i - 1];
      final p2 = _waypoints[i];

      if (_screenDistance(p1, p2) < 60) continue;

      final dist = _distanceCalc.as(LengthUnit.Meter, p1, p2);
      final bearing = _distanceCalc.bearing(p1, p2);
      final az = (bearing + 360) % 360;
      final direction = _bearingToCardinal(az);

      final mid = LatLng(
        (p1.latitude + p2.latitude) / 2,
        (p1.longitude + p2.longitude) / 2,
      );

      labels.add(Marker(
        point: mid,
        width: 120,
        height: 16,
        child: _strokeText(
          '${_fmtDistance(dist)}  ${az.toStringAsFixed(1)}°${direction.isNotEmpty ? " $direction" : ""}',
        ),
      ));
    }
    return labels;
  }

  String _bearingToCardinal(double degrees) {
    if (degrees >= 337.5 || degrees < 22.5) return 'N';
    if (degrees >= 22.5 && degrees < 67.5) return 'NE';
    if (degrees >= 67.5 && degrees < 112.5) return 'E';
    if (degrees >= 112.5 && degrees < 157.5) return 'SE';
    if (degrees >= 157.5 && degrees < 202.5) return 'S';
    if (degrees >= 202.5 && degrees < 247.5) return 'SW';
    if (degrees >= 247.5 && degrees < 292.5) return 'W';
    if (degrees >= 292.5 && degrees < 337.5) return 'NW';
    return '';
  }

  Widget _buildSavedWaypointLines(int si) {
    final pts = _savedWaypoints[si];
    final lines = <Polyline>[];
    for (int i = 1; i < pts.length; i++) {
      lines.add(Polyline(
        points: [pts[i - 1], pts[i]],
        color: Colors.tealAccent,
        strokeWidth: 3,
        pattern: StrokePattern.dotted(),
      ));
    }
    return PolylineLayer(polylines: lines);
  }

  Widget _buildSavedWaypointLayer(int si) {
    final pts = _savedWaypoints[si];
    final markers = <Marker>[];
    for (int i = 0; i < pts.length; i++) {
      final tooClose = (i > 0 && _screenDistance(pts[i - 1], pts[i]) < 28) ||
          (i < pts.length - 1 && _screenDistance(pts[i], pts[i + 1]) < 28);
      if (tooClose) continue;
      final lat = _toDms(pts[i].latitude, isLat: true);
      final lng = _toDms(pts[i].longitude, isLat: false);
      markers.add(Marker(
        point: pts[i],
        width: 200,
        height: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: Colors.teal,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
              ),
              width: 24,
              height: 24,
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            _strokeText(lat, fill: Colors.teal, fontSize: 9),
            _strokeText(lng, fill: Colors.teal, fontSize: 9),
          ],
        ),
      ));
    }
    return MarkerLayer(markers: markers);
  }

  List<Marker> _buildSavedWaypointLabels(int si) {
    final pts = _savedWaypoints[si];
    final labels = <Marker>[];
    for (int i = 1; i < pts.length; i++) {
      final p1 = pts[i - 1];
      final p2 = pts[i];

      if (_screenDistance(p1, p2) < 60) continue;

      final dist = _distanceCalc.as(LengthUnit.Meter, p1, p2);
      final bearing = _distanceCalc.bearing(p1, p2);
      final az = (bearing + 360) % 360;
      final direction = _bearingToCardinal(az);
      final mid = LatLng(
        (p1.latitude + p2.latitude) / 2,
        (p1.longitude + p2.longitude) / 2,
      );
      labels.add(Marker(
        point: mid,
        width: 120,
        height: 16,
        child: _strokeText(
          '${_fmtDistance(dist)}  ${az.toStringAsFixed(1)}°${direction.isNotEmpty ? " $direction" : ""}',
        ),
      ));
    }
    return labels;
  }

  Widget _buildLocationMarker() {
    final lat = _toDms(_center.latitude, isLat: true);
    final lng = _toDms(_center.longitude, isLat: false);

    return MarkerLayer(
      markers: [
        Marker(
          point: _center,
          width: 220,
          height: 70,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 26),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueAccent,
                ),
                width: 16,
                height: 16,
                child: const Center(
                  child: Icon(Icons.circle, size: 8, color: Colors.white),
                ),
              ),
              _strokeText(lat, fill: Colors.blueAccent, fontSize: 11),
              _strokeText(lng, fill: Colors.blueAccent, fontSize: 11),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArrowHeadPainter extends CustomPainter {
  final Color color;
  _ArrowHeadPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(0, size.height)
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
