/// UI 层访问直播后端时要实现的接口。
library;

import 'live_models.dart';

/// 一个已连接的弹幕通道。
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
  Future<int?> resolveRoomIdFromShareText(String text);

  /// 从任意文本里抠出本平台的链接（纯本地正则，不联网）。
  String? extractUrlFromText(String text);

  /// 轻量探活：只取房间是否存在、是否在播、标题和主播名。
  Future<LiveRoomInfo?> fetchRoomBrief(int roomId);

  /// 拉取直播间信息（房间名、主播、可用清晰度列表）。
  Future<LiveRoomDetail?> fetchRoom(int roomId);

  /// 拉取指定清晰度的流地址。
  Future<LiveStreamInfo?> fetchStream(int roomId, LIVE_VIDEO_QUALITY quality);

  /// 连接弹幕。
  DanmakuConnection? connectDanmaku(int roomId, {required void Function(String nickname, String content) onMessage, void Function(Object error)? onError});
}

/// 后端实现的注册表。
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
