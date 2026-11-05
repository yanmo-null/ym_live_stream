/// UI 层访问直播后端时要实现的接口。
///
/// 【设计意图】
/// `lib/ui/` 下所有代码只允许 import 这个文件和 `live_models.dart`，
/// **不允许 import `lib/backend/` 下的任何东西**。
/// 这样后端代码可以整体私有化，UI 依然能独立编译、独立开源。
///
/// 【怎么接自己的后端】
/// 在 `main()` 里调用 [LiveSourceRegistry.register]，把实现注册进来：
///
/// ```dart
/// LiveSourceRegistry.register(BilibiliLiveSource());
/// LiveSourceRegistry.register(DouyuLiveSource());
/// ```
///
/// 不注册的话，UI 会自动回落到 `MockLiveSource`（假数据），
/// 保证开源仓库 clone 下来就能直接跑起来看界面。
library;

import 'live_models.dart';

/// 一个已连接的弹幕通道。
///
/// 【为什么是对象而不是 Stream】
/// 各平台的弹幕客户端都要自己维持长连接和重连，
/// 用对象包起来才能显式地「关闭」，避免页面退出后连接还挂着。
abstract class DanmakuConnection {
  /// 关掉连接并释放资源。必须支持重复调用（页面销毁时可能被调多次）。
  void dispose();
}

/// 单个平台的直播后端。
///
/// 每个平台（哔哩哔哩/斗鱼/抖音）各实现一份。
abstract class LiveSource {
  /// 这个实现负责哪个平台
  LIVE_SITE_E get site;

  /// 解析分享文本/链接得到房间号。
  ///
  /// 用于处理 `https://b23.tv/xxx`、`https://v.douyin.com/xxx` 这类短链：
  /// 从整段分享文字里抠出链接，跟随跳转拿到真实房间号。
  ///
  /// 返回 null 表示解析失败。已经是纯数字房间号的情况不需要走这里。
  Future<int?> resolveRoomIdFromShareText(String text);

  /// 把「主播别名」解析成真正的房间标识。
  ///
  /// 【为什么需要】虎牙的直播间地址支持主播自定义别名（`huya.com/chuhe`），
  /// 这种标识和数字房间号指向同一个房间。项目里房间号统一用 String 传递，
  /// 所以这一步只在搜索阶段把别名换成平台认可的房间标识。
  ///
  /// 默认实现返回 null，表示「本平台不支持别名」（斗鱼/B站/抖音房间号必为数字）。
  Future<String?> resolveRoomIdFromAlias(String alias) async => null;

  /// 从任意文本里抠出本平台的链接（纯本地正则，不联网）。
  ///
  /// 单独拆出来是为了让搜索框能先判断「这段文字里有没有本平台的链接」，
  /// 有才去联网解析短链，避免对随便一段文字都发起请求。
  /// 返回 null 表示文本里没有本平台的链接。
  String? extractUrlFromText(String text);

  /// 轻量探活：只取房间是否存在、是否在播、标题和主播名。
  ///
  /// 主页刷新关注列表时会逐房间调用，所以**不要**在这里拉完整视频流列表。
  /// 返回 null 表示这次没查到（网络问题/房间不存在）。
  Future<LiveRoomInfo?> fetchRoomBrief(String roomId);

  /// 拉取直播间信息（房间名、主播、可用清晰度列表）。
  ///
  /// 返回 null 表示确实取不到（房间不存在 / 已下播且无缓存）。
  /// 注意：房间存在但未开播时**不要**返回 null —— 应该返回带
  /// `show_status = OFFLINE` 的 [LiveRoomInfo]，由 UI 决定怎么提示。
  Future<LiveRoomDetail?> fetchRoom(String roomId);

  /// 拉取指定清晰度的流地址。
  ///
  /// 切换清晰度时单独调用，避免每次都重拉整份房间信息。
  /// [LIVE_VIDEO_QUALITY.UNKNOWN] 表示用平台默认档位。
  Future<LiveStreamInfo?> fetchStream(String roomId, LIVE_VIDEO_QUALITY quality);

  /// 连接弹幕。
  ///
  /// [onMessage] 每收到一条弹幕调用一次。
  /// [onError] 连接异常时调用（弹幕失败不应该影响视频播放）。
  /// [roomInfo] 调用方已经拿到的房间信息 —— 有的话就直接用它里面的
  /// `danmakuIds` / `http_header`，不用再拉一次同一个房间页。
  /// 传 null 表示没有缓存，平台可以自己去取。
  ///
  /// 返回 null 表示这个平台在这个房间不支持弹幕。
  DanmakuConnection? connectDanmaku(
    String roomId, {
    required void Function(String nickname, String content) onMessage,
    void Function(Object error)? onError,
    LiveRoomInfo? roomInfo,
  });
}

/// 后端实现的注册表。
///
/// 【为什么用注册而不是直接 new】
/// UI 层不能出现 `BilibiliPlatform()` 这样的写法，否则就绑死了具体实现。
/// 改成「谁想用谁注册」，开源版不注册任何实现，自然回落到 mock。
class LiveSourceRegistry {
  LiveSourceRegistry._();

  static final Map<LIVE_SITE_E, LiveSource> _sources = {};

  /// 注册一个平台的实现。重复注册会覆盖（方便热重载/切换实现）。
  static void register(LiveSource source) {
    _sources[source.site] = source;
  }

  /// 取某个平台的实现；没注册返回 null，由调用方决定如何处理。
  static LiveSource? find(LIVE_SITE_E site) => _sources[site];

  /// 是否注册了某个平台的实现
  static bool has(LIVE_SITE_E site) => _sources.containsKey(site);

  /// 已注册的平台数量（启动时打日志用）
  static int get registeredCount => _sources.length;

  /// 清空注册（测试用）
  static void clear() => _sources.clear();
}
