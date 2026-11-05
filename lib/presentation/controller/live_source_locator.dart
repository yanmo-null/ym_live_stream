import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';
import 'package:ym_live_stream/mock/mock_live_source.dart';

/// 按平台取后端实现；没注册（开源版没接后端）就用 mock 兜底。
///
/// 【为什么单独抽成一个类】
/// 原来这是 `HomeController` 里的私有方法 `_sourceOf`，被三处用着：
///   1. 收藏列表查开播状态（现在在 FavoritesController 里）
///   2. 进房前探活（还在 HomeController 里）
///   3. 搜索时把主播别名换成房间号（也在 HomeController 里）
///
/// 收藏拆成独立 controller 之后，这三处分散在两个类里。如果各自复制一份，
/// 最直接的后果是 **mock 缓存变成两份**：同一个平台会建出两个 MockLiveSource，
/// 而 mock 里的假数据是按实例存的 —— 两边看到的状态会不一致。
///
/// 所以抽到这里，缓存只有一份，谁调都拿到同一个实例。
class LiveSourceLocator {
  LiveSourceLocator._();

  /// mock 兜底实例按平台缓存一份，避免每次新建
  static final Map<LIVE_SITE_E, LiveSource> _mockCache = {};

  static LiveSource of(LIVE_SITE_E site) =>
      LiveSourceRegistry.find(site) ?? _mockCache.putIfAbsent(site, () => MockLiveSource(site));
}
