import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/features/favorite_store.dart';
import 'package:ym_live_stream/shared/live_site_meta.dart';

import 'live_source_locator.dart';

/// 名片的直播状态。用三态而不是 bool：
/// bool 会把“还没拉到数据”显示成“未开播”，这是错的。
enum LiveStatus { live, offline, unknown, banned }

/// 名片数据。
class CardItemData {
  final String avatarUrl;
  final String userName;
  final LiveStatus status;
  final String roomTitle;

  /// 点名片要能进直播间，所以带上平台和房间号
  final String? roomId;
  final LIVE_SITE_E? site;

  CardItemData({
    required this.avatarUrl,
    required this.userName,
    required this.roomTitle,
    this.status = LiveStatus.unknown,
    this.roomId,
    this.site,
  });
}

/// 单房间查询结果：状态 + 最新元信息。
///
/// roomName / ownerName / ownerProfileUrl 为空表示这次没取到（用存储值兜底）
class _RoomStatusProbe {
  final LiveStatus status;
  final String roomName;
  final String ownerName;
  final String ownerProfileUrl;

  const _RoomStatusProbe({
    required this.status,
    this.roomName = '',
    this.ownerName = '',
    this.ownerProfileUrl = '',
  });
}

/// 关注（收藏）列表的控制器。
///
/// 【为什么从 HomeController 里拆出来】
/// 原来一个类同时管导航、搜索、进房、收藏四件事。收藏那段还带着
/// 「查开播状态 → 写回存储 → 稳定排序」的完整流程，和搜索/进房混在一起，
/// 改任何一块都要在一个 800 行的类里翻。
///
/// 【为什么用 InheritedNotifier 挂到 App 根部，而不是 HomePage 自己持有】
/// 因为后面还要加「录播页」，那一页要显示关注 / 特别关注的用户信息。
/// 如果两页各建一个实例，会有两个独立的问题：
///   1. **请求翻倍**：同一批房间被主页刷一遍、录播页再刷一遍；
///   2. **状态不一致**：主页显示在播、录播页显示未开播，因为它们各查各的。
/// 所以它和 SettingsController 一样，是一个「应用级」的共享状态。
///
/// 【和 GetX 的对应关系】
///   `final x = <T>[].obs`        →  `List<T> _x` + `get x` + `notifyListeners()`
///   `Obx(() => controller.x.value)` → `ListenableBuilder(listenable: ...)`
class FavoritesController extends ChangeNotifier {
  // ===================== 名片列表（两个区域，两份数据）=====================

  /// 主页下半区的名片：**只放特别关注的房间**。数据来源 FavoriteStore.specialFollowed()。
  List<CardItemData> _specialCards = const [];
  List<CardItemData> get specialCards => _specialCards;

  /// 「我的关注」页的名片：放**全部关注**（含特别关注）的房间。
  ///
  /// 这两个列表刻意分开：主页是「特别关注」的精选，关注页是完整名单。
  /// 之前共用一个 cardList，结果两个区域显示同一批人。
  List<CardItemData> _followedCards = const [];
  List<CardItemData> get followedCards => _followedCards;

  /// 正在刷新开播状态（两个刷新按钮共用）
  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  /// 避免两个按钮同时点出两轮刷新
  bool _refreshBusy = false;

  /// 关注页的分组数据：按平台把 followedCards 拆开。
  ///
  /// 组的顺序按 LiveSites.all 的固定顺序（哔哩哔哩 → 斗鱼 → 抖音 → 虎牙 → 快手），
  /// 而不是按数据出现的先后 —— 否则刷新状态后卡片顺序一变，
  /// 整组的上下位置也跟着跳。空组直接跳过，不显示没有内容的平台标题。
  List<({LIVE_SITE_E site, String title, List<CardItemData> cards})> get followedGroups {
    final result = <({LIVE_SITE_E site, String title, List<CardItemData> cards})>[];
    for (final meta in LiveSites.all) {
      final cards = _followedCards.where((c) => c.site == meta.site).toList();
      if (cards.isEmpty) continue;
      result.add((site: meta.site, title: meta.displayName, cards: cards));
    }
    return result;
  }

  // ===================== 生命周期 =====================

  /// 页面初始化时调用：先铺本地快照，再异步下查开播状态。
  ///
  /// 【为什么不写在构造函数里】构造函数要能纯同步、可预测。
  /// 预览 / 测试 new 一个 controller 时不应该顺手发一堆网络请求；
  /// 由宿主（FavoritesScope）在自己的 initState 里显式调用。
  ///
  /// 【为什么推到 postFrame】_loadFromStore() 最后会 notifyListeners()，
  /// 如果 init() 在某个 widget 的 build 阶段被同步调用（HomePage.build 就是这样），
  /// 这次通知会让 _FavoritesInherited 在 build 期间 markNeedsBuild ——
  /// 它不是当前正在 build 的 widget 的祖先，断言「setState() or markNeedsBuild()
  /// called during build」直接炸。推到当前 frame 结束之后执行，通知就安全了。
  /// 幂等：只跑一次，重复调用（HomePage 每次 build 都调）直接跳过。
  bool _didInit = false;
  void init() {
    if (_didInit) return;
    _didInit = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _loadFromStore();
      unawaited(refreshLiveStatus());
    });
  }

  // ===================== 读存储 =====================

  /// 从 Hive 读关注记录，分别铺到「主页特别关注」和「关注页全量」两个列表
  void _loadFromStore() {
    final all = FavoriteStore.instance.all();
    _specialCards = all.where((f) => f.specialFollowed).map(_toCard).toList();
    _followedCards = all.map(_toCard).toList();
    _sortByStatus();
    notifyListeners();
  }

  /// 存储记录 → 名片数据（状态先给 unknown，等下面查）
  static CardItemData _toCard(FavoriteRoom f, {LiveStatus status = LiveStatus.unknown}) => CardItemData(
        avatarUrl: f.ownerProfileUrl,
        userName: f.ownerName,
        roomTitle: f.roomName,
        status: status,
        roomId: f.roomId,
        site: f.site,
      );

  /// 供外部调用：按本地存储重建两份名片，沿用已知的开播状态。
  ///
  /// 房间里增删过关注 / 改过特别关注后回到首页用，纯本地操作，不发请求。
  /// 导入关注列表之后也要调它，否则卡片还是旧的。
  void reloadFromStore() => _rebuildFromStore();

  void _rebuildFromStore() {
    // 先把已知状态按 key 记下来，重建时沿用，避免白白退化成「状态未知」。
    // 两份列表都要扫：某条记录可能只在其中一份里出现过。
    final known = <String, LiveStatus>{};
    for (final card in [..._followedCards, ..._specialCards]) {
      final roomId = card.roomId;
      final site = card.site;
      if (roomId == null || site == null) continue;
      known['${site.name}_$roomId'] = card.status;
    }

    final all = FavoriteStore.instance.all();
    _specialCards = all
        .where((f) => f.specialFollowed)
        .map((f) => _toCard(f, status: known[f.key] ?? LiveStatus.unknown))
        .toList();
    _followedCards = all.map((f) => _toCard(f, status: known[f.key] ?? LiveStatus.unknown)).toList();
    _sortByStatus();
    notifyListeners();
  }

  // ===================== 查开播状态 =====================

  /// 下查开播状态，查到后原地替换卡片。
  /// 覆盖两个入口：init 的首次加载、两个「刷新」按钮。
  ///
  /// 查**全部关注**（不只是特别关注）：关注页要显示所有人的状态，
  /// 主页那份从同一批结果里筛出来即可，不用重复请求。
  ///
  /// 【除了状态，还要刷新房名和主播名】接口返回的 LiveRoomInfo 里本来就带着
  /// 最新的 title / uname / face，之前只取了 show_status 就丢掉，
  /// 于是卡片标题永远停在「第一次关注时」的快照上 ——
  /// 主播改个房名，卡片还是旧的，直到用户重新关注一次。
  /// 现在把这几项一并写回本地存储，卡片和存储都保持最新。
  Future<void> refreshLiveStatus() async {
    if (_refreshBusy) return;

    // 以本地存储为准重新读一遍（可能刚被增删）
    final favorites = FavoriteStore.instance.all();
    if (favorites.isEmpty) {
      _specialCards = const [];
      _followedCards = const [];
      notifyListeners();
      return;
    }

    _refreshBusy = true;
    _isRefreshing = true;
    notifyListeners();
    try {
      // 一次查询同时拿到「状态」和「最新元信息」，避免每个房间请求两遍
      final probeMap = <String, _RoomStatusProbe>{};
      await Future.wait(
        favorites.map((f) async {
          probeMap[f.key] = await _queryStatusAndMeta(f);
        }),
      );

      // 有变化就把最新元信息写回本地存储，下次启动/重建也能看到新房名
      for (final f in favorites) {
        final probe = probeMap[f.key];
        if (probe == null) continue;
        // copyWithMeta 在「三项都没变化」时返回 null，跳过写盘
        final merged = f.copyWithMeta(
          roomName: probe.roomName,
          ownerName: probe.ownerName,
          ownerProfileUrl: probe.ownerProfileUrl,
        );
        if (merged != null) await FavoriteStore.instance.add(merged);
      }

      // 用「最新的那份」来铺卡片：优先用 probe 里的值，取不到才退回存储值
      CardItemData toCardWithProbe(FavoriteRoom f) {
        final probe = probeMap[f.key];
        return CardItemData(
          avatarUrl: (probe?.ownerProfileUrl.isNotEmpty ?? false) ? probe!.ownerProfileUrl : f.ownerProfileUrl,
          userName: (probe != null && probe.ownerName.isNotEmpty) ? probe.ownerName : f.ownerName,
          roomTitle: (probe != null && probe.roomName.isNotEmpty) ? probe.roomName : f.roomName,
          status: probe?.status ?? LiveStatus.unknown,
          roomId: f.roomId,
          site: f.site,
        );
      }

      // 查询结果只算一次，两个列表按各自的范围取用
      _specialCards = favorites.where((f) => f.specialFollowed).map(toCardWithProbe).toList();
      _followedCards = favorites.map(toCardWithProbe).toList();
      // 查到状态后按开播状态重排：直播中的顶到前面
      _sortByStatus();
    } finally {
      _isRefreshing = false;
      _refreshBusy = false;
      notifyListeners();
    }
  }

  Future<_RoomStatusProbe> _queryStatusAndMeta(FavoriteRoom f) async {
    try {
      // 【三个平台原本是三段几乎一样的代码】区别只在调哪个方法取元信息，
      // 现在统一走 LiveSource.fetchRoomBrief，这里只剩一段。
      final info = await LiveSourceLocator.of(f.site).fetchRoomBrief(f.roomId);
      if (info == null) return const _RoomStatusProbe(status: LiveStatus.unknown);

      return _RoomStatusProbe(
        status: _mapStatus(info.show_status),
        roomName: info.room_name ?? '',
        ownerName: info.owner_name ?? '',
        ownerProfileUrl: info.owner_profile_url ?? '',
      );
    } catch (_) {
      return const _RoomStatusProbe(status: LiveStatus.unknown);
    }
  }

  static LiveStatus _mapStatus(LIVE_SHOW_STATUS_E? status) {
    switch (status) {
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE:
        return LiveStatus.live;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE:
        return LiveStatus.offline;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN:
        return LiveStatus.banned;
      case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN:
      case null:
        return LiveStatus.unknown;
    }
  }

  // ===================== 排序 =====================

  /// 两份名片列表都按开播状态排序：直播中在最前，然后依次是状态未知、未开播、被封禁。
  ///
  /// 用**稳定排序**（List.sort 在 Dart 里不保证稳定，所以这里自己比较）：
  /// 同一状态内保持原有的关注顺序，这样刷新状态后卡片不会在组内乱跳。
  /// 所有重建列表的地方都要过一遍这个函数，否则排序会不一致。
  void _sortByStatus() {
    _specialCards = _sorted(_specialCards);
    _followedCards = _sorted(_followedCards);
  }

  /// 按状态稳定排序一份列表，返回新列表（不改入参）
  static List<CardItemData> _sorted(List<CardItemData> source) {
    final sorted = source.toList();
    // 先记为原始下标，状态相同时用它当次要排序键
    final indexOf = <CardItemData, int>{};
    for (var i = 0; i < sorted.length; i++) {
      indexOf[sorted[i]] = i;
    }
    sorted.sort((a, b) {
      final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
      if (byStatus != 0) return byStatus;
      return (indexOf[a] ?? 0).compareTo(indexOf[b] ?? 0);
    });
    return sorted;
  }

  /// 状态排序权重，数字越小越靠前。
  /// unknown 排在 offline 之前：还没查到状态的房间多半是刚加载，
  /// 放在未开播前面能避免它被误认为「肯定没播」而沉到底部。
  static int _statusRank(LiveStatus status) {
    switch (status) {
      case LiveStatus.live:
        return 0;
      case LiveStatus.unknown:
        return 1;
      case LiveStatus.offline:
        return 2;
      case LiveStatus.banned:
        return 3;
    }
  }
}
