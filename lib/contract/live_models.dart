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
enum LIVE_SITE_E { LIVE_SITE_DOUYU, LIVE_SITE_BILIBILI, LIVE_SITE_DOUYIN }

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
  final int expire_at;

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
  late int? fake_room_id;

  /// 用户可见的房间号
  final int room_id;

  final String? room_name;
  final String? owner_name;
  final String? owner_profile_url;

  late LIVE_SITE_E? live_site;
  late LIVE_SHOW_STATUS_E? show_status;

  /// 拉流时要带的请求头（防盗链）
  late Map<String, String> http_header;

  /// 该房间所有可用清晰度
  final Map<LIVE_VIDEO_QUALITY, LiveStreamInfo> video_set;

  LiveRoomInfo({
    required this.room_id,
    required this.room_name,
    required this.owner_name,
    required this.owner_profile_url,
    required this.show_status,
    Map<LIVE_VIDEO_QUALITY, LiveStreamInfo>? video_set,
  }) : video_set = video_set ?? <LIVE_VIDEO_QUALITY, LiveStreamInfo>{};
}

/// 打开直播间时传的参数。
class LiveRoomArgs {
  final int roomId;
  final LIVE_SITE_E site;
  final LIVE_VIDEO_QUALITY quality;

  const LiveRoomArgs({required this.roomId, required this.site, this.quality = LIVE_VIDEO_QUALITY.UNKNOWN});

  /// 统一解析 Get.arguments，并在这里就把非法参数拦住
  factory LiveRoomArgs.fromDynamic(Object? args) {
    if (args is LiveRoomArgs) {
      if (args.roomId <= 0) throw ArgumentError('非法房间号: ${args.roomId}');
      return args;
    }
    if (args is int) {
      if (args <= 0) throw ArgumentError('非法房间号: $args');
      return LiveRoomArgs(roomId: args, site: LIVE_SITE_E.LIVE_SITE_DOUYU);
    }
    if (args is Map) {
      final raw = args['roomId'] ?? args['room_id'];
      final roomId = raw is int ? raw : (raw == null ? null : int.tryParse('$raw'));
      if (roomId == null || roomId <= 0) throw ArgumentError('非法房间号: $raw');
      return LiveRoomArgs(
        roomId: roomId,
        site: args['site'] is LIVE_SITE_E ? args['site'] as LIVE_SITE_E : _parseSite(args['site']?.toString()),
        quality: args['quality'] is LIVE_VIDEO_QUALITY ? args['quality'] as LIVE_VIDEO_QUALITY : LIVE_VIDEO_QUALITY.UNKNOWN,
      );
    }
    throw ArgumentError('打开直播间缺少参数(LiveRoomArgs)，实际收到: $args');
  }

  /// 从 URL 参数解析（深链接 / initialRoute / Get.parameters）
  factory LiveRoomArgs.fromParameters(Map<String, String?> params) {
    final raw = params['roomId'] ?? params['room_id'];
    final roomId = raw == null ? null : int.tryParse(raw);
    if (roomId == null || roomId <= 0) {
      throw ArgumentError('URL 中缺少合法 roomId: $raw');
    }
    return LiveRoomArgs(roomId: roomId, site: _parseSite(params['site']));
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
