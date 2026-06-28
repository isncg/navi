import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_device_compass/flutter_device_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';

import 'common.dart';
import 'painters.dart';
import 'tiles.dart';
import 'track_io.dart';

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
  double _heading = -1;
  StreamSubscription<CompassEvent>? _compassSub;

  bool _recording = false;
  final _track = <TrackPoint>[];
  int _elapsedSeconds = 0;
  int _currentSegment = 0;
  Timer? _timer;
  Timer? _autoSaveTimer;
  Timer? _safetyTimer;
  late final TrackStorage _trackStorage;
  DateTime? _lastBackPress;
  bool _showExitTip = false;
  Timer? _exitTipTimer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<Position>? _locSub;

  bool _waypointMode = false;
  final _waypoints = <Waypoint>[];
  final _savedWaypoints = <List<Waypoint>>[];
  int _cameraVersion = 0;
  int _editingWaypointIndex = -1;
  int _editingSavedSetIndex = -1;
  int _editingSavedIndex = -1;
  final _editController = TextEditingController();

  List<TrackPoint>? _loadedTrack;
  String? _loadedTrackName;

  final _distanceCalc = const Distance();

  final _logs = <String>[];
  bool _showLogs = false;
  bool _cartographicMode = false;
  LatLng? _gridOrigin;
  bool _showCoordinates = false;

  bool _measureMode = false;
  bool _eraserMode = false;
  final _measurements = <Measurement>[];
  bool _measuring = false;
  LatLng? _measureStart;

  bool _downloading = false;
  int _downloadProgress = 0;
  int _downloadTotal = 0;
  bool _downloadCancel = false;
  Directory? _cacheDir;
  int _tileSourceIndex = 0;

  bool _debugSim = false;
  Timer? _simTimer;
  LatLng? _simPos;

  void _log(String msg, {Object? error}) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final text = '[$ts] $msg${error != null ? ' $error' : ''}';
    dev.log(msg, name: 'Navi', error: error);
    if (!mounted) return;
    setState(() {
      _logs.add(text);
      while (_logs.length > 200) {
        _logs.removeAt(0);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _trackStorage = TrackStorage(_distanceCalc, _log, () => mounted);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _log('App started');
    _locate();
    _trackStorage.loadSavedRecordings();
    _trackStorage.checkAutoSaveRecovery();
    _initCacheDir();
    _safetyTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && !_located && !_failed) {
        _log('Location safety timeout: forcing failed');
        setState(() => _failed = true);
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _locSub?.cancel();
    _timer?.cancel();
    _autoSaveTimer?.cancel();
    _simTimer?.cancel();
    _safetyTimer?.cancel();
    _exitTipTimer?.cancel();
    _compassSub?.cancel();
    _editController.dispose();
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
      perm = await Geolocator.requestPermission().timeout(const Duration(seconds: 10));
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
      ).timeout(const Duration(seconds: 15));
      _log('Position: ${position.latitude}, ${position.longitude} accuracy=${position.accuracy}m');
      if (!mounted) return;
      setState(() {
        _center = LatLng(position.latitude, position.longitude);
        _located = true;
      });
      _moveToCurrent();
      _startLocationUpdates();
      _startCompass();
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

  void _startLocationUpdates() {
    _locSub?.cancel();
    _locSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(distanceFilter: 5, streaming: true),
    ).listen((pos) {
      if (!mounted || _recording) return;
      setState(() {
        _center = LatLng(pos.latitude, pos.longitude);
      });
    });
  }

  void _startCompass() {
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      if (event.heading != null) {
        setState(() => _heading = event.heading!);
      }
    });
  }

  void _stopLocationUpdates() {
    _locSub?.cancel();
    _locSub = null;
  }

  void _toggleDebugSim() {
    setState(() {
      _debugSim = !_debugSim;
      if (!_debugSim) {
        _simTimer?.cancel();
        _simTimer = null;
        _simPos = null;
      } else {
        _simPos = _center;
        _startSimTimer();
      }
    });
  }

  void _startSimTimer() {
    _simTimer?.cancel();
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_debugSim) return;
      final lat = _simPos!.latitude;
      final lng = _simPos!.longitude + 5.0 / (111320.0 * math.cos(lat * math.pi / 180));
      _simPos = LatLng(lat, lng);
      if (_recording) {
        final now = DateTime.now();
        final last = _track.last;
        final d = _distanceCalc.as(LengthUnit.Meter, last.point, _simPos!);
        final total = last.totalDistance + d;
        setState(() {
          _track.add(TrackPoint(_simPos!, now, total, segment: _currentSegment));
        });
      }
      setState(() {
        _center = _simPos!;
        if (!_recording) _located = true;
      });
    });
  }

  void _toggleRecording() {
    if (_recording) {
      _stopRecording();
    } else {
      _startRecording();
    }
  }

  LocationSettings _locationSettings({int distanceFilter = 0, bool streaming = false, bool foreground = false}) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
        forceLocationManager: true,
        timeLimit: streaming ? null : const Duration(seconds: 15),
        foregroundNotificationConfig: foreground
            ? const ForegroundNotificationConfig(
                notificationText: 'Navi 正在记录轨迹',
                notificationTitle: '跟踪记录中',
                enableWifiLock: true,
              )
            : null,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: distanceFilter,
      timeLimit: streaming ? null : const Duration(seconds: 15),
    );
  }

  void _startRecording() {
    _stopLocationUpdates();
    _track.clear();
    _elapsedSeconds = 0;
    _currentSegment = 0;

    if (_debugSim) {
      final now = DateTime.now();
      _track.add(TrackPoint(_center, now, 0));
      _startSimTimer();
    } else {
      _posSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(distanceFilter: 2, streaming: true, foreground: true),
    ).listen((pos) {
      if (!mounted) return;
      try {
        final p = LatLng(pos.latitude, pos.longitude);
        if (_track.isEmpty) {
          setState(() {
            _track.add(TrackPoint(p, DateTime.now(), 0, segment: _currentSegment));
          });
          return;
        }
        final last = _track.last;
        final d = _distanceCalc.as(LengthUnit.Meter, last.point, p);
        final total = last.totalDistance + d;
        final gap = pos.timestamp.difference(last.time);
        if (gap.inSeconds > 10 || d > 1000) {
          _currentSegment++;
          _log('GPS gap detected, new segment $_currentSegment');
        }
        setState(() {
          _track.add(TrackPoint(p, pos.timestamp, total, segment: _currentSegment));
        });
      } catch (e) {
        _log('Stream position error', error: e);
      }
    }, onError: (e) {
      _log('Stream error', error: e);
    });
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });

    _autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || !_recording || _track.length < 2) return;
      _trackStorage.autoSaveNow(_track);
    });

    setState(() => _recording = true);
  }

  void _stopRecording() {
    _posSub?.cancel();
    _posSub = null;
    _timer?.cancel();
    _timer = null;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _simTimer?.cancel();
    setState(() => _recording = false);
    _startLocationUpdates();
    if (_track.length >= 2) _trackStorage.saveRecording(_track);
    _trackStorage.deleteAutoSave();
  }

  Future<void> _initCacheDir() async {
    _cacheDir = await initTileCacheDir(_tileSourceIndex);
  }

  Future<void> _switchTileSource(int index) async {
    if (index == _tileSourceIndex) return;
    _cancelDownload();
    setState(() => _tileSourceIndex = index);
    _cacheDir = await initTileCacheDir(index);
  }

  Future<void> _startDownload() async {
    if (_downloading) return;
    setState(() { _downloading = true; _downloadCancel = false; _downloadProgress = 0; _downloadTotal = 0; });
    final center = _mapController.camera.center;
    final zoom = _mapController.camera.zoom.round();
    final (_, urlTemplate, subdomains) = tileSources[_tileSourceIndex];
    final allTasks = computeTileCoords(center.latitude, center.longitude, zoom, 1000.0);
    final tasks = <TileCoord>[];
    for (final t in allTasks) {
      if (!File(tileCachePath(_cacheDir!, t.z, t.x, t.y)).existsSync()) tasks.add(t);
    }
    if (tasks.isEmpty) {
      _log('下载结束: 0/0 张 (全部已缓存)');
      if (mounted) setState(() { _downloading = false; });
      return;
    }
    _downloadTotal = tasks.length;
    int failed = 0;
    final retryList = <TileCoord>[];
    for (int i = 0; i < tasks.length; i++) {
      if (_downloadCancel) break;
      final ok = await downloadTile(_cacheDir!, urlTemplate, subdomains, tasks[i].z, tasks[i].x, tasks[i].y);
      if (!ok) { failed++; retryList.add(tasks[i]); }
      if (mounted) setState(() => _downloadProgress = i + 1);
    }
    if (!_downloadCancel && retryList.isNotEmpty) {
      for (final t in retryList) {
        if (_downloadCancel) break;
        final ok = await downloadTile(_cacheDir!, urlTemplate, subdomains, t.z, t.x, t.y);
        if (ok) failed--;
      }
    }
    final total = tasks.length;
    if (mounted) {
      setState(() { _downloading = false; _downloadProgress = 0; _downloadTotal = 0; });
      _log('下载结束: ${total - failed}/$total 张 (失败 $failed 张)');
    }
  }

  void _cancelDownload() => setState(() => _downloadCancel = true);

  Future<void> _loadRecording(SavedRecording rec) async {
    final pts = await _trackStorage.loadRecording(rec);
    if (mounted && pts.isNotEmpty) {
      setState(() { _loadedTrack = pts; _loadedTrackName = rec.name; });
      _log('Loaded track: ${rec.name}');
    }
  }

  Future<void> _deleteRecording(SavedRecording rec) async {
    await _trackStorage.deleteRecording(rec);
    if (_loadedTrackName == rec.name) {
      setState(() { _loadedTrack = null; _loadedTrackName = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = (_waypointMode && _editingWaypointIndex >= 0) || _editingSavedSetIndex >= 0;
    return Stack(
      children: [
        PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 3)) {
          SystemNavigator.pop();
          return;
        }
        _lastBackPress = now;
        _exitTipTimer?.cancel();
        setState(() => _showExitTip = true);
        _exitTipTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showExitTip = false);
        });
      },
      child: Scaffold(
      body: Stack(
        children: [
          if (_located || _failed)
            FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              backgroundColor: Colors.black87,
              initialCenter: _center,
              initialZoom: _located ? 18 : (_failed ? 2 : 16),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: _eraserMode
                  ? (tapPos, latlng) {
                      _eraseMeasurement(latlng);
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
                    0.15, 0.45, 0.06, 0, 28,
                    0.15, 0.45, 0.06, 0, 34,
                    0.16, 0.48, 0.07, 0, 42,
                    0,    0,    0,    1, 0,
                  ]),
                  child: _buildTileLayer(),
                )
              else
                _buildTileLayer(),
              if (_cartographicMode) _buildGridLayer(),
              if (_located && !_recording) _buildLocationMarker(),
              if (_track.length >= 2) _buildTrackPolyline(),
              if (_track.length >= 2) MarkerLayer(markers: _buildTrackLabels()),
              if (_loadedTrack != null && _loadedTrack!.length >= 2) ...[
                _buildLoadedTrackPolyline(),
                MarkerLayer(markers: _buildLoadedTrackLabels()),
                if (_loadedTrack!.isNotEmpty) _buildLoadedTrackEndpoints(),
              ],
              if (_waypoints.length >= 2) _buildWaypointLines(),
              if (_waypointMode && _waypoints.isNotEmpty) _buildWaypointPreview(),
              if (_waypoints.length >= 2) MarkerLayer(markers: _buildWaypointLabels()),
              if (_waypoints.isNotEmpty) _buildWaypointLayer(),
              if (_measurements.isNotEmpty) _buildMeasurementPolyline(),
              if (_measurements.isNotEmpty) MarkerLayer(markers: _buildMeasurementLabels()),
              if (_measuring && _measureStart != null && _measureStart != _mapController.camera.center) ...[
                _buildDrawArrowPolyline(),
                MarkerLayer(markers: _buildDrawArrowLabels()),
              ],
              for (int s = 0; s < _savedWaypoints.length; s++) ...[
                _buildSavedWaypointLines(s),
                MarkerLayer(markers: _buildSavedWaypointLabels(s)),
                _buildSavedWaypointLayer(s),
              ],
            ],
          )
          else
            const SizedBox.expand(child: Center(child: CircularProgressIndicator())),
              if (_recording || _waypointMode) _buildBottomBar(),
          if (_downloading) _buildDownloadProgress(),
          if (_loadedTrack != null) _buildLoadedTrackBar(),
          if (_cartographicMode) _buildZoomLabel(),

          if (_showLogs) _buildLogPanel(),
          if (_measureMode || _waypointMode)
            Stack(
              children: [
                _buildCrosshair(),
                Positioned(
                  top: MediaQuery.of(context).size.height / 2 + 24,
                  left: 0,
                  right: 0,
                  child: _buildCrosshairLabels(),
                ),
              ],
            ),
          _buildLeftButtons(),
          IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _showExitTip ? 0.85 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '再按一次退出',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _buildFabs(),
        ),
      ),
      if (editing) _buildWaypointEditPanel(),
    ],
    );
  }

  Widget _buildWaypointEditPanel() {
    final isSaved = _editingSavedSetIndex >= 0;
    final wp = isSaved
        ? _savedWaypoints[_editingSavedSetIndex][_editingSavedIndex]
        : _waypoints[_editingWaypointIndex];
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final size = MediaQuery.of(context).size;
    if (_editController.text != wp.name) {
      _editController.text = wp.name;
    }

    void close() => setState(() {
          _editingWaypointIndex = -1;
          _editingSavedSetIndex = -1;
          _editingSavedIndex = -1;
        });

    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(onTap: close, behavior: HitTestBehavior.translucent),
          Positioned(
            top: isLandscape ? 0 : null,
            bottom: isLandscape ? 0 : null,
            right: isLandscape ? 0 : null,
            left: isLandscape ? null : 0,
            child: SafeArea(
              child: Container(
                width: isLandscape ? size.width * 0.25 : size.width,
                height: isLandscape ? size.height : size.height * 0.25,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                margin: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isSaved ? '已保存路径点 ${_editingSavedIndex + 1}' : '路径点 ${_editingWaypointIndex + 1}',
                          style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _editController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          hintText: '名称',
                          hintStyle: TextStyle(color: Colors.white30),
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          isDense: true,
                        ),
                        onChanged: (v) {
                          final updated = wp.copyWith(name: v);
                          if (isSaved) {
                            _savedWaypoints[_editingSavedSetIndex][_editingSavedIndex] = updated;
                          } else {
                            _waypoints[_editingWaypointIndex] = updated;
                          }
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        height: 32,
                        child: ElevatedButton(
                          onPressed: _waypointMode
                              ? () => setState(() {
                                    final moved = wp.copyWith(point: _mapController.camera.center);
                                    if (isSaved) {
                                      _savedWaypoints[_editingSavedSetIndex][_editingSavedIndex] = moved;
                                    } else {
                                      _waypoints[_editingWaypointIndex] = moved;
                                    }
                                  })
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            padding: EdgeInsets.zero,
                          ),
                          child: const Text('十字准星定位', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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

  Widget _buildBottomBar() {
    final parts = <Widget>[];
    if (_recording) {
      final dist = _track.isNotEmpty ? _track.last.totalDistance : 0.0;
      parts.add(Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
      ));
      parts.add(const SizedBox(width: 8));
      parts.add(Text(
        '${fmtDuration(_elapsedSeconds)}  ${fmtDistance(dist)}',
        style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
      ));
    }
    if (_recording && _waypointMode) {
      parts.add(const SizedBox(width: 24));
      parts.add(Container(width: 1, height: 16, color: Colors.white24));
      parts.add(const SizedBox(width: 24));
    }
    if (_waypointMode) {
      final totalDist = _waypointTotalDistance();
      parts.add(Text(
        '${_waypoints.length}点  ${fmtDistance(totalDist)}',
        style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace'),
      ));
    }
    return Positioned(
      bottom: 12,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: parts,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackPolyline() {
    final simplified = _simplifyTrack(_track);
    return PolylineLayer(
      polylines: [
        Polyline(
          points: simplified.map((t) => t.point).toList(),
          color: Colors.yellowAccent,
          strokeWidth: 3,
        ),
      ],
    );
  }

  List<TrackPoint> _simplifyTrack(List<TrackPoint> pts) {
    if (pts.length <= 500) return pts;
    final step = pts.length ~/ 500;
    final result = <TrackPoint>[pts.first];
    for (int i = 1; i < pts.length - 1; i++) {
      if (i % step == 0) result.add(pts[i]);
    }
    result.add(pts.last);
    return result;
  }

  List<Marker> _buildTrackLabels() {
    final labels = <Marker>[];
    final zoom = _mapController.camera.zoom;
    if (zoom < 12) return labels;
    final pts = _simplifyTrack(_track);
    int prevIdx = 0;
    LatLng? prevLabelPoint;
    for (int i = 0; i < pts.length; i++) {
      final t = pts[i];
      final d = pts[i].totalDistance - pts[prevIdx].totalDistance;
      final td = t.time.difference(pts[prevIdx].time);
      if (i == 0 || (d >= 100 || td.inSeconds >= 30 || i == pts.length - 1)) {
        if (prevLabelPoint != null && _screenDistance(prevLabelPoint, t.point) < 80 && i != pts.length - 1) {
          prevIdx = i;
          continue;
        }
        final dur = fmtTime(t.time);
        final dist = fmtDistance(t.totalDistance);
        labels.add(Marker(
          point: t.point,
          width: 140,
          height: 16,
          child: strokeText(
            '$dur  $dist',
            fill: Colors.yellowAccent,
            fontSize: 10,
          ),
        ));
        prevIdx = i;
        prevLabelPoint = t.point;
      }
    }
    return labels;
  }

  Widget _buildFabs() {
    if (!_located && !_failed) {
      final children = <Widget>[
        FloatingActionButton.extended(
          onPressed: null,
          icon: const Icon(Icons.location_searching),
          label: const Text('定位中...'),
        ),
      ];
      return Column(mainAxisSize: MainAxisSize.min, children: _addSpacing(children, false));
    }

    final buttons = <Widget>[];
    if (_waypointMode) {
      if (_savedWaypoints.isNotEmpty) {
        buttons.add(FloatingActionButton.small(
          heroTag: 'clearSaved',
          onPressed: () => setState(() {
            _editingSavedSetIndex = -1;
            _editingSavedIndex = -1;
            _savedWaypoints.clear();
          }),
          backgroundColor: Colors.red.shade800,
          child: const Icon(Icons.layers_clear),
        ));
      }
      if (_waypoints.isNotEmpty) {
        buttons.add(FloatingActionButton.small(
          heroTag: 'undoWaypoint',
          onPressed: () => setState(() => _waypoints.removeLast()),
          child: const Icon(Icons.undo),
        ));
      }
      buttons.add(FloatingActionButton.small(
        heroTag: 'addWaypoint',
          onPressed: () => setState(() => _waypoints.add(Waypoint(_mapController.camera.center))),
        backgroundColor: Colors.orange,
        child: const Icon(Icons.add_location),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'saveWaypoints',
        onPressed: _waypoints.length >= 2
            ? () => setState(() {
                  _editingWaypointIndex = -1;
                  _savedWaypoints.add(List.from(_waypoints));
                  _waypoints.clear();
                })
            : null,
        backgroundColor: _waypoints.length >= 2 ? Colors.green : null,
        child: const Icon(Icons.save),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'waypoint',
        onPressed: () {
          setState(() {
            _waypointMode = !_waypointMode;
            if (!_waypointMode) { _editingWaypointIndex = -1; _waypoints.clear(); }
          });
        },
        backgroundColor: _waypointMode ? Colors.red : null,
        child: Icon(_waypointMode ? Icons.close : Icons.route),
      ));
    } else if (_measureMode) {
      buttons.add(FloatingActionButton.small(
        heroTag: 'drawArrow',
        onPressed: () => setState(() {
          if (_measuring) {
            final center = _mapController.camera.center;
            if (_measureStart != center) {
              _measurements.add(Measurement(_measureStart!, center));
            }
            _measuring = false;
            _measureStart = null;
          } else {
            _measuring = true;
            _measureStart = _mapController.camera.center;
          }
        }),
        backgroundColor: _measuring ? Colors.orange : null,
        child: Icon(_measuring ? Icons.check : Icons.draw),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'eraser',
        onPressed: () => setState(() => _eraserMode = !_eraserMode),
        backgroundColor: _eraserMode ? Colors.red : null,
        child: const Icon(Icons.auto_fix_high),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'measure',
        onPressed: () => setState(() {
          _measureMode = !_measureMode;
          _eraserMode = false;
          _measuring = false;
          _measureStart = null;
        }),
        backgroundColor: _measureMode ? Colors.red : null,
        child: Icon(_measureMode ? Icons.close : Icons.straighten),
      ));
    } else {
      buttons.add(FloatingActionButton.small(
        heroTag: 'record',
        onPressed: _toggleRecording,
        backgroundColor: _recording ? Colors.red : null,
        child: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'locate',
        onPressed: () { if (!_recording) _locate(); },
        child: const Icon(Icons.my_location),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'waypoint',
        onPressed: () {
          setState(() {
            _waypointMode = !_waypointMode;
            if (!_waypointMode) { _editingWaypointIndex = -1; _waypoints.clear(); }
          });
        },
        backgroundColor: _waypointMode ? Colors.orange : null,
        child: const Icon(Icons.route),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'measure',
        onPressed: () => setState(() {
          _measureMode = !_measureMode;
          _eraserMode = false;
          _measuring = false;
          _measureStart = null;
        }),
        backgroundColor: _measureMode ? Colors.yellow.shade700 : null,
        child: const Icon(Icons.straighten),
      ));
      buttons.add(FloatingActionButton.small(
        heroTag: 'saved',
        onPressed: _showSavedTracksDialog,
        child: const Icon(Icons.folder_open),
      ));
    }
    final spaced = _addSpacing(buttons, false);
    return Column(mainAxisSize: MainAxisSize.min, children: spaced);
  }

  Widget _buildLeftButtons() {
    final buttons = <Widget>[
      FloatingActionButton.small(
        heroTag: 'cartographic',
        onPressed: () => setState(() {
          _cartographicMode = !_cartographicMode;
          if (_cartographicMode && _gridOrigin == null && _located) _gridOrigin = _center;
        }),
        backgroundColor: _cartographicMode ? Colors.blueGrey : null,
        child: const Icon(Icons.layers),
      ),
      FloatingActionButton.small(
        heroTag: 'orientation',
        onPressed: () {
          final land = MediaQuery.of(context).orientation == Orientation.landscape;
          SystemChrome.setPreferredOrientations(land
              ? [DeviceOrientation.portraitUp]
              : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        },
        child: const Icon(Icons.screen_rotation),
      ),
      FloatingActionButton.small(
        heroTag: 'download',
        onPressed: _downloading ? _cancelDownload : _startDownload,
        backgroundColor: _downloading ? Colors.red : null,
        child: Icon(_downloading ? Icons.stop : Icons.download),
      ),
      FloatingActionButton.small(
        heroTag: 'logs',
        onPressed: () => setState(() => _showLogs = !_showLogs),
        backgroundColor: _showLogs ? Colors.green : null,
        child: const Icon(Icons.terminal),
      ),
      FloatingActionButton.small(
        heroTag: 'coords',
        onPressed: () => setState(() => _showCoordinates = !_showCoordinates),
        backgroundColor: _showCoordinates ? Colors.blue : null,
        child: const Icon(Icons.pin_drop),
      ),
      FloatingActionButton.small(
        heroTag: 'tiles',
        onPressed: _showTileSourceDialog,
        child: const Icon(Icons.map),
      ),
      if (_showLogs) FloatingActionButton.small(
        heroTag: 'debugSim',
        onPressed: _toggleDebugSim,
        backgroundColor: _debugSim ? Colors.purple : null,
        child: Icon(_debugSim ? Icons.directions_walk : Icons.satellite_alt),
      ),
    ];
    final spaced = _addSpacing(buttons, false);
    return Positioned(
      bottom: 0,
      left: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: spaced),
        ),
      ),
    );
  }

  List<Widget> _addSpacing(List<Widget> items, bool horizontal) {
    final result = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      result.add(items[i]);
      if (i < items.length - 1) result.add(horizontal ? const SizedBox(width: 12) : const SizedBox(height: 12));
    }
    return result;
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
              strokeText('起点  ${fmtDuration(0)}', fill: Colors.green, fontSize: 9),
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
              strokeText('终点  ${fmtDistance(total)}', fill: Colors.red, fontSize: 9),
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
    while (lat >= bounds.south) {
      lat -= latDeg;
    }
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
    while (lng >= bounds.west) {
      lng -= lngDeg;
    }
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

    return PolylineLayer(polylines: lines    );
  }

  TileLayer _buildTileLayer() {
    final (_, urlTemplate, subdomains) = tileSources[_tileSourceIndex];
    return TileLayer(
      urlTemplate: urlTemplate,
      subdomains: subdomains,
      evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
    );
  }

  Widget _buildDownloadProgress() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.download, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              Text(
                '${(_downloadProgress / _downloadTotal * 100).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 8),
              Text(
                '$_downloadProgress / $_downloadTotal',
                style: const TextStyle(color: Colors.white54, fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
    );
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
      polylines: buildSegmentPolylines(_loadedTrack!, loadedSegmentColors),
    );
  }

  List<Marker> _buildLoadedTrackLabels() {
    final pts = _loadedTrack!;
    final labels = <Marker>[];
    final zoom = _mapController.camera.zoom;
    int prevIdx = 0;
    LatLng? prevLabelPoint;
    for (int i = 0; i < pts.length; i++) {
      final t = pts[i];
      final d = pts[i].totalDistance - pts[prevIdx].totalDistance;
      final td = t.time.difference(pts[prevIdx].time);
      if (i == 0 || (d >= 100 || td.inSeconds >= 30 || i == pts.length - 1)) {
        if (zoom < 12 && i != pts.length - 1) {
          prevIdx = i;
          continue;
        }
        if (prevLabelPoint != null && _screenDistance(prevLabelPoint, t.point) < 80 && i != pts.length - 1) {
          prevIdx = i;
          continue;
        }
        final dur = fmtTime(t.time);
        final dist = fmtDistance(t.totalDistance);
        labels.add(Marker(
          point: t.point,
          width: 120,
          height: 16,
          child: strokeText(
            '$dur  $dist',
            fill: Colors.purpleAccent,
            fontSize: 10,
          ),
        ));
        prevIdx = i;
        prevLabelPoint = t.point;
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
                  Text('${_trackStorage.savedRecordings.length} 条'),
                ],
              ),
            ),
            if (_trackStorage.savedRecordings.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无保存的轨迹', style: TextStyle(color: Colors.grey)),
              )
            else
              Flexible(
                child: ListView.builder(
                  itemCount: _trackStorage.savedRecordings.length,
                  itemBuilder: (_, i) {
                    final rec = _trackStorage.savedRecordings[i];
                    final isLoaded = _loadedTrackName == rec.name;
                    return ListTile(
                      leading: Icon(
                        Icons.route,
                        color: isLoaded ? Colors.purpleAccent : null,
                      ),
                      title: Text(rec.name, style: TextStyle(fontWeight: isLoaded ? FontWeight.bold : null)),
                      subtitle: Text('${rec.pointCount} 点  ${fmtDistance(rec.totalDistance)}'),
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

  void _showTileSourceDialog() {
    int selected = _tileSourceIndex;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('地图源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < tileSources.length; i++)
                ListTile(
                  title: Text(tileSources[i].$1),
                  leading: Icon(selected == i ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  onTap: () {
                    setDialogState(() => selected = i);
                    _switchTileSource(i);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogPanel() {
    return Positioned(
      top: 0,
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

  Widget _buildCrosshair() {
    return IgnorePointer(
      child: Center(
        child: CustomPaint(
          size: const Size(40, 40),
          painter: CrosshairPainter(color: _measuring ? Colors.yellow : Colors.white),
        ),
      ),
    );
  }

  Widget _buildCrosshairLabels() {
    final center = _mapController.camera.center;
    final labels = <Widget>[];
    if (_showCoordinates) {
      final lat = toDms(center.latitude, isLat: true, decimals: 2);
      final lng = toDms(center.longitude, isLat: false, decimals: 2);
      labels.add(strokeText('$lat  $lng', fill: Colors.white, fontSize: 10));
    }
    if (_waypointMode && _waypoints.isNotEmpty) {
      final dist = _distanceCalc.as(LengthUnit.Meter, _waypoints.last.point, center);
      labels.add(strokeText(fmtDistance(dist), fill: Colors.white70, fontSize: 10));
    }
    if (labels.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: labels),
      ),
    );
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
    final mPerPixel = 156543.0 * math.cos(tap.latitude * math.pi / 180) / math.pow(2.0, _mapController.camera.zoom);
    if (bestDist < 30 * mPerPixel && bestIdx >= 0) {
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

  Widget _buildDrawArrowPolyline() {
    final center = _mapController.camera.center;
    return PolylineLayer(polylines: _arrowPolylines(_measureStart!, center, Colors.yellow));
  }

  List<Marker> _buildDrawArrowLabels() {
    final center = _mapController.camera.center;
    return _arrowLabel(_measureStart!, center, Colors.yellow);
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
    final direction = bearingToCardinal(az);
    final angleRad = bearing * math.pi / 180;
    final cosLat = math.cos(to.latitude * math.pi / 180);
    final mPerPixel = 156543.0 * cosLat / math.pow(2.0, _mapController.camera.zoom);
    final backM = 40.0 * mPerPixel;
    final perpM = 20.0 * mPerPixel;

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
        height: 20,
        child: Transform.rotate(
          angle: angleRad,
          child: CustomPaint(
            size: const Size(18, 20),
            painter: ArrowHeadPainter(color),
          ),
        ),
      ),
      Marker(
        point: LatLng(labelLat, labelLng),
        width: 120,
        height: 16,
        child: Transform.rotate(
          angle: textRot,
          child: strokeText(
            '${fmtDistance(dist)}  ${az.toStringAsFixed(1)}°$direction',
            fill: color,
            fontSize: 10,
            minWidth: 120,
          ),
        ),
      ),
    ];
  }

  double _waypointTotalDistance() {
    double d = 0;
    for (int i = 1; i < _waypoints.length; i++) {
      d += _distanceCalc.as(LengthUnit.Meter, _waypoints[i - 1].point, _waypoints[i].point);
    }
    return d;
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
        points: [_waypoints[i - 1].point, _waypoints[i].point],
        color: i.isOdd ? Colors.orange : Colors.deepOrange,
        strokeWidth: 3,
        pattern: StrokePattern.dotted(),
      ));
    }
    return PolylineLayer(polylines: lines);
  }

  Widget _buildWaypointPreview() {
    final center = _mapController.camera.center;
    final i = _waypoints.length;
    return PolylineLayer(
      polylines: [
        Polyline(
          points: [_waypoints.last.point, center],
          color: i.isOdd ? Colors.orange : Colors.deepOrange,
          strokeWidth: 3,
          pattern: StrokePattern.dotted(),
        ),
      ],
    );
  }

  Widget _buildWaypointLayer() {
    final markers = <Marker>[];
    double cum = 0;
    LatLng? prevShown;
    for (int i = 0; i < _waypoints.length; i++) {
      final wp = _waypoints[i];
      final p = wp.point;
      if (i > 0) cum += _distanceCalc.as(LengthUnit.Meter, _waypoints[i - 1].point, p);
      if (prevShown != null && _screenDistance(prevShown, p) < 28 && i != _waypoints.length - 1) {
        continue;
      }
      prevShown = p;
      final lat = toDms(p.latitude, isLat: true);
      final lng = toDms(p.longitude, isLat: false);
      final color = i == 0 ? Colors.green : Colors.orange;
      final name = wp.name;
      markers.add(Marker(
        point: p,
        width: 200,
        height: 24,
        child: GestureDetector(
          onTap: () => setState(() => _editingWaypointIndex = i),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              if (name.isNotEmpty)
                Positioned(
                  top: -16,
                  left: 0,
                  right: 0,
                  child: strokeText(name, fill: Colors.white, fontSize: 12),
                ),
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
              Positioned(
                top: 28,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_showCoordinates) ...[
                      strokeText(lat, fill: color, fontSize: 9),
                      strokeText(lng, fill: color, fontSize: 9),
                    ],
                    strokeText(fmtDistance(cum), fill: Colors.white70, fontSize: 9),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return MarkerLayer(markers: markers);
  }

  List<Marker> _buildWaypointLabels() {
    final labels = <Marker>[];
    for (int i = 1; i < _waypoints.length; i++) {
      final p1 = _waypoints[i - 1].point;
      final p2 = _waypoints[i].point;

      if (_screenDistance(p1, p2) < 60) continue;

      final dist = _distanceCalc.as(LengthUnit.Meter, p1, p2);
      final bearing = _distanceCalc.bearing(p1, p2);
      final az = (bearing + 360) % 360;
      final direction = bearingToCardinal(az);

      final mid = LatLng(
        (p1.latitude + p2.latitude) / 2,
        (p1.longitude + p2.longitude) / 2,
      );

      labels.add(Marker(
        point: mid,
        width: 120,
        height: 16,
        child: strokeText(
          '${fmtDistance(dist)}  ${az.toStringAsFixed(1)}°${direction.isNotEmpty ? " $direction" : ""}',
        ),
      ));
    }
    return labels;
  }

  Widget _buildSavedWaypointLines(int si) {
    final pts = _savedWaypoints[si];
    final lines = <Polyline>[];
    for (int i = 1; i < pts.length; i++) {
      lines.add(Polyline(
        points: [pts[i - 1].point, pts[i].point],
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
    double cum = 0;
    LatLng? prevShown;
    for (int i = 0; i < pts.length; i++) {
      final wp = pts[i];
      final p = wp.point;
      if (i > 0) cum += _distanceCalc.as(LengthUnit.Meter, pts[i - 1].point, p);
      if (prevShown != null && _screenDistance(prevShown, p) < 28 && i != pts.length - 1) {
        continue;
      }
      prevShown = p;
      final lat = toDms(p.latitude, isLat: true);
      final lng = toDms(p.longitude, isLat: false);
      markers.add(Marker(
        point: p,
        width: 200,
        height: 24,
        child: GestureDetector(
          onTap: () => setState(() {
            _editingSavedSetIndex = si;
            _editingSavedIndex = i;
          }),
          child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            if (wp.name.isNotEmpty)
              Positioned(
                top: -16,
                left: 0,
                right: 0,
                child: strokeText(wp.name, fill: Colors.white, fontSize: 12),
              ),
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
            Positioned(
              top: 28,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_showCoordinates) ...[
                    strokeText(lat, fill: Colors.teal, fontSize: 9),
                    strokeText(lng, fill: Colors.teal, fontSize: 9),
                  ],
                  strokeText(fmtDistance(cum), fill: Colors.white70, fontSize: 9),
                ],
              ),
            ),
          ],
        ),
        ),
      ));
    }
    return MarkerLayer(markers: markers);
  }

  List<Marker> _buildSavedWaypointLabels(int si) {
    final pts = _savedWaypoints[si];
    final labels = <Marker>[];
    for (int i = 1; i < pts.length; i++) {
      final p1 = pts[i - 1].point;
      final p2 = pts[i].point;

      if (_screenDistance(p1, p2) < 60) continue;

      final dist = _distanceCalc.as(LengthUnit.Meter, p1, p2);
      final bearing = _distanceCalc.bearing(p1, p2);
      final az = (bearing + 360) % 360;
      final direction = bearingToCardinal(az);
      final mid = LatLng(
        (p1.latitude + p2.latitude) / 2,
        (p1.longitude + p2.longitude) / 2,
      );
      labels.add(Marker(
        point: mid,
        width: 120,
        height: 16,
        child: strokeText(
          '${fmtDistance(dist)}  ${az.toStringAsFixed(1)}°${direction.isNotEmpty ? " $direction" : ""}',
        ),
      ));
    }
    return labels;
  }

  Widget _buildLocationMarker() {
    final lat = toDms(_center.latitude, isLat: true);
    final lng = toDms(_center.longitude, isLat: false);
    final hasHeading = _heading >= 0;
    final headingRad = _heading * math.pi / 180;
    const triDist = 12.0;
    final triDx = triDist * math.sin(headingRad);
    final triDy = -triDist * math.cos(headingRad);

    return MarkerLayer(
      markers: [
        Marker(
          point: _center,
          width: 220,
          height: 100,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: Container(
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
              ),
              if (hasHeading)
                Positioned(
                  left: 110 + triDx - 6,
                  top: 50 + triDy - 8,
                  child: Transform.rotate(
                    angle: headingRad,
                    child: CustomPaint(
                      size: const Size(12, 16),
                      painter: HeadingTrianglePainter(),
                    ),
                  ),
                ),
              if (_showCoordinates)
                Positioned(
                  top: 72,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      strokeText(lat, fill: Colors.blueAccent, fontSize: 11),
                      strokeText(lng, fill: Colors.blueAccent, fontSize: 11),
                    ],
                  ),
                ),
              if (hasHeading)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: strokeText(
                      '${_heading.toStringAsFixed(0).padLeft(3, '0')} ${bearingToCardinal(_heading)}',
                      fill: Colors.blueAccent,
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

