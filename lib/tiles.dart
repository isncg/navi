import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class TileCoord {
  final int z, x, y;
  const TileCoord(this.z, this.x, this.y);
}

class CachedTileProvider extends TileProvider {
  CachedTileProvider(this.cacheDir);

  final Directory cacheDir;

  String _tilePath(int z, int x, int y) => '${cacheDir.path}/$z/$x/$y.png';

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final file = File(_tilePath(coordinates.z, coordinates.x, coordinates.y));
    if (file.existsSync()) {
      return FileImage(file);
    }
    return NetworkTileProvider().getImage(coordinates, options);
  }
}

const tileSources = [
  ('高德卫星', 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}', ['1', '2', '3', '4']),
  ('ArcGIS', 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', <String>[]),
  ('ESRI Clarity', 'https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', <String>[]),
];

Future<Directory> initTileCacheDir(int sourceIndex) async {
  final docDir = await getApplicationDocumentsDirectory();
  final dir = Directory('${docDir.path}/tiles_$sourceIndex');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

String tileCachePath(Directory cacheDir, int z, int x, int y) =>
    '${cacheDir.path}/$z/$x/$y.png';

Future<bool> downloadTile(Directory cacheDir, String urlTemplate, List<String> subdomains, int z, int x, int y) async {
  final file = File(tileCachePath(cacheDir, z, x, y));
  if (await file.exists()) return true;
  final url = urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y')
      .replaceAll('{s}', subdomains.isNotEmpty ? subdomains[(x + y) % subdomains.length] : '');
  try {
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(resp.bodyBytes);
      return true;
    }
  } catch (_) {}
  return false;
}

List<TileCoord> computeTileCoords(double lat, double lng, int zoom, double areaM) {
  final latDeg = areaM / 111320.0;
  final lngDeg = areaM / (111320.0 * math.cos(lat * math.pi / 180));
  final tasks = <TileCoord>[];
  for (int z = (zoom - 2).clamp(2, 18); z <= (zoom + 2).clamp(2, 18); z++) {
    final n = 1 << z;
    final xMin = ((lng + 180) / 360 * n).floor() - 1;
    final xMax = xMin + (lngDeg * n / 360).ceil() + 2;
    final yLat = (1 - math.log(math.tan(lat * math.pi / 180) + 1 / math.cos(lat * math.pi / 180)) / math.pi) / 2;
    final yMin = (yLat * n).floor() - 1;
    final yMax = yMin + (latDeg * n / 180).ceil() + 2;
    for (int x = xMin; x <= xMax; x++) {
      for (int y = yMin; y <= yMax; y++) {
        tasks.add(TileCoord(z, x, y));
      }
    }
  }
  return tasks;
}
