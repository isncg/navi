import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

const _a = 6378245.0;
const _ee = 0.00669342162296594323;

bool _outOfChina(double lat, double lng) {
  return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

double _transformLat(double x, double y) {
  var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
  ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0;
  return ret;
}

double _transformLng(double x, double y) {
  var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0;
  ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0;
  return ret;
}

LatLng wgs84ToGcj02(LatLng p) {
  if (_outOfChina(p.latitude, p.longitude)) return p;
  var dLat = _transformLat(p.longitude - 105.0, p.latitude - 35.0);
  var dLng = _transformLng(p.longitude - 105.0, p.latitude - 35.0);
  final radLat = p.latitude / 180.0 * math.pi;
  var magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return LatLng(p.latitude + dLat, p.longitude + dLng);
}

LatLng gcj02ToWgs84(LatLng p) {
  if (_outOfChina(p.latitude, p.longitude)) return p;
  var wgs = p;
  for (int i = 0; i < 2; i++) {
    final gcj = wgs84ToGcj02(wgs);
    wgs = LatLng(wgs.latitude - (gcj.latitude - p.latitude), wgs.longitude - (gcj.longitude - p.longitude));
  }
  return wgs;
}
