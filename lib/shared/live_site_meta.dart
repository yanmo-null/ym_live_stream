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

  const LiveSiteMeta({
    required this.site,
    required this.displayName,
    required this.iconAsset,
    required this.minRoomIdLen,
    required this.maxRoomIdLen,
    required this.domainKeywords,
  });

  /// 房间号是否合法（纯数字 + 长度在区间内）
  bool isValidRoomId(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    if (!RegExp(r'^\d+$').hasMatch(text)) return false;
    return text.length >= minRoomIdLen && text.length <= maxRoomIdLen;
  }

  String get roomIdRuleHint => '$displayName 房间号为 $minRoomIdLen~$maxRoomIdLen 位数字';
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

  /// 下拉框展示顺序：默认选中第一项（哔哩哔哩）
  static const List<LiveSiteMeta> all = [bilibili, douyu, douyin];

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
