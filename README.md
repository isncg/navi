# Navi - 户外卫星地图与轨迹记录

基于 Flutter 的离线卫星地图定位应用，支持轨迹录制、路径点规划、距离测量。

## 功能

- **卫星地图**：多图源切换 + 离线瓦片缓存下载，支持异形屏全屏显示
- **定位朝向**：GPS 定位与真实指南针朝向，经纬度可按需显隐
- **轨迹记录**：后台录制、自动保存恢复、历史轨迹回放
- **路径点模式**：十字准星打点、累计里程、命名编辑、保存多组路径
- **测距模式**：地图上画线量距，显示方位角和距离
- **其他**：横竖屏切换、军事网格、调试控制台、防误退出

## 技术栈

Flutter 3.x / flutter_map / geolocator / flutter_device_compass / latlong2

## 快速开始

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## 项目结构

```
lib/
├── main.dart       # 入口与主页面
├── common.dart     # 模型与工具函数
├── painters.dart   # 自定义绘制
├── tiles.dart      # 瓦片源与下载
└── track_io.dart   # 轨迹文件 I/O
```

## 注意

高德卫星图（GCJ-02）与 GPS（WGS-84）存在坐标偏移，默认使用 ArcGIS。
