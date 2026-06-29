import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Three-layer GPS filter: accuracy threshold + speed threshold + Kalman filter.
class GpsFilter {
  // Kalman state
  double _lat = 0, _lng = 0;
  double _varianceLat = 0, _varianceLng = 0;
  bool _initialized = false;
  DateTime? _lastTime;
  LatLng? _lastPoint;

  // Configuration
  static const double accuracyThreshold = 25.0; // discard if accuracy > 25m
  static const double maxSpeedMs = 50.0; // discard if implied speed > 50m/s (~180km/h)
  static const double processNoise = 2.0; // process noise Q (meters)

  /// Filter a GPS position. Returns filtered LatLng, or null if the point should be discarded.
  LatLng? filter(double lat, double lng, double accuracy, DateTime timestamp) {
    // Layer 1: accuracy threshold
    if (accuracy > accuracyThreshold) {
      return null;
    }

    // Layer 2: speed threshold (only if we have a previous point)
    if (_initialized && _lastPoint != null && _lastTime != null) {
      final dt = timestamp.difference(_lastTime!).inMilliseconds / 1000.0;
      if (dt > 0) {
        final dist = _haversineDistance(_lastPoint!.latitude, _lastPoint!.longitude, lat, lng);
        final speed = dist / dt;
        if (speed > maxSpeedMs) {
          return null;
        }
      }
    }

    // Layer 3: Kalman filter
    if (!_initialized) {
      _lat = lat;
      _lng = lng;
      _varianceLat = accuracy * accuracy;
      _varianceLng = accuracy * accuracy;
      _initialized = true;
    } else {
      // Predict step: increase variance by process noise * dt
      final dt = _lastTime != null
          ? timestamp.difference(_lastTime!).inMilliseconds / 1000.0
          : 1.0;
      final qDt = processNoise * processNoise * dt;
      _varianceLat += qDt;
      _varianceLng += qDt;

      // Update step
      final measVariance = accuracy * accuracy;

      final kLat = _varianceLat / (_varianceLat + measVariance);
      _lat += kLat * (lat - _lat);
      _varianceLat *= (1 - kLat);

      final kLng = _varianceLng / (_varianceLng + measVariance);
      _lng += kLng * (lng - _lng);
      _varianceLng *= (1 - kLng);
    }

    _lastTime = timestamp;
    _lastPoint = LatLng(_lat, _lng);
    return _lastPoint;
  }

  /// Reset filter state (call when starting a new recording or toggling).
  void reset() {
    _initialized = false;
    _lat = 0;
    _lng = 0;
    _varianceLat = 0;
    _varianceLng = 0;
    _lastTime = null;
    _lastPoint = null;
  }

  /// Haversine distance in meters between two lat/lng points.
  static double _haversineDistance(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) * math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;
}
