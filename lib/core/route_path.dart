/// 路由路径
class RoutePath {
  /// 首页
  static const p_home = "/home";

  /// 直播间
  static const p_liveroom = "/liveroom/detail";

  /// 直播间（可深链接/可从 initialRoute 直达：/liveroom/deep/6925114?site=douyu）
  static const p_liveroom_deep = "/liveroom/deep/:roomId";

  /// 弹幕设置
  static const p_settings_danmu = "/settings/danmu";

  /// 直播间设置
  static const p_settings_live = "/settings/live";

  /// 弹幕关键词屏蔽
  static const p_settings_danmu_shield = "/settings/danmu/shield";

  /// 其他设置
  static const p_settings_other = "/settings/other";

  /// 赞助
  static const p_sponsor = "/sponsor";

  /// 我的收藏
  static const p_collection = "/user/collection";
}
