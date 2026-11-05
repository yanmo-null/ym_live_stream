import 'package:ym_live_stream/contract/live_models.dart';

/// 平台的展示信息、房间号规则、URL 识别规则。
///
/// 集中在这里，新增平台时只要在 [LiveSites] 加一条。
class LiveSiteMeta {
  final LIVE_SITE_E site;

  /// 下拉框/卡片上展示的名字
  final String displayName;

  /// 平台图标资源路径
  final String iconAsset;

  /// 房间号合法长度区间（含端点）。
  ///
  /// 各平台规则不同，所以不做全局统一限制：
  /// 哔哩哔哩短号可以只有 3 位，抖音 web_rid 是 12 位。
  final int minRoomIdLen;
  final int maxRoomIdLen;

  /// 官方域名关键字，用于从 URL 自动识别平台
  final List<String> domainKeywords;

  /// 是否允许「字母」当房间号。
  ///
  /// 虎牙（`chuhe`）和快手（`3xz96kaifhw8ec4`）都允许。
  /// 其它平台（斗鱼/B站/抖音）的房间号一定是纯数字，保持 false。
  ///
  /// 字母 id 怎么变成可用的房间标识，交给各平台的
  /// [LiveSource.resolveRoomIdFromAlias] 决定：
  ///   * 虎牙要换成数字（别名不是真房间号）；
  ///   * 快手原样返回（id 本身就能用）。
  final bool allowAlphaRoomId;

  const LiveSiteMeta({
    required this.site,
    required this.displayName,
    required this.iconAsset,
    required this.minRoomIdLen,
    required this.maxRoomIdLen,
    required this.domainKeywords,
    this.allowAlphaRoomId = false,
  });

  /// 房间号是否合法。
  ///
  /// 默认要求「纯数字 + 长度在区间内」；[allowAlphaRoomId] 为 true 的平台
  /// 额外接受「数字字母混排」的 id。
  bool isValidRoomId(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;

    // 纯数字：按长度区间校验
    if (RegExp(r'^\d+$').hasMatch(text)) {
      return text.length >= minRoomIdLen && text.length <= maxRoomIdLen;
    }

    // 非纯数字：只有允许别名的平台才放行。
    // 限制成「数字或字母开头 + 3~32 位字母数字下划线短横线」，
    // 避免把乱输的内容（比如网址片段）当成房间号发出去。
    //
    // 【不能强制字母开头】快手的 id 是数字字母混排且经常数字开头
    // （如 `3xvsgfu2yrry8gu`），强制 [A-Za-z] 开头会把它挡掉。
    // 上面已经排除了纯数字，这里只要「含字母且字符集合法」就够了。
    if (!allowAlphaRoomId) return false;
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{2,31}$').hasMatch(text);
  }

  String get roomIdRuleHint => allowAlphaRoomId
      ? '$displayName 房间号为数字，或平台给出的字母数字 id'
      : '$displayName 房间号为 $minRoomIdLen~$maxRoomIdLen 位数字';
}

/// 平台元数据表。新增平台在这里追加一项。
class LiveSites {
  LiveSites._();

  static const LiveSiteMeta bilibili = LiveSiteMeta(
    site: LIVE_SITE_E.LIVE_SITE_BILIBILI,
    displayName: '哔哩哔哩',
    iconAsset: 'assets/icon/bilibili_logo.png',
    minRoomIdLen: 3,
    maxRoomIdLen: 12,
    domainKeywords: ['bilibili.com', 'b23.tv'],
  );

  static const LiveSiteMeta douyu = LiveSiteMeta(
    site: LIVE_SITE_E.LIVE_SITE_DOUYU,
    displayName: '斗鱼',
    iconAsset: 'assets/icon/douyu_logo.png',
    minRoomIdLen: 3,
    maxRoomIdLen: 12,
    domainKeywords: ['douyu.com', 'douyu.tv'],
  );

  static const LiveSiteMeta douyin = LiveSiteMeta(
    site: LIVE_SITE_E.LIVE_SITE_DOUYIN,
    displayName: '抖音',
    iconAsset: 'assets/icon/douyin_logo.png',
    minRoomIdLen: 6,
    maxRoomIdLen: 20,
    // amemv.com 是抖音分享页的真实落点，用户从 App 复制出来的链接可能直接就是它
    domainKeywords: ['douyin.com', 'iesdouyin.com', 'amemv.com'],
  );

  static const LiveSiteMeta huya = LiveSiteMeta(
    site: LIVE_SITE_E.LIVE_SITE_HUYA,
    displayName: '虎牙',
    iconAsset: 'assets/icon/huya_logo.png',
    minRoomIdLen: 3,
    maxRoomIdLen: 12,
    domainKeywords: ['huya.com'],
    // 虎牙支持主播别名（/chuhe），要换成数字房间号才能用
    allowAlphaRoomId: true,
  );

  static const LiveSiteMeta kuaishou = LiveSiteMeta(
    site: LIVE_SITE_E.LIVE_SITE_KUAISHOU,
    displayName: '快手',
    iconAsset: 'assets/icon/kuaishou_logo.png',
    // 快手的房间 id 形如 3xz96kaifhw8ec4（15 位左右），但也有纯数字的老房间
    minRoomIdLen: 3,
    maxRoomIdLen: 32,
    domainKeywords: ['kuaishou.com', 'gifshow.com', 'chenzhongtech.com'],
    // 快手的 id 带字母（3xz96kaifhw8ec4），而且这个 id 本身就是房间标识
    allowAlphaRoomId: true,
  );

  /// 下拉框展示顺序：默认选中第一项（哔哩哔哩）
  static const List<LiveSiteMeta> all = [bilibili, douyu, douyin, huya, kuaishou];

  static const LiveSiteMeta defaultSite = bilibili;

  static LiveSiteMeta of(LIVE_SITE_E site) => all.firstWhere((e) => e.site == site, orElse: () => defaultSite);

  /// 根据 URL 的 host 识别平台；识别不出返回 null
  static LiveSiteMeta? detectByUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    for (final meta in all) {
      for (final keyword in meta.domainKeywords) {
        if (host == keyword || host.endsWith('.$keyword')) return meta;
      }
    }
    return null;
  }
}
