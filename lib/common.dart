import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

class TrackPoint {
  final LatLng point;
  final DateTime time;
  final double totalDistance;
  final int segment;

  const TrackPoint(this.point, this.time, this.totalDistance, {this.segment = 0});
}

class SavedRecording {
  final String name;
  final String path;
  final int pointCount;
  final double totalDistance;

  const SavedRecording({
    required this.name,
    required this.path,
    required this.pointCount,
    required this.totalDistance,
  });
}

class Measurement {
  final LatLng from;
  final LatLng to;
  const Measurement(this.from, this.to);
}

class Waypoint {
  final LatLng point;
  final String name;
  const Waypoint(this.point, {this.name = ''});
  Waypoint copyWith({LatLng? point, String? name}) =>
      Waypoint(point ?? this.point, name: name ?? this.name);
}

String fmtDuration(int s) {
  if (s < 0) return '--:--';
  if (s > 863999) return '${(s / 3600).toStringAsFixed(1)}h';
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

String fmtTime(DateTime t) {
  final now = DateTime.now();
  final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  if (t.year != now.year) {
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $s';
  }
  if (t.month != now.month || t.day != now.day) {
    if (t.month != now.month) {
      return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $s';
    }
    return '${t.day.toString().padLeft(2, '0')}日 $s';
  }
  return s;
}

String fmtDistance(double m) {
  if (m < 1000) return '${m.toStringAsFixed(0)} m';
  return '${(m / 1000).toStringAsFixed(2)} km';
}

String toDms(double deg, {required bool isLat, int decimals = 1}) {
  final dir = isLat ? (deg >= 0 ? 'N' : 'S') : (deg >= 0 ? 'E' : 'W');
  final d = deg.abs();
  final degrees = d.truncate();
  final minutes = ((d - degrees) * 60).truncate();
  final seconds = ((d - degrees) * 60 - minutes) * 60;
  return '$degrees°${minutes.toString().padLeft(2, '0')}\'${seconds.toStringAsFixed(decimals).padLeft(3 + decimals, '0')}"$dir';
}

String bearingToCardinal(double degrees) {
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

const _debugStrokeText = false;

Widget strokeText(String text, {Color fill = Colors.white, double fontSize = 11, double minWidth = 0}) {
  return Container(
    decoration: _debugStrokeText
        ? BoxDecoration(border: Border.all(color: Colors.red, width: 1))
        : null,
    child: _debugStrokeText
        ? CustomPaint(
            foregroundPainter: _CenterDotPainter(),
            child: _buildTextStack(text, fill, fontSize, minWidth),
          )
        : _buildTextStack(text, fill, fontSize, minWidth),
  );
}

Widget _buildTextStack(String text, Color fill, double fontSize, double minWidth) {
  return SizedBox(
    width: minWidth > 0 ? minWidth : null,
    child: Stack(
      children: [
        SizedBox(
          width: double.infinity,
          child: Text(
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
        ),
        SizedBox(
          width: double.infinity,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: fill,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CenterDotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = Colors.red;
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 3, dot);
    canvas.drawLine(Offset(size.width / 2 - 5, size.height / 2), Offset(size.width / 2 + 5, size.height / 2), dot);
    canvas.drawLine(Offset(size.width / 2, size.height / 2 - 5), Offset(size.width / 2, size.height / 2 + 5), dot);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const segmentColors = [
  Colors.cyanAccent,
  Colors.yellowAccent,
  Colors.orangeAccent,
  Colors.greenAccent,
  Colors.pinkAccent,
];

const loadedSegmentColors = [
  Colors.purpleAccent,
  Colors.pink,
  Colors.deepOrangeAccent,
  Colors.tealAccent,
];

List<Polyline> buildSegmentPolylines(
  List<TrackPoint> points,
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

class ArrowHeadPainter extends CustomPainter {
  final Color color;
  ArrowHeadPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width / 2, size.height / 2)
      ..lineTo(0, size.height)
      ..moveTo(size.width / 2, size.height / 2)
      ..lineTo(size.width, size.height);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
