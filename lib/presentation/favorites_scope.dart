import 'package:flutter/widgets.dart';

import 'controller/favorites_controller.dart';

/// 把 [FavoritesController] 挂到 widget 树上，供主页 / 关注页 / 将来的录播页读取。
///
/// 【为什么是应用级的共享状态，而不是 HomePage 自己持有】
/// 后面要加的「录播页」需要显示关注和特别关注的用户信息，也就是要用到
/// 同一份名片数据。如果两个页面各建一个 FavoritesController：
///   1. **请求翻倍** —— 同一批房间被主页刷一遍、录播页再刷一遍，
///      在「关注上百个直播间」的场景下这个代价很实在；
///   2. **状态不一致** —— 主页说在播、录播页说未开播，因为各查各的。
/// 所以它和 SettingsScope 一样挂在 App 根部，全局一份。
///
/// 【和 SettingsScope 的区别】这里不传 init()：FavoritesController 的
/// 首次加载会真的发一堆网络请求，不应该在 App 启动时就触发。
/// 由 HomePage 在真正需要时调 `FavoritesScope.of(context).init()`（幂等）。
class FavoritesScope extends StatefulWidget {
  final Widget child;

  const FavoritesScope({super.key, required this.child});

  @override
  State<FavoritesScope> createState() => _FavoritesScopeState();

  /// 从任意 context 取 controller（会订阅，controller 通知时当前 widget 重建）。
  static FavoritesController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_FavoritesInherited>();
    assert(scope != null, 'FavoritesScope.of(context) 被调用，但上层没有 FavoritesScope');
    return scope!.notifier!;
  }

  /// 只读不订阅（用在事件回调里，不希望在通知时重建当前 widget）。
  static FavoritesController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_FavoritesInherited>();
    assert(scope != null, 'FavoritesScope.read(context) 被调用，但上层没有 FavoritesScope');
    return scope!.notifier!;
  }
}

class _FavoritesScopeState extends State<FavoritesScope> {
  late final FavoritesController _controller;

  @override
  void initState() {
    super.initState();
    // 【不在这里 init()】构造即发网络请求会让 App 启动变慢，
    // 而且用户可能根本不看关注列表。首次加载由 HomePage 触发。
    _controller = FavoritesController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _FavoritesInherited(notifier: _controller, child: widget.child);
  }
}

class _FavoritesInherited extends InheritedNotifier<FavoritesController> {
  const _FavoritesInherited({required super.notifier, required super.child});
}
