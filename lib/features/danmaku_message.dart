import 'package:ym_live_stream/features/live_common.dart';

/// 三端（斗鱼 / 抖音 / B 站）统一的弹幕消息模型。
class DanmakuMessage {
  /// 发送者昵称
  final String nickname;

  /// 弹幕正文
  final String content;

  /// 来自哪个平台（用于右侧栏着色/角标）
  final LIVE_SITE_E? site;

  /// 收到时间（本地时钟），用于排序和「同秒去重」
  final DateTime receivedAt;

  DanmakuMessage({required this.nickname, required this.content, this.site, DateTime? receivedAt}) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String toString() => '[$nickname] $content';
}
