import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台能力开关。
class PlatformSupport {
  PlatformSupport._();

  /// 是否桌面平台（Windows / macOS / Linux）。
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 是否支持用 window_manager 控制窗口（全屏、改窗口尺寸等）。
  static bool get supportsWindowManager => isDesktop;

  /// 是否 Linux 桌面。
  /// 所以这里需要按平台区分处理。
  static bool get isLinux {
    if (kIsWeb) return false;
    return Platform.isLinux;
  }
}
