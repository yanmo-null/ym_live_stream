import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台能力开关。
///
/// 项目原本是 Windows 桌面应用，后来要跑 Android，
/// 而有些插件**只在桌面实现**，在移动端调用会直接抛 MissingPluginException，
/// 一旦抛在 main() 里，runApp 就永远执行不到 —— 表现是卡在启动页进不去界面。
///
/// 所以这类平台相关的能力都从这里判断，不要在各处零散写 Platform.isXXX。
class PlatformSupport {
  PlatformSupport._();

  /// 是否桌面平台（Windows / macOS / Linux）。
  ///
  /// 注意要先判 kIsWeb：Web 上访问 dart:io 的 Platform 会抛异常。
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 是否支持用 window_manager 控制窗口（全屏、改窗口尺寸等）。
  ///
  /// window_manager 只有 Windows / macOS / Linux 的实现，
  /// Android / iOS 上调 ensureInitialized() 会抛 MissingPluginException。
  static bool get supportsWindowManager => isDesktop;

  /// 是否 Linux 桌面。
  ///
  /// 【为什么单独暴露这个】Linux 的窗口尺寸必须交给 GTK 自己决定：
  /// GTK 的窗口自带装饰（HeaderBar），gtk_window_set_default_size 设的是内容区，
  /// 而 window_manager 传的 size 被当成整个窗口。两者差一个 HeaderBar 的高度，
  /// Flutter 的 EGL 表面和请求的帧尺寸长期不一致，启动时要卡两分多钟：
  ///   Timed out waiting for OpenGL frame of size 1280x800 (have 1280x720)
  /// 所以这里需要按平台区分处理。
  static bool get isLinux {
    if (kIsWeb) return false;
    return Platform.isLinux;
  }
}
