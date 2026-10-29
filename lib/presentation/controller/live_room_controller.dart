import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';
import 'package:ym_live_stream/mock/mock_live_source.dart';
import 'package:ym_live_stream/core/platform_support.dart';
import 'package:ym_live_stream/core/route_path.dart';
import 'package:ym_live_stream/features/danmaku_message.dart';
import 'package:ym_live_stream/features/favorite_store.dart';

class LiveStreamController extends GetxController {
  LiveStreamController({required this.args});

  final LiveRoomArgs args;
  int get roomId => args.roomId;
  LIVE_SITE_E get site => args.site;

  LiveSource? get _source => LiveSourceRegistry.find(site) ?? _mockFor(site);

  /// 各平台的 mock 兜底实例，按平台缓存一份，避免每次新建
  static final Map<LIVE_SITE_E, LiveSource> _mockCache = {};

  static LiveSource _mockFor(LIVE_SITE_E site) => _mockCache.putIfAbsent(site, () => MockLiveSource(site));

  final isLoading = false.obs;
  final roomInfo = Rxn<LiveRoomInfo>();
  final roomDetail = Rxn<LiveRoomDetail>();
  final defaultStream = Rxn<LiveStreamInfo>();
  final loadError = RxnString();

  final roomShowStatus = Rxn<LIVE_SHOW_STATUS_E>();

  final isFavorited = false.obs;

  final isSpecialFollowed = false.obs;

  /// 进房请求超时：避免某些平台吞包导致永远转圈
  static const _kFetchTimeout = Duration(seconds: 15);

  final isPlaying = true.obs;
  final isDanmakuOn = true.obs;
  final showControls = true.obs;

  final isQualityMenuOpen = false.obs;

  final danmakuList = <DanmakuMessage>[].obs;

  /// 待刷新的弹幕缓冲（普通 List，不触发任何重建）。
  final List<DanmakuMessage> _danmakuBuffer = [];

  /// 节流刷新的定时器；为空表示当前没有待刷新的内容。
  Timer? _danmakuFlushTimer;

  /// 弹幕 UI 刷新间隔。
  static const Duration _kDanmakuFlushInterval = Duration(milliseconds: 200);

  final danmakuConnected = false.obs;

  /// 弹幕客户端连接状态文案（首测阶段方便定位是哪一端没连上）
  final danmakuStatus = ''.obs;

  DanmakuConnection? _danmakuConnection;

  int? _danmakuRoomId;

  /// 是否正在关闭中：关页时弹幕回调可能仍在触发，用它拦住往已销毁的列表里塞数据。
  bool _danmakuStopping = false;

  /// 列表上限：弹幕是持续流入的，不设上限会一直涨内存。
  static const int _kDanmakuMaxCount = 200;

  /// 入队一条弹幕（三个平台的回调都收到这里）。

  void _appendDanmaku(String nickname, String content, LIVE_SITE_E site) {
    if (_danmakuStopping || _disposed) return;
    final text = content.trim();
    if (text.isEmpty) return;

    _danmakuBuffer.add(DanmakuMessage(nickname: nickname, content: text, site: site));
    if (_danmakuBuffer.length > _kDanmakuMaxCount * 2) {
      _danmakuBuffer.removeRange(0, _danmakuBuffer.length - _kDanmakuMaxCount);
    }

    if (!danmakuConnected.value) {
      danmakuConnected.value = true;
      danmakuStatus.value = '${_danmakuStatusText()}弹幕：已连接';
    }

    _scheduleDanmakuFlush();
  }

  /// 安排一次延迟刷新：窗口内收到的弹幕会在下一次 flush 时一次性推给 UI。
  void _scheduleDanmakuFlush() {
    _danmakuFlushTimer ??= Timer(_kDanmakuFlushInterval, _flushDanmaku);
  }

  /// 把缓冲区里的弹幕合并进 [danmakuList]（一次赋值 = 一次 UI 重建）。
  void _flushDanmaku() {
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    if (_disposed) return;

    final merged = <DanmakuMessage>[...danmakuList, ..._danmakuBuffer];
    _danmakuBuffer.clear();

    danmakuList.value = merged.length > _kDanmakuMaxCount ? merged.sublist(merged.length - _kDanmakuMaxCount) : merged;
  }

  void _stopDanmaku() {
    _danmakuStopping = true;

    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _danmakuBuffer.clear();

    _danmakuConnection?.dispose();
    _danmakuConnection = null;
    _danmakuRoomId = null;

    danmakuConnected.value = false;
    danmakuStatus.value = '';
  }

  Future<void> _startDanmaku() async {
    if (_disposed) return;
    final info = roomInfo.value;
    if (info == null) return;
    if (roomShowStatus.value != null) return;

    if (_danmakuConnection != null && _danmakuRoomId == info.room_id) {
      return;
    }

    _stopDanmaku();
    _danmakuStopping = false;

    final source = _source;
    if (source == null) {
      danmakuStatus.value = '${_danmakuStatusText()}弹幕：没有可用的后端实现';
      return;
    }

    final danmakuRoomId = info.room_id;
    if (danmakuRoomId <= 0) {
      danmakuStatus.value = '${_danmakuStatusText()}弹幕：拿不到房间号，跳过';
      return;
    }

    _danmakuRoomId = danmakuRoomId;

    final stopwatch = Stopwatch()..start();
    try {
      danmakuStatus.value = '${_danmakuStatusText()}弹幕：连接中…';

      _danmakuConnection = source.connectDanmaku(
        danmakuRoomId,
        onMessage: (nickname, content) => _appendDanmaku(nickname, content, site),
        onError: (e) {
          if (_danmakuStopping || _disposed) return;
          danmakuConnected.value = false;
          danmakuStatus.value = '${_danmakuStatusText()}弹幕异常: $e';
          Get.log('[弹幕/${_danmakuStatusText()}] $e', isError: true);
        },
      );

      Get.log('[$runtimeType] 弹幕客户端已启动(${_danmakuStatusText()}) ${stopwatch.elapsedMilliseconds}ms：${danmakuStatus.value}');
    } catch (e, stack) {
      danmakuConnected.value = false;
      danmakuStatus.value = '弹幕连接失败: $e';
      Get.log('[$runtimeType] 弹幕连接失败: $e\n$stack', isError: true);
    }
  }

  String _danmakuStatusText() => switch (site) {
    LIVE_SITE_E.LIVE_SITE_DOUYU => '斗鱼',
    LIVE_SITE_E.LIVE_SITE_BILIBILI => 'B站',
    LIVE_SITE_E.LIVE_SITE_DOUYIN => '抖音',
  };

  /// 手动清空右侧栏弹幕
  void clearDanmaku() {
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _danmakuBuffer.clear();
    danmakuList.clear();
  }

  final Player player = Player(
    configuration: const PlayerConfiguration(
      title: 'YM Live Stream',
      logLevel: MPVLogLevel.error,
      bufferSize: 16 * 1024 * 1024,
    ),
  );

  /// 交给 Video widget 渲染
  VideoController? _videoController;

  final Completer<VideoController> _videoControllerReady = Completer<VideoController>();

  final Completer<void> _videoSurfaceLaidOut = Completer<void>();

  bool _videoSurfaceLaidOutNotified = false;

  void notifyVideoSurfaceLaidOut() {
    if (_videoSurfaceLaidOutNotified) return;
    _videoSurfaceLaidOutNotified = true;
    if (!_videoSurfaceLaidOut.isCompleted) _videoSurfaceLaidOut.complete();
  }

  /// 页面用来判断「还有没有必要再排一个 post-frame 通知」，避免重建时反复入队。
  bool get videoSurfaceLaidOutNotified => _videoSurfaceLaidOutNotified;

  /// 解码器硬解开关。
  static String get _kHwdec => forceSoftwareDecoding ? 'no' : hwdecForPlatform();

  /// 按平台决定解码器硬解模式。

  static String hwdecForPlatform() {
    return 'auto';
  }

  static const bool forceSoftwareDecoding = true;

  /// 是否启用 GPU 渲染（media_kit 把画面交给 Flutter 的方式）。
  static bool get _kEnableHardwareAcceleration => !forceSoftwareDecoding;

  /// 交给 Video widget 渲染（首次访问时才真正创建）
  VideoController get videoController {
    final existing = _videoController;
    if (existing != null) return existing;

    final created = VideoController(
      player,
      configuration: VideoControllerConfiguration(hwdec: _kHwdec, enableHardwareAcceleration: _kEnableHardwareAcceleration),
    );
    _videoController = created;

    if (!_videoControllerReady.isCompleted) _videoControllerReady.complete(created);
    return created;
  }

  /// 用户当前选中的清晰度（null = 跟随平台默认，例如 B 站蓝光 / 抖音蓝光 / 斗鱼默认）
  final selectedQuality = Rxn<LIVE_VIDEO_QUALITY>();

  /// 音量 0~100（media_kit 的 setVolume 就是 0~100 的 double）
  final volume = 100.0.obs;

  /// 切换清晰度时的 loading（避免连点）
  final isSwitchingQuality = false.obs;

  /// 播放器侧的错误提示
  final playError = RxnString();

  /// 缓冲中（UI 上盖一个转圈）
  final isBuffering = false.obs;

  double _lastVolume = 100;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;

  StreamSubscription<bool>? _completedSub;

  /// 【临时】诊断用，onClose 后不要再打日志
  bool _disposed = false;

  static const int _kMaxReconnectAttempts = 5;

  static const Duration _kStablePlaybackThreshold = Duration(seconds: 10);

  static const Duration _kOpenTimeout = Duration(seconds: 15);

  /// 重连退避计时器
  Timer? _reconnectTimer;

  /// 连续重连次数
  int _reconnectAttempts = 0;

  DateTime? _roundStartedAt;

  bool _hasPlayedOnce = false;

  /// 用户主动暂停时不该触发重连
  bool _userPaused = false;

  /// 当前应该播放的流：优先用户选的清晰度，其次平台默认流，最后任取一条有地址的
  LiveStreamInfo? get playingStream {
    final detail = roomDetail.value;
    if (detail == null) return defaultStream.value;

    final quality = selectedQuality.value ?? args.quality;
    if (quality != LIVE_VIDEO_QUALITY.UNKNOWN) {
      final picked = detail.roomInfo.video_set[quality];
      if (picked != null && picked.stream_url.isNotEmpty) return picked;
    }

    final def = detail.defaultStream;
    if (def != null && def.stream_url.isNotEmpty) return def;

    for (final stream in detail.roomInfo.video_set.values) {
      if (stream.stream_url.isNotEmpty) return stream;
    }
    return null;
  }

  List<LIVE_VIDEO_QUALITY> get availableQualities {
    final videoSet = roomDetail.value?.roomInfo.video_set ?? roomInfo.value?.video_set;
    if (videoSet == null || videoSet.isEmpty) return const [];

    return LIVE_VIDEO_QUALITY.values.where((q) => q != LIVE_VIDEO_QUALITY.UNKNOWN).where((q) => videoSet.containsKey(q)).toList(growable: false);
  }

  /// 正在播放的清晰度（用于 UI 显示当前选中项）
  LIVE_VIDEO_QUALITY? get currentQuality {
    final stream = playingStream;
    if (stream == null) return null;
    final videoSet = roomDetail.value?.roomInfo.video_set;
    if (videoSet != null) {
      for (final entry in videoSet.entries) {
        if (identical(entry.value, stream)) return entry.key;
      }
    }
    return selectedQuality.value;
  }

  /// 清晰度在 UI 上的名字：优先用平台返回的名字（原画/蓝光/超清…），兜底用枚举名
  String qualityName(LIVE_VIDEO_QUALITY quality) {
    final videoSet = roomDetail.value?.roomInfo.video_set ?? roomInfo.value?.video_set;
    final name = videoSet?[quality]?.name;
    if (name != null && name.isNotEmpty && name != '未知') return name;
    return quality.name.split('_').last;
  }

  @override
  void onInit() {
    super.onInit();

    _playingSub = player.stream.playing.listen((playing) {
      isPlaying.value = playing;
      if (playing) {
        _hasPlayedOnce = true;
      }
    });
    _bufferingSub = player.stream.buffering.listen((buffering) => isBuffering.value = buffering);
    _errorSub = player.stream.error.listen((error) {
      Get.log('[播放器] $error', isError: true);

      final actuallyPlaying = player.state.playing;
      if (!actuallyPlaying) {
        playError.value = error;
      } else {
        Get.log('[$runtimeType] 播放中收到错误输出，仅记录日志、不上屏: $error');
      }

      if (_hasPlayedOnce && !actuallyPlaying) {
        _scheduleReconnect('播放错误');
      }
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (!completed) return;
      Get.log('[播放器] 流已结束(EOF)，尝试重连');
      _scheduleReconnect('流已结束');
    });

    unawaited(player.setVolume(volume.value));

    _initBackendLogic();
  }

  /// 当前播放的第几轮起播（切清晰度会重新 open，诊断只针对最新那一轮）
  int _openEpoch = 0;

  static final RegExp _kNetworkErrorPattern = RegExp(
    r'tcp|ffurl_write|connection reset|reset by peer|broken pipe|'
    r'failed to open|could not open|network is unreachable|'
    r'connection refused|timed out|0xffffd8',
    caseSensitive: false,
  );

  bool _isNetworkPlayError(String? error) => error != null && _kNetworkErrorPattern.hasMatch(error);

  Future<void> _probeFirstFrame(int epoch) async {
    const timeout = Duration(seconds: 30);

    final VideoController controller;
    try {
      controller = await _videoControllerReady.future.timeout(timeout);
    } on TimeoutException {
      if (_disposed || epoch != _openEpoch) return;
      Get.log('[播放器] 30s 内页面仍未创建 Video widget，纹理未注册', isError: true);
      return;
    }

    try {
      await controller.waitUntilFirstFrameRendered.timeout(timeout);
      if (_disposed || epoch != _openEpoch) return;
      Get.log('[播放器] 首帧已渲染，纹理 ID = ${controller.id.value}');
    } on TimeoutException {
      if (_disposed || epoch != _openEpoch) return;
      final id = controller.id.value;
      Get.log('[播放器] 30s 没有首帧，纹理 ID = ${id ?? "(null)"}，playError = ${playError.value ?? "(无)"}', isError: true);

      if (_isNetworkPlayError(playError.value)) {
        Get.log('[$runtimeType] 判定为网络层错误，改走重连换新地址', isError: true);
        _scheduleReconnect('首帧前网络错误');
        return;
      }

      if (playError.value == null) {
        playError.value = '画面未能渲染（该流可能是 H.265/FLV 等当前播放器不支持的编码）';
      }
      return;
    } catch (e) {
      if (_disposed || epoch != _openEpoch) return;
      Get.log('[播放器] 首帧等待异常: $e；纹理 ID = ${controller.id.value}', isError: true);
      return;
    }
  }

  @override
  void onReady() {
    super.onReady();
    final err = loadError.value;
    if (err != null) Get.snackbar('错误', err);
  }

  @override
  void onClose() {
    _disposed = true;

    _restoreWindowOnLeave();
    _stopDanmaku();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _reconnectTimer?.cancel();
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;

    player
        .stop()
        .then((_) {
          return player.dispose();
        })
        .catchError((_) {
          return player.dispose();
        });

    super.onClose();
  }

  Future<void> _initBackendLogic() async {
    if (isLoading.value) {
      Get.log('[$runtimeType] 忽略重复请求: $args');
      return;
    }

    if (roomId <= 0) {
      loadError.value = '房间号非法: $roomId';
      roomInfo.value = null;
      roomDetail.value = null;
      return;
    }

    isLoading.value = true;
    loadError.value = null;

    final stopwatch = Stopwatch()..start();
    Get.log('[$runtimeType] 开始获取直播间: $args');

    try {
      final live_room_information = await _fetchRoomInfo().timeout(
        _kFetchTimeout,
        onTimeout: () => throw TimeoutException('请求超时(${_kFetchTimeout.inSeconds}s)'),
      );

      if (live_room_information == null) {
        throw Exception('程序出错，未获取到直播间信息（可能平台选择错误或者该房间号不存在）');
      }

      final showStatus = live_room_information.roomInfo.show_status ?? LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN;
      switch (showStatus) {
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN:
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE:
          _onRoomNotLive(showStatus, live_room_information.roomInfo, stopwatch);
          return;
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE:
          break;
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN:
        default:
          throw Exception('程序出错，未获取到直播间信息（可能平台选择错误或者该房间号不存在）');
      }

      roomShowStatus.value = null;
      roomDetail.value = live_room_information;
      roomInfo.value = live_room_information.roomInfo;
      defaultStream.value = live_room_information.defaultStream;
      _syncFavoriteState();

      await _openCurrentStream();

      unawaited(_startDanmaku());

      Get.log(
        '[${runtimeType}] 获取成功 ${stopwatch.elapsedMilliseconds}ms: '
        '${live_room_information.roomInfo.room_name} / ${live_room_information.roomInfo.owner_name} / '
        '清晰度 ${live_room_information.roomInfo.video_set.length} 个 / '
        '默认流 ${live_room_information.defaultStream != null} / '
        '可切清晰度 ${availableQualities.length} 个',
      );
    } on TimeoutException catch (e) {
      _onLoadFailed('连接超时，请检查网络或稍后重试', e, stopwatch);
    } on ArgumentError catch (e) {
      _onLoadFailed('直播间参数错误: ${e.message}', e, stopwatch);
    } catch (e, stack) {
      _onLoadFailed('获取直播间信息失败: $e', e, stopwatch, stack: stack);
    } finally {
      isLoading.value = false;
      stopwatch.stop();
    }
  }

  /// 统一收口失败状态，避免每处都重复写 4 行
  void _onLoadFailed(String message, Object error, Stopwatch stopwatch, {StackTrace? stack}) {
    roomInfo.value = null;
    roomDetail.value = null;
    defaultStream.value = null;
    roomShowStatus.value = null;
    isFavorited.value = false;
    isSpecialFollowed.value = false;
    loadError.value = message;
    unawaited(player.stop());
    Get.log(
      '[${runtimeType}] 获取失败 ${stopwatch.elapsedMilliseconds}ms: $message'
      '${stack == null ? '' : '\n$stack'}',
      isError: true,
    );
    _abortWithDialog('无法进入直播间', message);
  }

  void _onRoomNotLive(LIVE_SHOW_STATUS_E status, LiveRoomInfo room, Stopwatch stopwatch) {
    roomInfo.value = null;
    roomDetail.value = null;
    defaultStream.value = null;
    loadError.value = null;
    unawaited(player.stop());
    roomShowStatus.value = status;
    Get.log('[$runtimeType] 直播间未开播/不可用 ${stopwatch.elapsedMilliseconds}ms: ${_showStatusText(status)}');
    _abortWithDialog('无法进入直播间', '${_showStatusText(status)}${(room.owner_name ?? '').isEmpty ? '' : '\n${room.owner_name}'}');
  }

  bool _abortDialogShown = false;

  void _abortWithDialog(String title, String content) {
    if (_abortDialogShown || _disposed) return;
    _abortDialogShown = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final navigator = Get.key.currentState;
      if (navigator == null) return;
      Get.dialog<void>(
        AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Text(content, style: const TextStyle(fontSize: 14)),
          actions: [TextButton(onPressed: () => Get.back(), child: const Text('知道了'))],
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.only(right: 12, bottom: 8),
        ),
        barrierDismissible: false,
      ).then((_) {
        if (_disposed) return;
        _leaveRoomPage();
      });
    });
  }

  void _leaveRoomPage() {
    final navigator = Get.key.currentState;
    if (navigator != null && navigator.canPop()) {
      Get.back();
      return;
    }
    Get.offAllNamed(RoutePath.p_home);
  }

  /// 状态文案：只在这里维护一份，页面直接用
  String _showStatusText(LIVE_SHOW_STATUS_E status) {
    return switch (status) {
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE => '直播中',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE => '主播未开播',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN => '直播间已被封禁',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN => '直播间状态未知',
    };
  }

  Future<LiveRoomDetail?> _fetchRoomInfo() async {
    final source = _source;
    if (source == null) {
      throw Exception('没有可用的后端实现：${site.name}');
    }
    return source.fetchRoom(roomId);
  }

  Future<void> reload() {
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _userPaused = false;
    return _initBackendLogic();
  }

  void _syncFavoriteState() {
    final info = roomInfo.value;
    final id = _favoriteRoomId(info);
    if (id == null) {
      isFavorited.value = false;
      isSpecialFollowed.value = false;
      return;
    }
    isFavorited.value = FavoriteStore.instance.contains(site, id);
    isSpecialFollowed.value = isFavorited.value && FavoriteStore.instance.isSpecialFollowed(site, id);
  }

  int? _favoriteRoomId(LiveRoomInfo? info) {
    if (info == null) return null;
    final id = info.room_id > 0 ? info.room_id : info.fake_room_id;
    if (id == null || id <= 0) return null;
    return id;
  }

  Future<void> toggleFavorite() async {
    final info = roomInfo.value;
    final id = _favoriteRoomId(info);
    if (info == null || id == null) {
      Get.snackbar('关注失败', '还没有拿到直播间信息，稍后再试');
      return;
    }

    if (FavoriteStore.instance.contains(site, id)) {
      await FavoriteStore.instance.remove(site, id);
      isFavorited.value = false;
      isSpecialFollowed.value = false;
      return;
    }

    await FavoriteStore.instance.add(
      FavoriteRoom(
        roomId: id,
        fakeRoomId: info.fake_room_id,
        roomName: info.room_name ?? '',
        ownerName: info.owner_name ?? '',
        ownerProfileUrl: info.owner_profile_url ?? '',
        site: site,
        specialFollowed: false,
      ),
    );
    isFavorited.value = true;
    isSpecialFollowed.value = false;
  }

  Future<void> toggleSpecialFollow() async {
    final info = roomInfo.value;
    final id = _favoriteRoomId(info);
    if (info == null || id == null) {
      Get.snackbar('操作失败', '还没有拿到直播间信息，稍后再试');
      return;
    }

    final next = !isSpecialFollowed.value;

    if (!FavoriteStore.instance.contains(site, id)) {
      await FavoriteStore.instance.add(
        FavoriteRoom(
          roomId: id,
          fakeRoomId: info.fake_room_id,
          roomName: info.room_name ?? '',
          ownerName: info.owner_name ?? '',
          ownerProfileUrl: info.owner_profile_url ?? '',
          site: site,
          specialFollowed: true,
        ),
      );
      isFavorited.value = true;
      isSpecialFollowed.value = true;
      return;
    }

    await FavoriteStore.instance.setSpecialFollowed(site, id, next);
    isSpecialFollowed.value = next;
    isFavorited.value = true;
  }

  /// 断流后安排一次重连（带退避）。重复调用只保留先来的那一次。
  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    if (_reconnectTimer != null) return;
    if (_userPaused) return;
    if (isSwitchingQuality.value) return;
    if (isLoading.value) return;
    if (roomInfo.value == null && !_hasPlayedOnce) return;
    if (roomShowStatus.value != null) return;

    final startedAt = _roundStartedAt;
    if (startedAt != null && DateTime.now().difference(startedAt) >= _kStablePlaybackThreshold) {
      _reconnectAttempts = 0;
    }
    _roundStartedAt = null;

    if (_reconnectAttempts >= _kMaxReconnectAttempts) {
      Get.log('[$runtimeType] $reason，但重连次数已达上限($_kMaxReconnectAttempts)，放弃', isError: true);
      playError.value = '直播流已中断，请点击重试';
      return;
    }

    _reconnectAttempts++;
    final seconds = 1 << (_reconnectAttempts - 1).clamp(0, 3).toInt();
    Get.log('[$runtimeType] $reason ⇒ 第 $_reconnectAttempts/$_kMaxReconnectAttempts 次重连，${seconds}s 后重取地址');

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      unawaited(_reconnectStream());
    });
  }

  Future<void> _reconnectStream() async {
    if (_disposed) return;
    if (isLoading.value) return;
    Get.log('[$runtimeType] 开始重连：重新获取直播间信息以换取新的播放地址');
    await _initBackendLogic();
    if (_disposed) return;
    if (loadError.value != null) {
      Get.log('[$runtimeType] 重连拉取房间信息失败: ${loadError.value}');
      _scheduleReconnect('重连失败');
    }
  }

  /// 用当前选中的流打开播放器（切清晰度其实就是换一条 URL 重新 open）
  Future<void> _openCurrentStream() async {
    final stream = playingStream;
    if (stream == null) {
      playError.value = '没有可用的播放地址（可能未开播）';
      return;
    }

    final url = _pickPlayableUrl(stream, currentLine);
    if (url == null) {
      playError.value = '当前清晰度没有可用的线路';
      return;
    }

    playError.value = null;
    debugPrint('[$runtimeType] 起播: ${stream.name} -> $url');

    final epoch = ++_openEpoch;
    _roundStartedAt = DateTime.now();

    await _awaitRenderContextReady();
    if (_disposed) return;
    if (epoch != _openEpoch) {
      Get.log('[$runtimeType] 起播已被更新的请求取代，放弃本次(epoch=$epoch, now=$_openEpoch)');
      return;
    }
    try {
      await player.open(Media(url, httpHeaders: roomInfo.value?.http_header), play: true).timeout(_kOpenTimeout);
      try {
        await player.setVolume(volume.value).timeout(const Duration(seconds: 2));
      } catch (e) {
        Get.log('[$runtimeType] open 后补写音量失败/超时，忽略: $e', isError: true);
      }
    } on TimeoutException {
      playError.value = '打开播放器超时（原生渲染未就绪，画面可能仍是黑的）';
      Get.log('[$runtimeType] player.open 超过 ${_kOpenTimeout.inSeconds}s 未返回，放弃等待继续后续流程', isError: true);
    } catch (e) {
      playError.value = '播放失败: $e';
      Get.log('[$runtimeType] 播放失败: $e', isError: true);
    }

    unawaited(_probeFirstFrame(epoch));
  }

  Future<void> _awaitRenderContextReady() async {
    if (_disposed) return;

    try {
      await _videoSurfaceLaidOut.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (!_disposed) {
        debugPrint('[$runtimeType] 等待视频区域布局超时(3s)，继续等渲染上下文');
      }
    }
    if (_disposed) return;

    try {
      await _videoControllerReady.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (!_disposed) {
        debugPrint('[$runtimeType] 等待 VideoController 创建超时(3s)，继续尝试等纹理');
      }
    }
    if (_disposed) return;

    final vc = _videoController;
    if (vc != null && vc.id.value == null) {
      final ready = Completer<void>();
      void onIdChanged() {
        if (vc.id.value != null && !ready.isCompleted) ready.complete();
      }

      vc.id.addListener(onIdChanged);
      try {
        await ready.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        if (!_disposed) {
          debugPrint('[$runtimeType] 等待纹理 ID 超时(3s)，仍继续起播');
        }
      } finally {
        vc.id.removeListener(onIdChanged);
      }
    }
    if (_disposed) return;
  }

  static String? _pickPlayableUrl(LiveStreamInfo stream, [int? lineIndex]) {
    final candidates = _sortLines(stream);
    if (candidates.isEmpty) return null;

    if (lineIndex != null && lineIndex >= 0 && lineIndex < candidates.length) {
      return candidates[lineIndex].$3;
    }
    return candidates.first.$3;
  }

  static List<(LIVE_PROTOCOL_E?, LIVE_CODEC_E?, String)> _sortLines(LiveStreamInfo stream) {
    final candidates = stream.stream_url.where((u) => u.$3.isNotEmpty).toList();
    if (candidates.length < 2) return candidates;

    candidates.sort((a, b) {
      final byProtocol = _protocolRank(a.$1).compareTo(_protocolRank(b.$1));
      if (byProtocol != 0) return byProtocol;
      return _codecRank(a.$2).compareTo(_codecRank(b.$2));
    });
    return candidates;
  }

  /// FLV 延迟最低，其次 HLS；斗鱼的线路没标协议(null)，按 HLS 同级处理
  static int _protocolRank(LIVE_PROTOCOL_E? protocol) {
    switch (protocol) {
      case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HTTP_FLV:
        return 0;
      case null:
      case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HLS_TS:
        return 1;
      case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HLS_FMP4:
        return 2;
    }
  }

  /// H.264 兼容性最好，其次 H.265，最后 AV1
  static int _codecRank(LIVE_CODEC_E? codec) {
    switch (codec) {
      case null:
      case LIVE_CODEC_E.LIVE_CODEC_AVC_H264:
        return 0;
      case LIVE_CODEC_E.LIVE_PROTOCOL_HEVC_H265:
        return 1;
      case LIVE_CODEC_E.LIVE_PROTOCOL_AV1:
        return 2;
    }
  }

  /// 切换清晰度
  Future<void> switchQuality(LIVE_VIDEO_QUALITY quality) async {
    if (isSwitchingQuality.value) return;
    if (quality == LIVE_VIDEO_QUALITY.UNKNOWN) return;
    if (currentQuality == quality) return;

    isSwitchingQuality.value = true;
    try {
      if (!(roomDetail.value?.roomInfo.video_set[quality]?.stream_url.isNotEmpty ?? false)) {
        final ok = await _fetchStreamForQuality(quality);
        if (!ok) {
          Get.snackbar('切换画质失败', '${qualityName(quality)} 暂时没有可用线路');
          return;
        }
      }

      selectedQuality.value = quality;
      selectedLine.value = 0;
      await _openCurrentStream();
    } finally {
      isSwitchingQuality.value = false;
    }
  }

  /// 用户当前选中的线路序号，跟随 _openCurrentStream 生效
  final selectedLine = 0.obs;

  /// 当前画质下可用的线路列表
  List<(LIVE_PROTOCOL_E?, LIVE_CODEC_E?, String)> get availableLines {
    final stream = playingStream;
    if (stream == null) return const [];
    return _sortLines(stream);
  }

  /// 当前实际在用的线路序号。线路变少时夹回合法范围，避免 UI 显示成「线路4」但只有 2 条
  int get currentLine {
    final count = availableLines.length;
    if (count == 0) return 0;
    return selectedLine.value.clamp(0, count - 1).toInt();
  }

  /// 线路在 UI 上的显示名：按「协议 + 编码」描述这条流的区别
  String lineName(int index) {
    final lines = availableLines;
    if (index < 0 || index >= lines.length) return '线路${index + 1}';
    final (protocol, codec, _) = lines[index];
    final detail = _lineDetailName(protocol, codec);
    return detail.isEmpty ? '线路${index + 1}' : '线路${index + 1} $detail';
  }

  /// 把协议/编码翻成能给用户看的短语；两者都未知时返回空串（只显示线路号）
  static String _lineDetailName(LIVE_PROTOCOL_E? protocol, LIVE_CODEC_E? codec) {
    final parts = <String>[];
    if (protocol != null) {
      switch (protocol) {
        case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HTTP_FLV:
          parts.add('FLV');
        case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HLS_TS:
          parts.add('HLS');
        case LIVE_PROTOCOL_E.LIVE_PROTOCOL_HLS_FMP4:
          parts.add('HLS-fMP4');
      }
    }
    if (codec != null) {
      switch (codec) {
        case LIVE_CODEC_E.LIVE_CODEC_AVC_H264:
          parts.add('H.264');
        case LIVE_CODEC_E.LIVE_PROTOCOL_HEVC_H265:
          parts.add('H.265');
        case LIVE_CODEC_E.LIVE_PROTOCOL_AV1:
          parts.add('AV1');
      }
    }
    return parts.join(' · ');
  }

  /// 切换线路：同一清晰度内换一条流重新起播
  Future<void> switchLine(int index) async {
    if (isSwitchingQuality.value) return;

    final count = availableLines.length;
    if (count == 0 || index < 0 || index >= count) return;
    if (index == currentLine) return;

    isSwitchingQuality.value = true;
    try {
      selectedLine.value = index;
      await _openCurrentStream();
    } finally {
      isSwitchingQuality.value = false;
    }
  }

  /// 按需向平台再要一次指定清晰度的流；不支持/失败返回 false
  Future<bool> _fetchStreamForQuality(LIVE_VIDEO_QUALITY quality) async {
    final source = _source;
    if (source == null) return false;

    try {
      final stream = await source.fetchStream(roomId, quality);
      return _adoptFetchedStream(quality, stream);
    } catch (e) {
      Get.log('[$runtimeType] 重取清晰度失败($quality): $e', isError: true);
      return false;
    }
  }

  bool _adoptFetchedStream(LIVE_VIDEO_QUALITY quality, LiveStreamInfo? stream) {
    if (stream == null || stream.stream_url.isEmpty) return false;

    final room = roomDetail.value?.roomInfo;
    if (room != null && !identical(room.video_set[quality], stream)) {
      room.video_set[quality] = stream;
    }
    return true;
  }

  /// 设置音量 0~100
  Future<void> setVolume(double value) async {
    final v = value.clamp(0.0, 100.0).toDouble();
    volume.value = v;
    if (v > 0) _lastVolume = v;
    await player.setVolume(v);
  }

  /// 静音 / 恢复
  Future<void> toggleMute() async {
    if (volume.value > 0) {
      _lastVolume = volume.value;
      await setVolume(0);
    } else {
      await setVolume(_lastVolume <= 0 ? 100 : _lastVolume);
    }
  }

  Future<void> togglePlay() async {
    final playing = player.state.playing;
    if (playing) {
      _userPaused = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      await player.pause();
    } else {
      _userPaused = false;
      await player.play();
    }
  }

  void toggleDanmaku() {
    isDanmakuOn.value = !isDanmakuOn.value;
  }

  void setShowControls(bool show) {
    if (!show && isQualityMenuOpen.value) return;
    showControls.value = show;
  }

  /// 标记画质菜单的展开状态。
  void setQualityMenuOpen(bool open) {
    isQualityMenuOpen.value = open;
    if (open) showControls.value = true;
  }

  final isFullscreen = false.obs;

  /// 是否处于「适配窗口」状态：视频画面铺满整个 App 窗口（BoxFit.cover）。
  final isFitWindow = false.obs;

  /// 直链：取当前正在播放的那条流的原始地址。
  Future<String> get_clarity_vido_play_url() async {
    final stream = playingStream;
    if (stream == null) return '';

    final url = _pickPlayableUrl(stream, currentLine);
    return url ?? '';
  }

  /// 刷新：重新拉一次房间信息并重新起播。
  Future<void> refreshStream() async {
    if (isLoading.value) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    playError.value = null;
    await reload();
  }

  /// 适配窗口：把视频画面放大到铺满整个 App 窗口（不改变窗口本身的大小）。
  void toggleFitWindow() {
    final next = !isFitWindow.value;
    isFitWindow.value = next;
    if (next) {
      exitFullscreenIfNeeded();
      showControls.value = true;
    }
  }

  bool _isTogglingFullscreen = false;

  Future<void> toggleFullscreen() async {
    if (_isTogglingFullscreen) {
      Get.log('[$runtimeType] 正在切换全屏，忽略这次点击');
      return;
    }
    _isTogglingFullscreen = true;

    try {
      final next = !isFullscreen.value;

      if (PlatformSupport.isDesktop) {
        _applyFullscreenState(next);
        unawaited(_setWindowFullscreen(next));

        await WidgetsBinding.instance.endOfFrame;
      } else {
        await _setLandscapeOrientation(next);
        if (_disposed) return;

        _applyFullscreenState(next);

        await WidgetsBinding.instance.endOfFrame;
      }

      if (_disposed) return;
      textureRefreshTick.value++;
      Get.log('[$runtimeType] 全屏切换完成 next=$next tick=${textureRefreshTick.value}');
    } finally {
      _isTogglingFullscreen = false;
    }
  }

  /// 真正改布局状态（两部分共用，保证行为一致）。
  void _applyFullscreenState(bool next) {
    if (next) isFitWindow.value = false;
    isFullscreen.value = next;
    if (next) showControls.value = true;
  }

  final textureRefreshTick = 0.obs;

  Future<void> _setLandscapeOrientation(bool landscape) async {
    if (PlatformSupport.isDesktop) return;

    try {
      if (landscape) {
        await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (e) {
      Get.log('[$runtimeType] 切换屏幕方向失败: $e', isError: true);
    }
  }

  /// 如果当前在窗口全屏，就退出来。供「适配窗口」等场景复用
  void exitFullscreenIfNeeded() {
    if (!isFullscreen.value) return;
    isFullscreen.value = false;
    unawaited(_setWindowFullscreen(false));
  }

  Future<void> _setWindowFullscreen(bool full) async {
    if (!PlatformSupport.supportsWindowManager) return;

    try {
      await windowManager.setFullScreen(full);
    } catch (e) {
      Get.log('[$runtimeType] 设置窗口全屏失败: $e', isError: true);
    }
  }

  void _restoreWindowOnLeave() {
    isFitWindow.value = false;
    if (!isFullscreen.value) return;
    isFullscreen.value = false;
    unawaited(_setLandscapeOrientation(false));
    unawaited(_setWindowFullscreen(false));
  }
}
