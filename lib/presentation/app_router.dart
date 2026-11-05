import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:ym_live_stream/core/route_path.dart';
import 'package:ym_live_stream/contract/live_models.dart';

import 'package:ym_live_stream/presentation/home_page.dart';
import 'package:ym_live_stream/presentation/live_room_page.dart';

/// 应用路由表。
///
/// 【为什么从 GetX 换到 go_router】
/// GetX 的路由和它的状态管理耦在一起：`GetMaterialApp` + `getPages` +
/// `Get.toNamed` + `Get.arguments`。想只换路由不换状态几乎做不到，而且
/// GetX 本身已经实质停更（4.7.3 之后几年没动），长痛不如短痛。
///
/// [go_router] 由 flutter.dev 官方维护（pub.dev publisher 是 flutter.dev），
/// 和 http / SDK 同档风险，不是个人项目。它把路由表拆成纯数据，
/// 深链接（`/liveroom/deep/:roomId?site=douyu`）直接写在 path pattern 里，
/// 比 GetX 靠 `Get.parameters` 捞更清楚。
///
/// 【路径约定】path 里带 `:` 的是路径参数，进 `state.pathParameters`；
/// 问号后面的是查询参数，进 `state.uri.queryParameters`。
class AppRouter {
  AppRouter._();

  /// 根 Navigator 的 key。
  ///
  /// 【为什么需要它】controller 里没有 BuildContext（GetX 的 controller 就是一
  /// 个普通对象），但有些动作必须拿到 Navigator 才能弹 dialog。
  /// 之前靠 `Get.key.currentState` —— 那是 GetMaterialApp 专有的，换路由后没了。
  /// 现在把这个 key 交给 MaterialApp.router，任何地方都能：
  ///     AppRouter.rootNavigatorKey.currentContext
  /// 拿到一个可用的 context 去 showDialog。
  static final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

  /// 全局唯一的 router。
  ///
  /// 【为什么是静态单例】GoRouter 必须活在整个 App 生命周期内，
  /// 每次 build 新建一个会把导航栈清空。main.dart 里把它交给
  /// MaterialApp.router，widget 树重建时读的还是同一个实例。
  static final GoRouter router = GoRouter(
    navigatorKey: rootNavigatorKey,
    // 首页固定是 /home；深链接由系统把完整 URL 交给 go_router 自己解析。
    initialLocation: RoutePath.p_home,
    routes: [
      GoRoute(
        path: RoutePath.p_home,
        builder: (context, state) => HomePage(),
      ),

      // 直播间：支持两种入口
      //   1) 直接跳：/liveroom/detail（房间参数走 extra 传）
      //   2) 深链接：/liveroom/deep/<roomId>?site=douyu（可从命令行/分享链接直达）
      GoRoute(
        path: RoutePath.p_liveroom,
        builder: (context, state) {
          final args = _liveRoomArgsFromExtra(state.extra);
          if (args == null) {
            // 缺少房间参数说明跳转调用方写错了，回到首页而不是白屏
            return HomePage();
          }
          return LiveStreamPage(args: args);
        },
      ),
      GoRoute(
        path: RoutePath.p_liveroom_deep,
        builder: (context, state) {
          final args = _liveRoomArgsFromDeepLink(state);
          if (args == null) {
            return HomePage();
          }
          return LiveStreamPage(args: args);
        },
      ),
    ],
  );

  /// 从 `state.extra` 取房间参数（普通跳转时用 `extra: LiveRoomArgs(...)` 传）。
  ///
  /// 【为什么用 extra 而不是 query 参数】普通跳转（从名片点进直播间）
  /// 不产生 URL，用 extra 传对象最直接，也不用序列化。
  static LiveRoomArgs? _liveRoomArgsFromExtra(Object? extra) {
    if (extra is LiveRoomArgs) {
      return LiveRoomArgs.isValidRoomId(extra.roomId) ? extra : null;
    }
    return null;
  }

  /// 从深链接解析房间参数：roomId 在 path 里，site 在 query 里。
  ///
  /// 缺 site 时给斗鱼兜底，和 LiveRoomArgs.fromParameters 的老行为一致，
  /// 避免旧链接（没带 site）一进来就白屏。
  static LiveRoomArgs? _liveRoomArgsFromDeepLink(GoRouterState state) {
    final roomId = state.pathParameters['roomId'];
    if (!LiveRoomArgs.isValidRoomId(roomId)) return null;
    final siteName = state.uri.queryParameters['site'];
    final site = LIVE_SITE_E.values.firstWhere(
      (e) => e.name == siteName,
      orElse: () => LIVE_SITE_E.LIVE_SITE_DOUYU,
    );
    return LiveRoomArgs(roomId: roomId!.trim(), site: site);
  }
}

/// 导航辅助：把「打开直播间」的两种形式收成扩展方法。
///
/// 【别在页面里直接写 context.go(...) + extra】两个参数必须一起给，
/// 拆开写容易出现「给了 path 没给 extra」导致页面回退首页。
extension LiveRoomNavigation on BuildContext {
  /// 打开直播间（普通跳转，参数走 extra，不产生 URL）
  void openLiveRoom(LiveRoomArgs args) => go(RoutePath.p_liveroom, extra: args);

  /// 打开直播间（深链接形式，可收藏/分享）
  void openLiveRoomDeep(LIVE_SITE_E site, String roomId) =>
      go('${RoutePath.p_liveroom_deep.replaceFirst(':roomId', roomId)}?site=${site.name}');
}
