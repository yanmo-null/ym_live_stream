import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ym_live_stream/presentation/app_router.dart';

/// 全局统一的轻提示：居中偏下的半透明黑底小卡片，无遮罩，3 秒自动消失。
///
/// 【为什么不用 Get.snackbar】GetX 的 SnackBar 外层是 Align + Container，
/// 宽度由它自己的参数决定，在 messageText 里写死的宽度会被外层吃掉，
/// 实测控制不住尺寸。这里直接用 Overlay 画一个固定宽度的小卡片。
///
/// 形态：半透明黑底 + 细白边 + 轻投影，居中偏下，无遮罩（不打断操作）。
/// 和画质/线路菜单、弹幕设置面板用同一套深色底，观感统一。
/// 同一时间只显示一条：新提示顶掉旧的。
class AppSnackbar {
  AppSnackbar._();

  /// 卡片宽度（固定值，不随内容变，避免长短不一时跳动）
  static const double _width = 320;

  /// 距屏幕底部的距离：偏下但不贴底
  static const double _bottomOffset = 96;

  /// 当前正在显示的浮层与定时器（同一时间只保留一条）
  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 显示一条提示。默认 3 秒后自动消失。
  ///
  /// [title] 第一行（加粗），[message] 第二行（最多两行，超出省略）。
  static void show(String title, String message, {Duration duration = const Duration(seconds: 2), bool isError = false}) {
    // 先收起上一条：连续操作时不叠在一起
    dismiss();

    // 【从 Get.key.currentState?.overlay 换成 AppRouter.rootNavigatorKey】
    // GetX 的 overlay 依赖 GetMaterialApp，路由换到 MaterialApp.router 后
    // `Get.key` 是 null，所有提示都会静默消失。改用 go_router 的根
    // navigatorKey 拿 Overlay —— 它是 MaterialApp 的真实 Navigator。
    final overlay = AppRouter.rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        bottom: _bottomOffset,
        child: IgnorePointer(
          child: Center(
            // 淡入 + 轻微上浮：直接出现太生硬
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
              ),
              child: _buildCard(title: title, message: message, isError: isError),
            ),
          ),
        ),
      ),
    );

    _entry = entry;
    overlay.insert(entry);

    _timer = Timer(duration, dismiss);
  }

  /// 收起当前提示（幂等）
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  /// 卡片本体：浅色底 + 细边 + 轻投影
  static Widget _buildCard({required String title, required String message, required bool isError}) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: _width,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          // 半透明黑底：压在视频画面上不突兀，也和画质/线路菜单、
          // 弹幕设置面板的黑底保持一致。
          // 出错时混一点红，不用边框也能一眼分出成败。
          color: (isError ? const Color(0xFF3A1414) : Colors.black).withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                fontWeight: FontWeight.w600,
                // 黑底一律白字；错误态的标题用浅红，保证在暗底上够亮
                color: isError ? const Color(0xFFFFB4AB) : Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: isError ? const Color(0xFFFFB4AB).withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
