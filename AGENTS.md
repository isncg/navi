# AGENTS.md

Flutter app for satellite map display and device location.

## Stack
- Flutter (Dart)

## Commands
- `flutter pub get` — install dependencies
- `flutter run` — launch on connected device / Chrome / Windows
- `flutter build windows` — release build for Windows
- `flutter build apk` — release build for Android

## Architecture
- `lib/main.dart` — single-file app entrypoint, all features inline
- `lib/common.dart` — shared types (`TrackPoint`, `SavedRecording`, `Measurement`), formatters (`fmtDuration`, `fmtDistance`, `toDms`, `bearingToCardinal`), `strokeText`, `ArrowHeadPainter`, segment helpers

## Features
- Satellite tile map (ArcGIS World Imagery)
- Device location marker with coordinates
- Track recording (polyline, time/distance labels, timer bar)
- Survey tool (tap to place waypoints, segment distance/bearing/coordinates)
- On-screen debug log panel
