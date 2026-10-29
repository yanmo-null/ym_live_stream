import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:get/get.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:window_manager/window_manager.dart';

import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import 'package:ym_live_stream/features/favorite_store.dart';
import 'package:ym_live_stream/features/live_common.dart';

import 'package:ym_live_stream/core/platform_support.dart';
import 'package:ym_live_stream/core/route_path.dart';

import 'package:ym_live_stream/contract/auth_source.dart';
import 'package:ym_live_stream/contract/live_source.dart';

import 'package:ym_live_stream/presentation/ym_live_pages.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      debugPrint('[BOOT] 1. binding 就绪');

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[BOOT][FATAL] Flutter 异常: ${details.exception}\n${details.stack}');
      };
      ErrorWidget.builder = (FlutterErrorDetails details) {
        debugPrint('[BOOT][FATAL] 组件构建失败: ${details.exception}\n${details.stack}');
        return _WidgetErrorView('${details.exception}\n\n${details.stack ?? ''}');
      };

      // 收藏列表的本地存储：Hive 是二进制 box（不是明文 json），
      // initFlutter 用 path_provider 决定目录，不随工作目录漂移。
      debugPrint('[BOOT] 2. 准备 Hive.initFlutter()');
      await Hive.initFlutter();
      debugPrint('[BOOT] 3. Hive 就绪');
      await FavoriteStore.instance.init();
      debugPrint('[BOOT] 4. FavoriteStore 就绪');

      //Initialize the media_kit components
      debugPrint('[BOOT] 5. MediaKit.ensureInitialized()');
      MediaKit.ensureInitialized();

      debugPrint('[BOOT] 5.1 已注册后端: ${LiveSourceRegistry.registeredCount} 个平台');

      // 窗口管理：全屏按钮要它把窗口切成全屏，必须在 runApp 之前初始化。
      if (PlatformSupport.supportsWindowManager) {
        await windowManager.ensureInitialized();
        if (PlatformSupport.isLinux) {
          await windowManager.show();
          await windowManager.focus();
        } else {
          const windowOptions = WindowOptions(size: Size(1280, 800), minimumSize: Size(960, 600), center: true, title: 'YM Live Stream');
          // 用 waitUntilReadyToShow：确保窗口出现时就是目标尺寸，不会先闪一下默认大小再跳过去。
          windowManager.waitUntilReadyToShow(windowOptions, () async {
            await windowManager.show();
            await windowManager.focus();
          });
        }
      }

      debugPrint('[BOOT] 6. 准备 runApp');
      runApp(const YMLiveStream());
      debugPrint('[BOOT] 7. runApp 已调用');
    },
    (error, stack) {
      // zone 内的未捕获异步异常（比如 await 里抛的）会走到这里。
      debugPrint('[BOOT][FATAL] 未捕获异常: $error\n$stack');
    },
  );
}

class DevBoot {
  static const bool enabled = false; // 测试完改 false
  static const int roomId = 6925114;
  static const LIVE_SITE_E site = LIVE_SITE_E.LIVE_SITE_DOUYU;
  static String get bootRoute => '${RoutePath.p_liveroom_deep.replaceFirst(':roomId', '$roomId')}?site=${site.name}';
}

class YMLiveStream extends StatelessWidget {
  const YMLiveStream({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'YMLive Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),

      //RoutePath.p_liveroom,
      initialRoute: DevBoot.enabled ? DevBoot.bootRoute : RoutePath.p_home,
      getPages: YMLivePages.all_routes,

      // home: const LiveStreamPage(),
      builder: (context, child) => FlutterSmartDialog(child: child),
    );
  }
}

class _WidgetErrorView extends StatelessWidget {
  final String message;

  const _WidgetErrorView(this.message);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '页面渲染出错',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red),
              ),
              const SizedBox(height: 12),
              SelectableText(message, style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.black87)),
            ],
          ),
        ),
      ),
    );
  }
}
