import 'dart:io';

import 'package:latlong2/latlong.dart' hide Path;
import 'package:path_provider/path_provider.dart';

import 'common.dart';

class TrackStorage {
  final Distance _distanceCalc;
  final void Function(String msg, {Object? error}) _log;
  final bool Function() _isMounted;

  String? autoSavePath;
  final List<SavedRecording> savedRecordings = [];

  TrackStorage(this._distanceCalc, this._log, this._isMounted);

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

  String _pad(int n) => n.toString().padLeft(2, '0');

  Future<void> saveRecording(List<TrackPoint> track) async {
    final now = DateTime.now();
    final name = '${now.year}-${_pad(now.month)}-${_pad(now.day)}_'
        '${_pad(now.hour)}-${_pad(now.minute)}-${_pad(now.second)}';
    final buf = StringBuffer();
    buf.writeln('#$name');
    for (final t in track) {
      buf.writeln('${t.point.latitude.toStringAsFixed(6)} '
          '${t.point.longitude.toStringAsFixed(6)} '
          '${t.time.millisecondsSinceEpoch} '
          '${t.segment}');
    }
    try {
      final dir = await _trackDir();
      final file = File('${dir.path}/$name.track');
      await file.writeAsString(buf.toString());
      _log('Track saved: $name (${track.length} pts)');
      await loadSavedRecordings();
    } catch (e) {
      _log('Save failed', error: e);
    }
  }

  Future<void> autoSaveNow(List<TrackPoint> track) async {
    if (track.length < 2) return;
    final buf = StringBuffer();
    buf.writeln('#autosave');
    for (final t in track) {
      buf.writeln('${t.point.latitude.toStringAsFixed(6)} '
          '${t.point.longitude.toStringAsFixed(6)} '
          '${t.time.millisecondsSinceEpoch} '
          '${t.segment}');
    }
    try {
      final dir = await _trackDir();
      final tmpFile = File('${dir.path}/.autosave.tmp');
      await tmpFile.writeAsString(buf.toString());
      autoSavePath = tmpFile.path;
    } catch (e) {
      _log('Auto-save failed', error: e);
    }
  }

  Future<void> deleteAutoSave() async {
    if (autoSavePath == null) return;
    try {
      final f = File(autoSavePath!);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    autoSavePath = null;
  }

  Future<void> checkAutoSaveRecovery() async {
    try {
      final dir = await _trackDir();
      final f = File('${dir.path}/.autosave.tmp');
      if (!await f.exists()) return;
      final lines = await f.readAsLines();
      if (lines.length < 3) return;
      final timestamp = DateTime.now();
      final name2 = '${timestamp.year}-${_pad(timestamp.month)}-${_pad(timestamp.day)}_'
          '${_pad(timestamp.hour)}-${_pad(timestamp.minute)}-${_pad(timestamp.second)}_recovered';
      final dest = File('${dir.path}/$name2.track');
      await f.copy(dest.path);
      await f.delete();
      _log('Recovered unsaved track: $name2 (${lines.length - 1} pts)');
      await loadSavedRecordings();
    } catch (e) {
      _log('Recovery check failed', error: e);
    }
  }

  Future<void> loadSavedRecordings() async {
    try {
      final dir = await _trackDir();
      final files = await dir.list().toList();
      final recordings = <SavedRecording>[];
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
            recordings.add(SavedRecording(
              name: name,
              path: f.path,
              pointCount: lines.length - 1,
              totalDistance: totalDist,
            ));
          } catch (_) {}
        }
      }
      recordings.sort((a, b) => b.name.compareTo(a.name));
      if (_isMounted()) {
        savedRecordings
          ..clear()
          ..addAll(recordings);
      }
    } catch (_) {}
  }

  Future<List<TrackPoint>> loadRecording(SavedRecording rec) async {
    final points = <TrackPoint>[];
    try {
      final lines = await File(rec.path).readAsLines();
      if (lines.isEmpty) return points;
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
        points.add(TrackPoint(point, time, cum, segment: seg));
      }
    } catch (_) {}
    return points;
  }

  Future<void> deleteRecording(SavedRecording rec) async {
    try {
      await File(rec.path).delete();
      await loadSavedRecordings();
    } catch (_) {}
  }
}
