library;

import 'dart:async';

import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';

/// 给所有没注册真实后端的平台兜底。
class MockLiveSource implements LiveSource {
  @override
  final LIVE_SITE_E site;

  MockLiveSource(this.site);

  /// 假弹幕内容，循环推送
  static const List<(String, String)> _fakeDanmaku = [
    ('路人甲', '这里是演示数据，接入真实后端后就能看到真正的弹幕了'),
    ('路人乙', '这个项目是开源的，可以自己实现 LiveSource 接平台'),
    ('路人丙', '666'),
    ('路人丁', '界面做得不错'),
    ('测试用户', '弹幕会在右侧滚动显示'),
  ];

  @override
  Future<int?> resolveRoomIdFromShareText(String text) async {
    // 演示版不解析任何分享链接，直接返回 null 让 UI 提示解析失败。
    return null;
  }

  @override
  String? extractUrlFromText(String text) {
    // 演示版不认任何平台链接，统一返回 null，走「无法识别」提示
    return null;
  }

  @override
  Future<LiveRoomInfo?> fetchRoomBrief(int roomId) async {
    final detail = await fetchRoom(roomId);
    return detail?.roomInfo;
  }

  @override
  Future<LiveRoomDetail?> fetchRoom(int roomId) async {
    // 模拟一点网络延迟，让加载动画能被看到
    await Future.delayed(const Duration(milliseconds: 600));

    final stream = LiveStreamInfo(
      name: '演示',
      rate: 0,
      bit: 1000,
      expire_at: 0,
      stream_url: [
        // 故意给一个不存在的地址：视频区会黑屏，但不会崩
        (LIVE_PROTOCOL_E.LIVE_PROTOCOL_HTTP_FLV, LIVE_CODEC_E.LIVE_CODEC_AVC_H264, 'https://example.invalid/demo.flv'),
      ],
    );

    final room = LiveRoomInfo(
      room_id: roomId,
      room_name: '演示直播间',
      owner_name: '演示主播',
      owner_profile_url: null,
      show_status: LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE,
      video_set: {
        LIVE_VIDEO_QUALITY.values.firstWhere((q) => q.name.startsWith(site.name.replaceFirst('LIVE_SITE_', '')), orElse: () => LIVE_VIDEO_QUALITY.UNKNOWN):
            stream,
      },
    )..live_site = site;

    return LiveRoomDetail(roomInfo: room, defaultStream: stream);
  }

  @override
  Future<LiveStreamInfo?> fetchStream(int roomId, LIVE_VIDEO_QUALITY quality) async {
    final detail = await fetchRoom(roomId);
    return detail?.defaultStream;
  }

  @override
  DanmakuConnection? connectDanmaku(int roomId, {required void Function(String nickname, String content) onMessage, void Function(Object error)? onError}) {
    var index = 0;
    // 每 2 秒推一条，循环播放
    final timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final (nickname, content) = _fakeDanmaku[index % _fakeDanmaku.length];
      index++;
      onMessage(nickname, content);
    });

    return _MockDanmakuConnection(timer);
  }
}

class _MockDanmakuConnection implements DanmakuConnection {
  final Timer _timer;

  _MockDanmakuConnection(this._timer);

  @override
  void dispose() {
    // Timer.cancel 可以重复调用，满足「dispose 要幂等」的约定
    _timer.cancel();
  }
}
