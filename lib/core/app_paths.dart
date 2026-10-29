import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths._();

  /// 应用私有数据目录（首次访问时惰性创建）
  static Directory? _dataDir;

  /// 拿应用私有数据目录，并确保它存在。
  ///
  /// 只在第一次调用时走 path_provider，后续直接用缓存，避免高频 IO。
  static Future<Directory> dataDirectory() async {
    final cached = _dataDir;
    if (cached != null) return cached;

    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dataDir = dir;
    return dir;
  }

  static Future<String> configPath() async {
    final dir = await dataDirectory();
    return '${dir.path}${Platform.pathSeparator}ym_live_stream_config.json';
  }
}
