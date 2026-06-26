import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';

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

  const _TrackPoint(this.point, this.time, this.totalDistance);
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
  Timer? _timer;
  StreamSubscription<Position>? _posSub;

  bool _surveyMode = false;
  final _surveyPoints = <LatLng>[];
  final _savedSurveys = <List<LatLng>>[];
  int _cameraVersion = 0;

  final _distanceCalc = const Distance();

  final _logs = <String>[];
  bool _showLogs = false;

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
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: const Duration(seconds: 15),
          forceLocationManager: true,
        ),
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

  void _startRecording() {
    _track.clear();
    _elapsedSeconds = 0;

    final now = DateTime.now();
    _track.add(_TrackPoint(_center, now, 0));

    _posSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2,
        forceLocationManager: true,
      ),
    ).listen((pos) {
      if (!mounted) return;
      final p = LatLng(pos.latitude, pos.longitude);
      final last = _track.last;
      final d = _distanceCalc.as(LengthUnit.Meter, last.point, p);
      final total = last.totalDistance + d;
      setState(() {
        _track.add(_TrackPoint(p, pos.timestamp, total));
      });
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
              onTap: _surveyMode
                  ? (tapPos, latlng) {
                      setState(() => _surveyPoints.add(latlng));
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
              TileLayer(
                urlTemplate:
                    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
              ),
              if (_located) _buildLocationMarker(),
              if (_track.length >= 2) _buildTrackPolyline(),
              if (_track.length >= 2) MarkerLayer(markers: _buildTrackLabels()),
              if (_surveyPoints.length >= 2) _buildSurveyLines(),
              if (_surveyPoints.length >= 2) MarkerLayer(markers: _buildSurveyLabels()),
              if (_surveyPoints.isNotEmpty) _buildSurveyPointsLayer(),
              for (int s = 0; s < _savedSurveys.length; s++) ...[
                _buildSavedSurveyLines(s),
                MarkerLayer(markers: _buildSavedSurveyLabels(s)),
                _buildSavedSurveyPointsLayer(s),
              ],
            ],
          ),
          if (_recording) _buildTimerBar(),
          if (_surveyMode) _buildSurveyBar(),
          if (!_located) const Center(child: CircularProgressIndicator()),
          if (_showLogs) _buildLogPanel(),
        ],
      ),
      floatingActionButton: _buildFabs(),
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

  Widget _buildTrackPolyline() {
    return PolylineLayer(
      polylines: [
        Polyline(
          points: _track.map((t) => t.point).toList(),
          color: Colors.cyanAccent,
          strokeWidth: 3,
        ),
      ],
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
        if (_savedSurveys.isNotEmpty)
          FloatingActionButton.small(
            heroTag: 'clearSaved',
            onPressed: () => setState(() => _savedSurveys.clear()),
            backgroundColor: Colors.red.shade800,
            child: const Icon(Icons.layers_clear),
          ),
        if (_savedSurveys.isNotEmpty) const SizedBox(height: 12),
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
          heroTag: 'survey',
          onPressed: () {
            setState(() {
              _surveyMode = !_surveyMode;
              if (!_surveyMode) _surveyPoints.clear();
            });
          },
          backgroundColor: _surveyMode ? Colors.orange : null,
          child: const Icon(Icons.straighten),
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

  Widget _buildSurveyBar() {
    final totalDist = _surveyTotalDistance();
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
                '测  ${_surveyPoints.length}点',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                _fmtDistance(totalDist),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _surveyPoints.length >= 2
                    ? () => setState(() {
                          _savedSurveys.add(List.from(_surveyPoints));
                          _surveyPoints.clear();
                        })
                    : null,
                child: Icon(Icons.save,
                    color: _surveyPoints.length >= 2 ? Colors.white : Colors.white30,
                    size: 20),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => setState(() => _surveyPoints.removeLast()),
                child: const Icon(Icons.undo, color: Colors.white54, size: 18),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _surveyPoints.clear()),
                child: const Icon(Icons.delete_outline, color: Colors.white54, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _surveyTotalDistance() {
    double d = 0;
    for (int i = 1; i < _surveyPoints.length; i++) {
      d += _distanceCalc.as(LengthUnit.Meter, _surveyPoints[i - 1], _surveyPoints[i]);
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

  Widget _buildSurveyLines() {
    final lines = <Polyline>[];
    for (int i = 1; i < _surveyPoints.length; i++) {
      lines.add(Polyline(
        points: [_surveyPoints[i - 1], _surveyPoints[i]],
        color: i.isOdd ? Colors.orange : Colors.deepOrange,
        strokeWidth: 3,
        pattern: StrokePattern.dotted(),
      ));
    }
    return PolylineLayer(polylines: lines);
  }

  Widget _buildSurveyPointsLayer() {
    final markers = <Marker>[];
    for (int i = 0; i < _surveyPoints.length; i++) {
      final p = _surveyPoints[i];
      final tooClose = (i > 0 && _screenDistance(_surveyPoints[i - 1], p) < 28) ||
          (i < _surveyPoints.length - 1 && _screenDistance(p, _surveyPoints[i + 1]) < 28);
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

  List<Marker> _buildSurveyLabels() {
    final labels = <Marker>[];
    for (int i = 1; i < _surveyPoints.length; i++) {
      final p1 = _surveyPoints[i - 1];
      final p2 = _surveyPoints[i];

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

  Widget _buildSavedSurveyLines(int si) {
    final pts = _savedSurveys[si];
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

  Widget _buildSavedSurveyPointsLayer(int si) {
    final pts = _savedSurveys[si];
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

  List<Marker> _buildSavedSurveyLabels(int si) {
    final pts = _savedSurveys[si];
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
