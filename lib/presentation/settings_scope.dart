import 'package:flutter/widgets.dart';

import 'controller/settings_controller.dart';

/// 把 [SettingsController] 挂到 widget 树上，供设置页读取。
///
/// 【为什么不用第三方 Provider / GetX】
/// 这个项目正在把 GetX 换掉，目标是不再依赖停更的第三方状态库。
/// 跨页面共享一个 controller 这件事，Flutter SDK 自带的
/// [InheritedNotifier] 就够用：
///   * 下游用 `SettingsScope.of(context)` 取到实例；
///   * 实例 `notifyListeners()` 时，依赖它的 widget 自动重建
///     （InheritedNotifier 内部就是监听 listenable 并触发 dependents 重建）。
///
/// 【生命周期】controller 由本 widget 创建、`dispose` 时释放。
/// 它活在整个 App 根部，所以设置页来回切也不会丢状态（登录态摘要不会闪）。
class SettingsScope extends StatefulWidget {
  final Widget child;

  const SettingsScope({super.key, required this.child});

  @override
  State<SettingsScope> createState() => _SettingsScopeState();

  /// 从任意 context 取 controller。
  ///
  /// 找不到时直接抛断言（而不是返回 null 悄悄兜底）：
  /// 说明使用处没被 SettingsScope 包住，属于接线错误，应该在开发期就炸出来。
  static SettingsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SettingsInherited>();
    assert(scope != null, 'SettingsScope.of(context) 被调用，但上层没有 SettingsScope');
    return scope!.notifier!;
  }

  /// 只读不订阅（用在事件回调里，不希望在通知时重建当前 widget）。
  static SettingsController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_SettingsInherited>();
    assert(scope != null, 'SettingsScope.read(context) 被调用，但上层没有 SettingsScope');
    return scope!.notifier!;
  }
}

class _SettingsScopeState extends State<SettingsScope> {
  late final SettingsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SettingsController()..init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsInherited(notifier: _controller, child: widget.child);
  }
}

class _SettingsInherited extends InheritedNotifier<SettingsController> {
  const _SettingsInherited({required super.notifier, required super.child});
}
