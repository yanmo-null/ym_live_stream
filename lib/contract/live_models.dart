/// 直播平台与后端之间的**数据契约**。
library;

/// 视频协议。
enum LIVE_PROTOCOL_E {
  /// HTTP-FLV，直播最常用，延迟最低
  LIVE_PROTOCOL_HTTP_FLV,

  /// HLS（TS 切片）
  LIVE_PROTOCOL_HLS_TS,

  /// HLS（fMP4 切片）
  LIVE_PROTOCOL_HLS_FMP4,
}

/// 视频编码格式。
enum LIVE_CODEC_E { LIVE_CODEC_AVC_H264, LIVE_PROTOCOL_HEVC_H265, LIVE_PROTOCOL_AV1 }

/// 支持的直播平台。
enum LIVE_SITE_E { LIVE_SITE_DOUYU, LIVE_SITE_BILIBILI, LIVE_SITE_DOUYIN, LIVE_SITE_HUYA, LIVE_SITE_KUAISHOU, LIVE_SITE_TWITCH }

/// 直播间开播状态。
///
/// 用枚举而不是 bool：未开播、被封禁、状态未知是三种不同情况，
/// 界面上要显示不同文案，重连策略也不一样。
enum LIVE_SHOW_STATUS_E { LIVE_SHOW_STATUS_LIVE, LIVE_SHOW_STATUS_OFFLINE, LIVE_SHOW_STATUS_BAN, LIVE_SHOW_STATUS_UNKNOWN }

/// 清晰度档位。
///
/// 各平台的档位不通用，所以按平台加前缀而不是共用一个「高清/超清」枚举。
enum LIVE_VIDEO_QUALITY {
  // 哔哩哔哩
  BILIBILI_DUBI,
  BILIBILI_4K,
  BILIBILI_2K,
  BILIBILI_YUANHUA,
  BILIBILI_LANGUANG,
  BILIBILI_CHAOQING,
  BILIBILI_GAOQING,

  // 斗鱼
  DOUYU_YUANHUA,
  DOUYU_LANGUANG,
  DOUYU_CHAOQING,
  DOUYU_GAOQING,

  // 抖音
  DOUYIN_YUANHUA,
  DOUYIN_LANGUANG,
  DOUYIN_CHAOQING,
  DOUYIN_GAOQING,
  DOUYIN_BIAOQING,

  //虎牙
  HUYA_LANGUANG_50M,
  HUYA_LANGUANG_20M,
  HUYA_LANGUANG_8M,
  HUYA_LANGUANG_4M,
  HUYA_CHAOQING,
  HUYA_LIUCHANG,

  //快手
  KUAISHOU_GAOQING,
  KUAISHOU_CHAOQING,
  KUAISHOU_LANGUANG,

  UNKNOWN,
}

/// 一条可播放的直播流。
class LiveStreamInfo {
  /// 清晰度的展示名（如「蓝光」）
  final String name;

  /// 码率档位（平台内部用，数值越大越清晰）
  final int rate;

  /// 码率（kbps）
  final int bit;

  /// 地址过期时间（Unix 秒）。
  ///
  /// 各平台给的时效不同，取不到时由后端给一个保守值（一般 30 分钟），
  /// 过期后重新拉取，避免播放到一半地址失效。
  int expire_at;

  /// 所属平台
  LIVE_SITE_E? live_site;

  /// 同一清晰度下的多条线路。
  ///
  /// 元组是 (协议, 编码, 地址)，协议或编码可能未知（null），
  /// 界面会据此显示「FLV · H.264」这样的线路说明。
  late List<(LIVE_PROTOCOL_E?, LIVE_CODEC_E?, String)> stream_url;

  LiveStreamInfo({required this.rate, required this.name, required this.bit, required this.expire_at, required this.stream_url});
}

/// 一个直播间的完整信息。
class LiveRoomInfo {
  /// 平台内部的真实房间号（部分平台和用户可见的房间号不是一回事）
  ///
  /// 例：B 站是 short_id，抖音是真实数字 room_id。
  late String? fake_room_id;

  /// 用户可见的房间号。
  ///
  /// 【为什么是 String 不是 int】
  /// 各平台的房间标识形态不一致：
  ///   * 斗鱼 / B站 / 抖音 → 纯数字
  ///   * 虎牙               → 数字，也支持主播别名（`chuhe`）
  ///   * 快手               → **带字母的短 id**（如 `3xz96kaifhw8ec4`），
  ///                          根本拿不到数字形态
  /// 所以这里统一用 String 存，各平台内部需要数字时自己转。
  final String room_id;

  final String? room_name;
  final String? owner_name;
  final String? owner_profile_url;

  late LIVE_SITE_E? live_site;
  late LIVE_SHOW_STATUS_E? show_status;

  /// 拉流时要带的请求头（防盗链）
  late Map<String, String> http_header;

  /// 该房间所有可用清晰度
  final Map<LIVE_VIDEO_QUALITY, LiveStreamInfo> video_set;

  /// 弹幕订阅需要的平台内部标识。
  ///
  /// 【为什么放在这里】有些平台的弹幕协议要求的不是用户可见的房间号，
  /// 而是房间页里才有的另一组数字。这些值在拉房间信息时就能顺手拿到，
  /// 存下来给弹幕客户端直接用，避免它自己再拉一次同一个页面。
  ///
  /// 虎牙：{主播 id, 频道号, 子频道号}（对应页面的 yyid / lChannelId / lSubChannelId）
  /// 其它平台暂时不用，保持 null。
  Map<String, int>? danmakuIds;

  /// 直播流 id —— 和 [room_id] 不是一回事。
  ///
  /// 【快手需要它】快手把「房间」和「这一场直播」分成两个 id：
  ///   * [room_id]       形如 `3xvsgfu2yrry8gu`，主播/房间的标识
  ///   * [live_stream_id] 形如 `gxOZNdGDweg`，本场直播的标识
  /// 弹幕 feed 接口要的是**后者**，传房间号拿不到弹幕。
  ///
  /// 其它平台（房号即场次标识）可保持 null。
  String? live_stream_id;

  LiveRoomInfo({
    required this.room_id,
    required this.room_name,
    required this.owner_name,
    required this.owner_profile_url,
    required this.show_status,
    required this.live_site,
    Map<LIVE_VIDEO_QUALITY, LiveStreamInfo>? video_set,
  }) : video_set = video_set ?? <LIVE_VIDEO_QUALITY, LiveStreamInfo>{};
}

/// 打开直播间时传的参数。
class LiveRoomArgs {
  /// 房间标识。数字或字母 id 都可能（见 [LiveRoomInfo.room_id] 的说明）。
  final String roomId;
  final LIVE_SITE_E site;
  final LIVE_VIDEO_QUALITY quality;

  const LiveRoomArgs({required this.roomId, required this.site, this.quality = LIVE_VIDEO_QUALITY.UNKNOWN});

  /// 房间标识是否看起来合法（非空、非纯空白）
  static bool isValidRoomId(String? id) => id != null && id.trim().isNotEmpty;

  /// 统一解析 Get.arguments，并在这里就把非法参数拦住
  factory LiveRoomArgs.fromDynamic(Object? args) {
    if (args is LiveRoomArgs) {
      if (!isValidRoomId(args.roomId)) throw ArgumentError('非法房间号: ${args.roomId}');
      return args;
    }
    // 兼容老调用方：直接用 int 传房间号（斗鱼/B站/抖音都这么用过）
    if (args is int) {
      if (args <= 0) throw ArgumentError('非法房间号: $args');
      return LiveRoomArgs(roomId: '$args', site: LIVE_SITE_E.LIVE_SITE_DOUYU);
    }
    if (args is Map) {
      final raw = args['roomId'] ?? args['room_id'];
      final roomId = raw?.toString().trim();
      if (!isValidRoomId(roomId)) throw ArgumentError('非法房间号: $raw');
      return LiveRoomArgs(
        roomId: roomId!,
        site: args['site'] is LIVE_SITE_E ? args['site'] as LIVE_SITE_E : _parseSite(args['site']?.toString()),
        quality: args['quality'] is LIVE_VIDEO_QUALITY ? args['quality'] as LIVE_VIDEO_QUALITY : LIVE_VIDEO_QUALITY.UNKNOWN,
      );
    }
    throw ArgumentError('打开直播间缺少参数(LiveRoomArgs)，实际收到: $args');
  }

  /// 从 URL 参数解析（深链接 / initialRoute / Get.parameters）
  factory LiveRoomArgs.fromParameters(Map<String, String?> params) {
    final raw = params['roomId'] ?? params['room_id'];
    final roomId = raw?.trim();
    if (!isValidRoomId(roomId)) {
      throw ArgumentError('URL 中缺少合法 roomId: $raw');
    }
    return LiveRoomArgs(roomId: roomId!, site: _parseSite(params['site']));
  }

  static LIVE_SITE_E _parseSite(String? name) => LIVE_SITE_E.values.firstWhere((e) => e.name == name, orElse: () => LIVE_SITE_E.LIVE_SITE_DOUYU);

  @override
  String toString() => 'LiveRoomArgs(roomId: $roomId, site: $site, quality: $quality)';
}

/// 一次「取直播间信息」的结果。
class LiveRoomDetail {
  final LiveRoomInfo roomInfo;

  /// 默认清晰度的流；可能为 null（未开播 / 该清晰度没有线路）
  final LiveStreamInfo? defaultStream;

  const LiveRoomDetail({required this.roomInfo, this.defaultStream});

  /// 按清晰度取流；取不到时回落到 defaultStream
  LiveStreamInfo? streamOf(LIVE_VIDEO_QUALITY quality) {
    final stream = roomInfo.video_set[quality];
    if (stream != null && stream.stream_url.isNotEmpty) return stream;
    return stream ?? defaultStream;
  }

  @override
  String toString() =>
      'LiveRoomDetail(room: ${roomInfo.room_name}, site: ${roomInfo.live_site}, '
      'qualities: ${roomInfo.video_set.length}, hasDefault: ${defaultStream != null})';
}
