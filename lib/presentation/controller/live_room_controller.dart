import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// SystemChrome / DeviceOrientation / SystemUiMode 都在 services.dart 里，
// material.dart 不会把这些导出，必须单独 import（否则报 Undefined name）。
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'package:ym_live_stream/contract/live_models.dart';
import 'package:ym_live_stream/contract/live_source.dart';
import 'package:ym_live_stream/mock/mock_live_source.dart';
import 'package:ym_live_stream/core/platform_support.dart';
import 'package:ym_live_stream/core/route_path.dart';
import 'package:ym_live_stream/features/danmaku_message.dart';
import 'package:ym_live_stream/features/favorite_store.dart';
import 'package:ym_live_stream/presentation/app_router.dart';
import 'package:ym_live_stream/presentation/widgets/app_snackbar.dart';

// 【这个控制器不认识任何具体平台实现】
// 只通过 LiveSourceRegistry 拿一个 LiveSource 接口来用。
// 所以这里**不允许**出现 import '.../features/bilibili/...' 这类后端路径 ——
// 那是私有代码，开源版没有它。新增平台时改后端，不用动这里。

// ==========================================
// 2. 业务逻辑层 (Controller)
// ==========================================
class LiveStreamController extends ChangeNotifier {
  LiveStreamController({required this.args}); // 参数只走构造函数

  final LiveRoomArgs args;

  /// 房间标识（字符串）。数字或字母 id 都可能，见 LiveRoomInfo.room_id。
  String get roomId => args.roomId;
  LIVE_SITE_E get site => args.site;

  /// 当前平台的后端实现。
  ///
  /// 从注册表取，取不到就用 mock 兜底（开源版没注册真实后端时走这里）。
  /// 注意：这个 getter 每次都会查表，不要在 build 里反复调，存到局部变量用。
  LiveSource? get _source => LiveSourceRegistry.find(site) ?? _mockFor(site);

  /// 各平台的 mock 兜底实例，按平台缓存一份，避免每次新建
  static final Map<LIVE_SITE_E, LiveSource> _mockCache = {};

  static LiveSource _mockFor(LIVE_SITE_E site) => _mockCache.putIfAbsent(site, () => MockLiveSource(site));

  // ===== 响应式状态（ChangeNotifier：字段 + setter + notifyListeners）=====
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  set isLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  LiveRoomInfo? _roomInfo;
  LiveRoomInfo? get roomInfo => _roomInfo;
  set roomInfo(LiveRoomInfo? v) {
    _roomInfo = v;
    notifyListeners();
  }

  LiveRoomDetail? _roomDetail;
  LiveRoomDetail? get roomDetail => _roomDetail;
  set roomDetail(LiveRoomDetail? v) {
    _roomDetail = v;
    notifyListeners();
  }

  LiveStreamInfo? _defaultStream;
  LiveStreamInfo? get defaultStream => _defaultStream;
  set defaultStream(LiveStreamInfo? v) {
    _defaultStream = v;
    notifyListeners();
  }

  String? _loadError;
  String? get loadError => _loadError;
  set loadError(String? v) {
    _loadError = v;
    notifyListeners();
  }

  /// 直播间开播状态（未开播 / 被封禁）。
  ///
  /// 单独开一条通道，不要塞进 loadError：未开播、被封禁是平台正常返回的**业务状态**，
  /// 不是「获取失败」。塞进 loadError 会连带出两个错误结果：
  ///   1) 页面按报错页渲染（红色错误文案 + 重试），语义不对；
  ///   2) 重连逻辑（_reconnectStream）会读到 loadError 就继续排重连，
  ///      对着一个没开播的房间无限重试。
  LIVE_SHOW_STATUS_E? _roomShowStatus;
  LIVE_SHOW_STATUS_E? get roomShowStatus => _roomShowStatus;
  set roomShowStatus(LIVE_SHOW_STATUS_E? v) {
    _roomShowStatus = v;
    notifyListeners();
  }

  /// 当前房间是否已关注（「关注」按钮的高亮状态）。
  ///
  /// 只在拿到 roomInfo 之后才有意义：room_id / 主播名 / 头像都来自它。
  bool _isFavorited = false;
  bool get isFavorited => _isFavorited;
  set isFavorited(bool v) {
    _isFavorited = v;
    notifyListeners();
  }

  /// 当前房间是否「特别关注」。
  ///
  /// 特别关注 = 除了进关注列表，还会出现在主页名片区。
  /// 它必须建立在「已关注」之上：没关注的时候这个状态一定是 false。
  bool _isSpecialFollowed = false;
  bool get isSpecialFollowed => _isSpecialFollowed;
  set isSpecialFollowed(bool v) {
    _isSpecialFollowed = v;
    notifyListeners();
  }

  /// 进房请求超时：避免某些平台吞包导致永远转圈
  static const _kFetchTimeout = Duration(seconds: 15);

  bool _isPlaying = true;
  bool get isPlaying => _isPlaying;
  set isPlaying(bool v) {
    _isPlaying = v;
    notifyListeners();
  }

  bool _isDanmakuOn = true;
  bool get isDanmakuOn => _isDanmakuOn;
  set isDanmakuOn(bool v) {
    _isDanmakuOn = v;
    notifyListeners();
  }

  bool _showControls = true;
  bool get showControls => _showControls;
  set showControls(bool v) {
    _showControls = v;
    notifyListeners();
  }

  /// 控制栏自动隐藏计时器：showControls 设为 true 后，N 秒无操作自动收回。
  ///
  /// 桌面端靠 MouseRegion.onExit 隐藏；手机端没有 hover，必须靠这个计时器。
  /// 点击视频区会重置计时器（见 [setShowControls]）。
  Timer? _hideControlsTimer;
  static const Duration _kControlsAutoHideDelay = Duration(seconds: 4);

  // ===== 视频画面上的滚动弹幕：显示参数 =====
  //
  // 这三个都由控制栏的「弹幕」按钮弹出面板调节，不需要持久化到配置
  // （属于观感偏好，每次进房用默认值即可；用户嫌烦可以关掉弹幕开关）。

  /// 弹幕区域占视频高度的比例。可选 1/4、1/3、1/2。
  ///
  /// 值越小画面露得越多，但能排的轨道也越少（同屏容易挤）。
  double _danmakuAreaRatio = 0.25;
  double get danmakuAreaRatio => _danmakuAreaRatio;
  set danmakuAreaRatio(double v) {
    _danmakuAreaRatio = v;
    notifyListeners();
  }

  /// 弹幕字号（逻辑像素）。
  ///
  /// 可选范围 [kDanmakuFontSizeMin] ~ [kDanmakuFontSizeMax] 内的**任意整数**。
  /// 手机的初始化采用最小的16字号
  int _danmakuFontSize = PlatformSupport.isDesktop ? 22 : 16;
  int get danmakuFontSize => _danmakuFontSize;
  set danmakuFontSize(int v) {
    _danmakuFontSize = v;
    notifyListeners();
  }

  /// 同屏同时飞行的弹幕条数上限。
  ///
  /// 可选范围 [kDanmakuMaxOnScreenMin] ~ [kDanmakuMaxOnScreenMax] 内的**任意整数**。
  int _danmakuMaxOnScreen = 30;
  int get danmakuMaxOnScreen => _danmakuMaxOnScreen;
  set danmakuMaxOnScreen(int v) {
    _danmakuMaxOnScreen = v;
    notifyListeners();
  }

  /// 弹幕滚动速度：一条弹幕从右侧进入到完全飞出左侧所需秒数。
  ///
  /// 【用「时长」而不是「像素/秒」】视频区宽度随全屏/窗口缩放变化，
  /// 固定时长能让任何宽度下的观感速度一致（宽屏也只是飞得远、不会更快）。
  /// 秒数越大越慢。可选范围 [kDanmakuFlightSecondsMin] ~ [kDanmakuFlightSecondsMax]。
  int _danmakuFlightSeconds = 14;
  int get danmakuFlightSeconds => _danmakuFlightSeconds;
  set danmakuFlightSeconds(int v) {
    _danmakuFlightSeconds = v;
    notifyListeners();
  }

  /// 弹幕飞行时长的可调范围（秒，含两端）。越大越慢。
  static const int kDanmakuFlightSecondsMin = 8;
  static const int kDanmakuFlightSecondsMax = 24;

  /// 显示范围的可选值（离散三档，不是连续区间）
  static const List<double> kDanmakuAreaOptions = [0.25, 1 / 3, 0.5];

  /// 字号可调范围（含两端）
  static const int kDanmakuFontSizeMin = 16;
  static const int kDanmakuFontSizeMax = 34;

  /// 同屏条数可调范围（含两端）
  static const int kDanmakuMaxOnScreenMin = 20;
  static const int kDanmakuMaxOnScreenMax = 50;

  /// 区域比例的显示文案
  static String danmakuAreaLabel(double ratio) {
    if (ratio <= 0.25) return '1/4';
    if (ratio <= 0.34) return '1/3';
    return '1/2';
  }

  /// 画质菜单是否正在展开。
  ///
  /// 菜单是走 Navigator 的独立 route，鼠标移上去就已经离开了播放区的 MouseRegion，
  /// 会触发 onExit 把控制栏收起来 —— 表现就是「点开画质，底部工具栏消失」。
  /// 所以菜单展开期间锁住控制栏，让它和菜单同时可见。
  bool _isQualityMenuOpen = false;
  bool get isQualityMenuOpen => _isQualityMenuOpen;
  set isQualityMenuOpen(bool v) {
    _isQualityMenuOpen = v;
    notifyListeners();
  }

  // ===== 弹幕（当前只在右侧栏显示，不叠加到播放区） =====
  List<DanmakuMessage> _danmakuList = <DanmakuMessage>[];

  /// 右侧栏要展示的弹幕列表，最新的在末尾。
  ///
  /// 迁移自 RxList：现在由 [_flushDanmaku] 在替换整列表后手动 [notifyListeners]。
  List<DanmakuMessage> get danmakuList => _danmakuList;
  set danmakuList(List<DanmakuMessage> v) {
    _danmakuList = v;
    notifyListeners();
  }

  /// 待刷新的弹幕缓冲（普通 List，不触发任何重建）。
  final List<DanmakuMessage> _danmakuBuffer = [];

  /// 节流刷新的定时器；为空表示当前没有待刷新的内容。
  Timer? _danmakuFlushTimer;

  /// 弹幕 UI 刷新间隔。
  static const Duration _kDanmakuFlushInterval = Duration(milliseconds: 200);

  /// 弹幕是否**确认**已连上（右侧栏顶部的状态图标用）。
  ///
  /// 刻意只在收到第一条弹幕时才置 true：三个客户端的连接方法都不保证
  /// 「返回即连上」——斗鱼和 B 站的 connect 都会把握手异常吞掉转去重连，
  /// 所以「连接中」不等于失败，收到消息才是唯一可靠的实证。
  bool _danmakuConnected = false;
  bool get danmakuConnected => _danmakuConnected;
  set danmakuConnected(bool v) {
    _danmakuConnected = v;
    notifyListeners();
  }

  /// 弹幕客户端连接状态文案（首测阶段方便定位是哪一端没连上）
  String _danmakuStatus = '';
  String get danmakuStatus => _danmakuStatus;
  set danmakuStatus(String v) {
    _danmakuStatus = v;
    notifyListeners();
  }

  /// 当前弹幕连接。
  ///
  /// 三个平台的客户端类型各不相同，但都通过 [DanmakuConnection] 暴露同一个
  /// 「关闭」语义，所以这里只需要一个句柄，不再按平台分三个字段。
  DanmakuConnection? _danmakuConnection;

  /// 当前弹幕连接对应的房间号。
  ///
  /// 用来判断「这条连接还能不能复用」：房间号没变就不用重连。
  /// 全屏切换、切清晰度、视频重连都会重新走一次起播流程，
  /// 但那些都不该打断弹幕。
  String? _danmakuRoomId;

  /// 是否正在关闭中：关页时弹幕回调可能仍在触发，用它拦住往已销毁的列表里塞数据。
  bool _danmakuStopping = false;

  /// 列表上限：弹幕是持续流入的，不设上限会一直涨内存。
  static const int _kDanmakuMaxCount = 200;

  /// 入队一条弹幕（三个平台的回调都收到这里）。

  void _appendDanmaku(String nickname, String content, LIVE_SITE_E site) {
    if (_danmakuStopping || _disposed) return;
    // 空内容（礼物/进房等消息里可能夹杂）不显示
    final text = content.trim();
    if (text.isEmpty) return;

    _danmakuBuffer.add(DanmakuMessage(nickname: nickname, content: text, site: site));
    if (_danmakuBuffer.length > _kDanmakuMaxCount * 2) {
      _danmakuBuffer.removeRange(0, _danmakuBuffer.length - _kDanmakuMaxCount);
    }

    // 「能收到弹幕」才是连接成功的唯一实证：三个客户端连上后都会自行重连、
    // 且握手失败不一定抛异常（斗鱼的 connect 就是把异常吞掉排重连），
    // 所以状态以第一条弹幕到达为准。
    if (!danmakuConnected) {
      danmakuConnected = true;
      danmakuStatus = '${_danmakuStatusText()}弹幕：已连接';
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

    // 合并：已有的 + 新攒的，然后只保留最后 N 条。
    final merged = <DanmakuMessage>[...danmakuList, ..._danmakuBuffer];
    _danmakuBuffer.clear();

    // 一次赋值完成「追加 + 裁剪」，UI 只重建一次
    danmakuList = merged.length > _kDanmakuMaxCount ? merged.sublist(merged.length - _kDanmakuMaxCount) : merged;
  }

  /// 停止当前弹幕连接（关页 / 换一轮重连前调用）。
  ///
  /// 各平台客户端内部都自带重连（斗鱼 3s、B 站 3s），关页时只靠 GC 是收不掉的：
  /// socket 和心跳定时器会一直活着，所以必须显式断开。
  void _stopDanmaku() {
    _danmakuStopping = true;

    // 取消尚未执行的刷新，并丢掉缓冲区里没刷出去的弹幕 ——
    // 换房间时这些属于上一个房间，不该显示到新的直播间里。
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _danmakuBuffer.clear();

    // 具体怎么断（close/disconnect/dispose）由各平台适配器决定，
    // 这里只负责调用统一的 dispose，并且它是幂等的。
    _danmakuConnection?.dispose();
    _danmakuConnection = null;
    _danmakuRoomId = null;

    danmakuConnected = false;
    danmakuStatus = '';
  }

  /// 起播成功后拉起对应平台的弹幕连接。
  ///
  /// 各平台客户端内部自带重连（斗鱼 3s、B 站 3s），所以**视频断流重连时
  /// 不要跟着再连一次弹幕**，否则每重连一轮就多一个后台 socket、
  /// 界面上也会反复闪「弹幕：连接中…」。
  ///
  /// 【判断依据是「同一个房间的活跃连接」】
  /// 全屏切换、切清晰度、视频重连都会重新走起播流程，但房间没变、
  /// 弹幕连接本身也还活着 —— 这些情况下直接复用，什么都不做。
  /// 只有房间号变了（换房间）或连接已经断了，才真正重建。
  Future<void> _startDanmaku() async {
    if (_disposed) return;
    final info = roomInfo;
    if (info == null) return;
    // 未开播 / 被封禁：不连弹幕
    if (roomShowStatus != null) return;

    // 【已有同一个房间的活跃连接：直接复用】
    // 全屏进进出出、切清晰度、视频重连都会走到这里，
    // 但弹幕流跟视频流是两条独立的连接，没理由重连。
    if (_danmakuConnection != null && _danmakuRoomId == info.room_id) {
      return;
    }

    // 走到这里说明：第一次连 / 换了房间 / 上一次的连接已经停了。
    // 先把上一轮的连接停掉，避免残留后台 socket。
    _stopDanmaku();
    _danmakuStopping = false;

    final source = _source;
    if (source == null) {
      danmakuStatus = '${_danmakuStatusText()}弹幕：没有可用的后端实现';
      return;
    }

    // 各平台弹幕用的房间号都取 room_id（抖音这里是 web_rid）
    final danmakuRoomId = info.room_id;
    if (!LiveRoomArgs.isValidRoomId(danmakuRoomId)) {
      danmakuStatus = '${_danmakuStatusText()}弹幕：拿不到房间号，跳过';
      return;
    }

    // 记下这条连接对应的房间号，供上面的复用判断使用
    _danmakuRoomId = danmakuRoomId;

    final stopwatch = Stopwatch()..start();
    try {
      danmakuStatus = '${_danmakuStatusText()}弹幕：连接中…';

      // 【一个接口调用代替原来的三个 switch 分支】
      // 具体用哪个客户端、怎么握手、怎么重连，全在平台适配器里。
      // 连接过程不 await：各平台握手都带网络请求，等下去会拖慢起播，
      // 而且失败不该影响视频播放 —— 错误统一走 onError 回调。
      _danmakuConnection = source.connectDanmaku(
        danmakuRoomId,
        onMessage: (nickname, content) => _appendDanmaku(nickname, content, site),
        onError: (e) {
          if (_danmakuStopping || _disposed) return;
          danmakuConnected = false;
          danmakuStatus = '${_danmakuStatusText()}弹幕异常: $e';
          debugPrint('[弹幕/${_danmakuStatusText()}] $e');
        },
        // 把已拿到的房间信息传过去：虎牙这类平台的弹幕订阅参数
        // （频道号等）在拉房间信息时就已经取到了，传过去就不用重复请求。
        roomInfo: info,
      );

      debugPrint('[$runtimeType] 弹幕客户端已启动(${_danmakuStatusText()}) ${stopwatch.elapsedMilliseconds}ms：${danmakuStatus}');
    } catch (e, stack) {
      // 弹幕连不上绝不能影响看直播：这里只记录，不写 loadError、不打断播放
      danmakuConnected = false;
      danmakuStatus = '弹幕连接失败: $e';
      debugPrint('[$runtimeType] 弹幕连接失败: $e\n$stack');
    }
  }

  String _danmakuStatusText() => switch (site) {
    LIVE_SITE_E.LIVE_SITE_DOUYU => '斗鱼',
    LIVE_SITE_E.LIVE_SITE_BILIBILI => 'BiliBili',
    LIVE_SITE_E.LIVE_SITE_DOUYIN => '抖音',
    LIVE_SITE_E.LIVE_SITE_HUYA => '虎牙',
    LIVE_SITE_E.LIVE_SITE_KUAISHOU => '快手',
    LIVE_SITE_E.LIVE_SITE_TWITCH => 'Twitch',
  };

  /// 手动清空右侧栏弹幕
  void clearDanmaku() {
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _danmakuBuffer.clear();
    _danmakuList.clear();
    notifyListeners();
  }

  // ===== media_kit 播放器 =====
  /// 全局唯一的播放器实例（由 main() 里的 MediaKit.ensureInitialized() 保证已初始化）
  final Player player = Player(
    configuration: const PlayerConfiguration(
      title: 'YM Live Stream',
      // 只保留 error 级别：debug 级别会按帧刷解码/渲染日志，是持续的 CPU + IO 开销。
      // 排查播放问题时临时改成 MPVLogLevel.debug（记得改回来）。
      logLevel: MPVLogLevel.error,
      // 直播是「跟着最新数据走」，不需要点播那种大缓存。
      // 默认值（32MB）在直播场景下只是白占内存，降到 16MB；
      // 如果遇到高码率（4K）频繁卡顿，把这个值往上调即可。
      bufferSize: 16 * 1024 * 1024,
    ),
  );

  /// 交给 Video widget 渲染
  VideoController? _videoController;

  /// 页面真正把 Video widget 建出来（也就是 videoController 构造完）时完成，
  /// 供诊断逻辑等待，避免诊断自己去访问 getter 把懒加载提前触发。
  final Completer<VideoController> _videoControllerReady = Completer<VideoController>();

  /// 页面把视频区域「布局完成」的信号（Video widget 已经拿到真实约束）。
  /// 起播必须等它，原因见 _awaitRenderContextReady 的注释。
  final Completer<void> _videoSurfaceLaidOut = Completer<void>();

  /// 去重放在 controller 自己身上（实例级），页面就无需任何静态状态，
  /// 也不会留下对已销毁 controller 的悬挂引用。
  bool _videoSurfaceLaidOutNotified = false;

  /// 由页面在视频区域布局完成后调用（addPostFrameCallback）。
  /// 可重复调用：LayoutBuilder 会频繁重建，这里靠 _videoSurfaceLaidOutNotified 幂等。
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
    // 桌面端用 auto-safe：只有"明确安全"的硬解器才会启用，探测/初始化失败会自动
    // 退回软解，比 'auto' 更不容易在个别老显卡上花屏或崩溃。
    // 移动端（Android 的 mediacodec、iOS 的 videotoolbox）保持 'auto'：系统解码
    // 通路成熟，auto 就是最优。
    if (PlatformSupport.isDesktop) return 'auto-safe';
    return 'auto';
  }

  /// 【调试开关】强制走软解 + 软渲染，排查兼容性问题时用。
  ///
  /// 打开后：
  ///   hwdec = 'no'                        （解码全走 CPU）
  ///   enableHardwareAcceleration = false  （渲染走 SW，不碰 EGL/GPU）
  ///
  /// 【默认关闭】默认走硬解 + GPU 渲染。之前为排查某些机器的兼容/黑屏问题临时置为
  /// true，会导致全部解码和渲染压到 CPU，高码率/全屏时明显卡顿、CPU 占用高。
  /// 若某台机器遇到硬解花屏/黑屏，再单独把它打开验证。
  static const bool forceSoftwareDecoding = false;

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
  LIVE_VIDEO_QUALITY? _selectedQuality;
  LIVE_VIDEO_QUALITY? get selectedQuality => _selectedQuality;
  set selectedQuality(LIVE_VIDEO_QUALITY? v) {
    _selectedQuality = v;
    notifyListeners();
  }

  /// 音量 0~100（media_kit 的 setVolume 就是 0~100 的 double）
  double _volume = 100.0;
  double get volume => _volume;
  set volume(double v) {
    _volume = v;
    notifyListeners();
  }

  /// 切换清晰度时的 loading（避免连点）
  bool _isSwitchingQuality = false;
  bool get isSwitchingQuality => _isSwitchingQuality;
  set isSwitchingQuality(bool v) {
    _isSwitchingQuality = v;
    notifyListeners();
  }

  /// 播放器侧的错误提示
  String? _playError;
  String? get playError => _playError;
  set playError(String? v) {
    _playError = v;
    notifyListeners();
  }

  /// 缓冲中（UI 上盖一个转圈）
  bool _isBuffering = false;
  bool get isBuffering => _isBuffering;
  set isBuffering(bool v) {
    _isBuffering = v;
    notifyListeners();
  }

  double _lastVolume = 100;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;

  /// 流被 CDN 掐断时 mpv 会走到 EOF，只有这个流能感知到「播完了」。
  /// 注意：断流时 player.stream.error **不一定**会触发（ffmpeg 的原生报错
  /// 只写到 stderr，Dart 侧收不到），所以不能只靠 _errorSub。
  StreamSubscription<bool>? _completedSub;

  /// 【临时】诊断用，onClose 后不要再打日志
  bool _disposed = false;

  // ===== 断流自动重连 =====
  //
  // 背景（实测）：斗鱼直链跑到第 7 分钟被 CDN 掐断，日志末尾是
  //   mbedtls_ssl_read reported connection reset by peer
  //   Stream ends prematurely at 43666346, should be 18446744073709551615
  // 这条地址带 expire=300 / token / wsAuth 短时效签名，**断掉之后不能复用**，
  // 所以重连必须重新拉一次房间信息拿新地址，而不是拿旧 URL 硬重开。
  static const int _kMaxReconnectAttempts = 5;

  /// 播满这么久才算「这次真的稳定了」，才会把重连计数清零。
  /// 否则「起来就死」的情况会被误判成一次成功重连，导致无限循环。
  static const Duration _kStablePlaybackThreshold = Duration(seconds: 10);

  /// player.open 的兜底超时。
  /// 背景（实测）：从收藏页进入直播间时，原生纹理偶尔没注册成功（id 一直为 null），
  /// 此时 mpv 不会发出 file-loaded 事件，media_kit 的 open() 就永远不返回 ——
  /// 调用链卡死在这里的后果是：isLoading 一直为 true（页面永远 loading/黑屏），
  /// 并且后面的 _startDanmaku() 也没机会执行（表现为「黑屏 + 没有弹幕」）。
  /// 所以这里必须给 open 加超时，超时后照常往下走，至少把弹幕和错误提示放出来。
  static const Duration _kOpenTimeout = Duration(seconds: 15);

  /// 重连退避计时器
  Timer? _reconnectTimer;

  /// 连续重连次数
  int _reconnectAttempts = 0;

  /// 本轮 open 的时刻。用它而不是 stream.playing 来算「这轮播了多久」：
  /// 重连时如果 playing 一直保持 true，media_kit 不会再发一次 true，
  /// 依赖它会导致「播了 7 分钟」被误判成「起来就死」。
  /// 在 _openCurrentStream 里置为当前时间，在 _scheduleReconnect 里置空。
  DateTime? _roundStartedAt;

  /// 是否成功播出过画面。用来把「起播阶段 mpv 的一堆良性 error 日志」
  /// 挡在重连逻辑之外（例如 `Failed to create file cache.` 就是 error 级别）。
  bool _hasPlayedOnce = false;

  /// 用户主动暂停时不该触发重连
  bool _userPaused = false;

  /// 当前应该播放的流：优先用户选的清晰度，其次平台默认流，最后任取一条有地址的
  LiveStreamInfo? get playingStream {
    final detail = roomDetail;
    if (detail == null) return defaultStream;

    final quality = selectedQuality ?? args.quality;
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

  /// 可切换的清晰度列表（按枚举定义的从高到低排列）
  ///
  /// **规则：video_set 里有几项，就列几项** —— 不论它内部有没有 stream_url。
  /// 没有地址的那档，点选后会走 _fetchStreamForQuality 现场向平台要一次。
  ///
  /// 之前这里还带一个 canFetchOnDemand 判断，把「没地址且平台不支持按需取」的项
  /// 直接剔掉了（当时 B 站分支是写死 return false 的）。现在三个平台都能按需
  /// 取流了（B 站走 getRoomPlayInfo），这个过滤就只是在藏选项 ——
  /// 用户明明看到 video_set 里有这一档，选择框里却找不到，很容易误以为是 bug。
  /// 真取不到时由 _fetchStreamForQuality 返回 false 并提示，比事先藏掉更清楚。
  List<LIVE_VIDEO_QUALITY> get availableQualities {
    final videoSet = roomDetail?.roomInfo.video_set ?? roomInfo?.video_set;
    if (videoSet == null || videoSet.isEmpty) return const [];

    return LIVE_VIDEO_QUALITY.values.where((q) => q != LIVE_VIDEO_QUALITY.UNKNOWN).where((q) => videoSet.containsKey(q)).toList(growable: false);
  }

  /// 正在播放的清晰度（用于 UI 显示当前选中项）
  LIVE_VIDEO_QUALITY? get currentQuality {
    final stream = playingStream;
    if (stream == null) return null;
    final videoSet = roomDetail?.roomInfo.video_set;
    if (videoSet != null) {
      for (final entry in videoSet.entries) {
        if (identical(entry.value, stream)) return entry.key;
      }
    }
    return selectedQuality;
  }

  /// 清晰度在 UI 上的名字：优先用平台返回的名字（原画/蓝光/超清…），兜底用枚举名
  String qualityName(LIVE_VIDEO_QUALITY quality) {
    final videoSet = roomDetail?.roomInfo.video_set ?? roomInfo?.video_set;
    final name = videoSet?[quality]?.name;
    if (name != null && name.isNotEmpty && name != '未知') return name;
    return quality.name.split('_').last;
  }

  /// 初始化：由页面 State.initState 调用。
  ///
  /// 迁移自 GetxController.onInit —— onInit 在 GetX 里是 put 之后、build 之前同步执行，
  /// 这里改成页面显式调用，时序等价（State.initState 也早于 build）。
  void init() {
    _playingSub = player.stream.playing.listen((playing) {
      isPlaying = playing;
      // 播出过 true 才算「起播成功」，重连逻辑用这个闸门过滤起播期的噪声
      if (playing) {
        _hasPlayedOnce = true;
      }
    });
    _bufferingSub = player.stream.buffering.listen((buffering) => isBuffering = buffering);
    _errorSub = player.stream.error.listen((error) {
      debugPrint('[播放器] $error');

      // 【不要无条件写进 playError】mpv 的 error 级别输出里混着大量良性噪声，
      // 而且**存在滞后**：上一个解码器/上一次 open 的错误可能在新流已经正常播放
      // 之后才送达。无条件写入会导致「画面明明在播，屏幕中间却一直挂着
      // could not open codec 的错误浮层」—— 实测切清晰度失败后点刷新就是这个现象。
      //
      // 判据：只要此刻播放器确实在播，就不把这条错误当成「用户需要看到的错误」。
      // 真有致命错误时，playing 会先降为 false，那时再显示不迟
      // （断流那条路径另有 completed(EOF) 兜底）。
      final actuallyPlaying = player.state.playing;
      if (!actuallyPlaying) {
        playError = error;
      } else {
        debugPrint('[$runtimeType] 播放中收到错误输出，仅记录日志、不上屏: $error');
      }

      // 两道闸门，都是为了防止「良性 error 日志」把重连打成死循环：
      //   1) _hasPlayedOnce —— 起播前 mpv 会抛一堆 error 级别的噪声
      //      （`Failed to create file cache.`、解码器探测失败等）；
      //   2) !playing —— 起播后仍在播的状态下报 error 的，多半只是日志，
      //      不是真的断流；真断了的时候播放状态会先落下来。
      // 真正「播放中被 CDN 掐断」这条路径由下面的 completed(EOF) 兜底。
      if (_hasPlayedOnce && !actuallyPlaying) {
        _scheduleReconnect('播放错误');
      }
    });

    // 断流：CDN 掐断连接后 mpv 走到 EOF。这是本次线上问题的**唯一**可感知信号，
    // 因为 Dart 侧收不到 ffmpeg 的 stderr 报错。
    _completedSub = player.stream.completed.listen((completed) {
      if (!completed) return;
      debugPrint('[播放器] 流已结束(EOF)，尝试重连');
      _scheduleReconnect('流已结束');
    });

    unawaited(player.setVolume(volume));

    // 注意：这里绝对不要碰 videoController，否则会提前触发它的构造，
    // 导致首帧之前那块 0x0 的纹理被创建又丢弃（见字段上的注释）。
    _initBackendLogic(); // 页面初始化时自动执行后端逻辑
  }

  /// mpv 直播调优属性是否已经设置过（设置一次即可，属性在引擎生命周期内持续有效）。
  bool _mpvLivePropsApplied = false;

  /// 给 mpv 引擎设置一批「直播场景专用」的属性。
  ///
  /// media_kit 的 [PlayerConfiguration] 只暴露 title/logLevel/bufferSize 这类有限字段，
  /// 更细的 mpv 原生属性要通过 [NativePlayer.setProperty] 设置。
  ///
  /// 参考 pure_live 的直播调优表，只挑对本项目影响最大、且各平台都安全的几条：
  ///   * force-seekable=no / cache-pause=no：FLV/HLS 直播没有"缓存目标凑齐"的那一刻，
  ///     开着 cache-pause 会「先播两秒 → 停进缓冲 → 再续播」，这两条关掉即可。
  ///   * framedrop=decoder+vo：解码/渲染跟不上时丢掉晚到的帧，而不是越堆越多、延迟越来越大。
  ///   * network-timeout / demuxer-lavf-probesize：弱网鲁棒性 + 提升起播探测成功率。
  ///   * cache-secs / demuxer-max-bytes：给直播留足缓冲，减少抖动（比默认 16MB 更宽裕）。
  ///
  /// 【必须 await】属性要在第一次 open 之前写完，否则可能被 open 抢先、
  /// 导致首播仍按默认参数跑。失败不抛：某些 mpv 版本/平台可能不认识某个属性，
  /// 静默忽略即可，不能影响起播。
  Future<void> _applyMpvLiveProperties() async {
    if (_mpvLivePropsApplied) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final properties = <String, String>{
      // 直播流不 seek、不"凑缓存再播"，避免先播后停
      'force-seekable': 'no',
      'cache-pause': 'no',
      // 网络缓存与探测预算（直播场景偏大一点更稳）
      'cache': 'yes',
      'cache-on-disk': 'no',
      'cache-secs': '30',
      'demuxer-max-bytes': '96MiB',
      'demuxer-max-back-bytes': '8MiB',
      'demuxer-donate-buffer': 'no',
      'demuxer-readahead-secs': '8',
      // 网络超时与 lavf 探测
      'network-timeout': '15',
      'demuxer-lavf-probesize': '2097152',
      'demuxer-lavf-analyzeduration': '2',
      'demuxer-thread': 'yes',
      // 丢晚到的帧，防止延迟越积越大
      'framedrop': 'decoder+vo',
      // 硬解失败一帧即退回软解，避免花屏
      'hwdec-software-fallback': '1',
      // 允许的协议（FLV over http/https、hls、rtmp 等）
      'protocol_whitelist': 'httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt',
    };

    for (final entry in properties.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (e) {
        debugPrint('[$runtimeType] 设置 mpv 属性 ${entry.key}=${entry.value} 失败（忽略）: $e');
      }
    }
    _mpvLivePropsApplied = true;
  }

  /// 当前播放的第几轮起播（切清晰度会重新 open，诊断只针对最新那一轮）
  int _openEpoch = 0;

  /// 「网络层错误」的特征。
  ///
  /// 用来判断「30s 没有首帧」是不是因为「这条 URL / 这条 CDN 连接废了」。
  /// 是的话唯一正确的处置是重新拉房间信息换一条新的签名地址（_scheduleReconnect）——
  /// 旧 URL 带 expire 短时效签名，重放必然立刻失败。
  /// 不是网络问题又没有首帧的（比如编码不被支持），只报错给用户，
  /// 不再做任何自动改解码器配置 + 重开的动作。
  ///
  /// 最具代表性的一条是实测日志里的 `tcp: ffurl_write returned 0xffffd8ba`：
  /// 0xffffd8ba 按有符号 32 位解释就是 -10054 = Windows 的 WSAECONNRESET
  /// （连接被对端重置），跟 hwdec 没有任何关系。
  static final RegExp _kNetworkErrorPattern = RegExp(
    r'tcp|ffurl_write|connection reset|reset by peer|broken pipe|'
    r'failed to open|could not open|network is unreachable|'
    r'connection refused|timed out|0xffffd8',
    caseSensitive: false,
  );

  bool _isNetworkPlayError(String? error) => error != null && _kNetworkErrorPattern.hasMatch(error);

  /// 首帧诊断：**从 open 之后开始计时**。
  ///
  /// 之前这个计时从 onInit 就开始了，而拉房间信息本身可能花几十秒，
  /// 等 open 真正执行时窗口早就过期了，于是误报"render API 没建起来"。
  ///
  /// 另外这里不能直接碰 videoController getter：那样会把懒加载提前触发，
  /// 又回到 0x0 纹理的老问题。所以先等页面把 Video widget 建出来。
  Future<void> _probeFirstFrame(int epoch) async {
    const timeout = Duration(seconds: 30);

    // 第一步：等页面真正创建出 VideoController（即 Video widget 已 build）
    final VideoController controller;
    try {
      controller = await _videoControllerReady.future.timeout(timeout);
    } on TimeoutException {
      if (_disposed || epoch != _openEpoch) return;
      debugPrint('[播放器] 30s 内页面仍未创建 Video widget，纹理未注册');
      return;
    }

    // 第二步：等首帧
    try {
      await controller.waitUntilFirstFrameRendered.timeout(timeout);
      if (_disposed || epoch != _openEpoch) return;
      debugPrint('[播放器] 首帧已渲染，纹理 ID = ${controller.id.value}');
    } on TimeoutException {
      if (_disposed || epoch != _openEpoch) return;
      final id = controller.id.value;
      debugPrint('[播放器] 30s 没有首帧，纹理 ID = ${id ?? "(null)"}，playError = ${playError ?? "(无)"}');

      // 只剩下一种处置：网络层已经把这条流废了，就重新拉房间信息换一条新地址。
      //   实测 `tcp: ffurl_write returned 0xffffd8ba`（= WSAECONNRESET，对端重置连接）
      //   就是这种。旧 URL 带 expire 的短时效签名，重放必然立刻失败，唯一出路是重连。
      //
      // 【这里曾经有「切软解 hwdec=no 再重开」的分支，已移除】理由是它解决不了真问题：
      //   黑屏的真实成因是 H.265 的 FLV 流（日志 `Video codec (c) is not implemented`），
      //   那是 mpv 自带 ffmpeg 的 flv 解封装不认 FLV 里的 HEVC，包在解封装层就被丢了，
      //   根本没进解码器 —— 换硬解/软解都不可能有帧。既然与硬解无关，就不该在
      //   播放异常时去改解码器配置、更不该拿旧签名地址重开（那是「程序卡死」的来源）。
      if (_isNetworkPlayError(playError)) {
        debugPrint('[$runtimeType] 判定为网络层错误，改走重连换新地址');
        _scheduleReconnect('首帧前网络错误');
        return;
      }

      // 非网络错误又没有首帧：只报错给用户，不做任何自动改配置 + 重开的动作。
      if (playError == null) {
        playError = '画面未能渲染（该流可能是 H.265/FLV 等当前播放器不支持的编码）';
      }
      return;
    } catch (e) {
      if (_disposed || epoch != _openEpoch) return;
      debugPrint('[播放器] 首帧等待异常: $e；纹理 ID = ${controller.id.value}');
      return;
    }
  }

  /// 页面首帧渲染后由 State 在 postFrame 回调里调用。
  ///
  /// 迁移自 GetxController.onReady —— onReady 在 GetX 里是页面首帧后执行，
  /// 这里改成页面显式调用（页面用 addPostFrameCallback 排队）。
  void onReady() {
    final err = loadError; // 页面已挂载，这里弹提示才安全
    if (err != null) AppSnackbar.show('错误', err, isError: true);
  }

  @override
  void dispose() {
    _disposed = true; // 【临时诊断】后面的日志不要再打了

    // 退出播放页时必须还原窗口：不还原的话用户返回后整个程序还卡在全屏/最大化，
    // 连标题栏都没有，无从操作。
    _restoreWindowOnLeave();
    // 弹幕连接必须在销毁前停掉：三个客户端都是自己重连的常驻连接，
    // 不显式关闭的话退出房间后 socket/心跳定时器还在后台跑。
    _stopDanmaku();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _reconnectTimer?.cancel();
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;

    // 先 stop 再 dispose：让播放器有序收尾（停掉解码线程、断开网络），
    // 比直接 dispose 更稳妥。dispose 不能 await，所以用 stop().then() 串起来。
    player
        .stop()
        .then((_) {
          return player.dispose();
        })
        .catchError((_) {
          // stop 抛异常时仍然尝试 dispose，尽最大努力释放资源
          return player.dispose();
        });

    super.dispose();
  }

  // 后端逻辑入口
  Future<void> _initBackendLogic() async {
    // 1) 重入保护：刷新按钮连点 / onInit 与手动 reload 撞车
    if (isLoading) {
      debugPrint('[$runtimeType] 忽略重复请求: $args');
      return;
    }

    // 2) 参数校验：非法参数不要发请求
    if (!LiveRoomArgs.isValidRoomId(roomId)) {
      loadError = '房间号非法: $roomId';
      roomInfo = null;
      roomDetail = null;
      return;
    }

    isLoading = true;
    loadError = null;
    // 这里刻意 **不清** roomShowStatus：从「未开播」面板点刷新时，拉取最长要 15 秒，
    // 中途清空会让页面把视频区插回布局，闪一块黑屏。状态统一在确认为开播后清
    // （见下面成功分支），或由 _onLoadFailed / _onRoomNotLive 覆盖。

    // 直播调优属性必须在任何 open 之前写完（幂等，只第一次真正执行）。
    // 放在这里而不是 init()：init() 是同步方法，无法 await，
    // 属性写和 open 会竞争；这里是 async，await 完再往下拉流起播。
    await _applyMpvLiveProperties();

    final stopwatch = Stopwatch()..start();
    debugPrint('[$runtimeType] 开始获取直播间: $args');

    try {
      // 3) 超时保护 + 平台分发
      final live_room_information = await _fetchRoomInfo().timeout(
        _kFetchTimeout,
        onTimeout: () => throw TimeoutException('请求超时(${_kFetchTimeout.inSeconds}s)'),
      );

      // 4) 空结果按错误处理（未开播 / 房间号不存在 / 页面结构变了）
      if (live_room_information == null) {
        throw Exception('程序出错，未获取到直播间信息（可能平台选择错误或者该房间号不存在）');
      }

      // 4.1) 未开播 / 被封禁：平台正常返回的**业务状态**，不是获取失败。
      // 必须在这里直接 return，两个原因：
      //   1) switch 本身不会中断外层流程，不 return 就会继续执行下面的成功分支，
      //      于是 roomInfo 被填上、_openCurrentStream() 也照跑，页面变成一个
      //      「有房间信息但永远没有画面」的假播放页；
      //   2) 这类状态不能用 _onLoadFailed 表达 —— 它写 loadError 并弹错误提示，
      //      而重连逻辑(_reconnectStream)一读到 loadError 就会继续排重连，
      //      对着一个没开播的房间无限重试。
      final showStatus = live_room_information.roomInfo.show_status ?? LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN;
      switch (showStatus) {
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN:
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE:
          _onRoomNotLive(showStatus, live_room_information.roomInfo, stopwatch);
          return;
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE:
          break; // 正常开播，继续走下面的成功分支
        case LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN:
        default:
          // 状态未知 = 平台返回里没给出可信状态（或解析不到），
          // 和「房间号不存在 / 页面结构变了」归为同一类：真的获取失败，走错误页。
          throw Exception('程序出错，未获取到直播间信息（可能平台选择错误或者该房间号不存在）');
      }

      // 5) 成功：元信息给页面，默认流给播放器
      roomShowStatus = null; // 确认为开播，清掉上一轮的未开播/封禁面板
      roomDetail = live_room_information;
      roomInfo = live_room_information.roomInfo;
      defaultStream = live_room_information.defaultStream;
      _syncFavoriteState(); // 拿到房间信息才能判断关注状态

      // 6) 起播：把选中的流交给 media_kit
      await _openCurrentStream();

      // 7) 接入弹幕（当前只在右侧栏展示）。
      //    不 await：弹幕要走各自的握手/签名网络请求，等下去会拖慢起播；
      //    _startDanmaku 内部已把异常全部兜住，失败只影响弹幕栏，不影响播放。
      unawaited(_startDanmaku());

      debugPrint(
        '[${runtimeType}] 获取成功 ${stopwatch.elapsedMilliseconds}ms: '
        '${live_room_information.roomInfo.room_name} / ${live_room_information.roomInfo.owner_name} / '
        '清晰度 ${live_room_information.roomInfo.video_set.length} 个 / '
        '默认流 ${live_room_information.defaultStream != null} / '
        '可切清晰度 ${availableQualities.length} 个',
      );
    } on TimeoutException catch (e) {
      _onLoadFailed('连接超时，请检查网络或稍后重试', e, stopwatch);
    } on ArgumentError catch (e) {
      // 参数类错误：提示但不重试
      _onLoadFailed('直播间参数错误: ${e.message}', e, stopwatch);
    } catch (e, stack) {
      // 平台解析失败（JSON 结构变化等）都会落到这里
      _onLoadFailed('获取直播间信息失败: $e', e, stopwatch, stack: stack);
    } finally {
      isLoading = false;
      stopwatch.stop();
    }
  }

  /// 统一收口失败状态，避免每处都重复写 4 行
  void _onLoadFailed(String message, Object error, Stopwatch stopwatch, {StackTrace? stack}) {
    roomInfo = null;
    roomDetail = null;
    defaultStream = null;
    roomShowStatus = null; // 真失败，不是未开播，清掉状态通道避免页面显示串味
    isFavorited = false; // 房间信息已丢弃，关注状态无从判断，别留上一间房的高亮
    isSpecialFollowed = false; // 同上，两个按钮必须一起复位
    loadError = message;
    unawaited(player.stop());
    debugPrint(
      '[${runtimeType}] 获取失败 ${stopwatch.elapsedMilliseconds}ms: $message'
      '${stack == null ? '' : '\n$stack'}',
    );
    // 失败不再进播放页正常界面，直接小弹窗报错后退出
    _abortWithDialog('无法进入直播间', message);
  }

  /// 收口「直播间未开播 / 被封禁」。
  ///
  /// 【正常情况下这里不会被触发】进房的「能不能播」判断已经提前到首页
  /// （见 HomeController.openLiveRoom）：未开播的房间根本不会跳到本页。
  /// 保留这个分支只作为兜底 —— 状态在首页查完之后、本页发起请求之前发生了变化
  /// （比如主播刚好下播），此时仍要有个合理收场，不能停在一个放不了的空页上。
  ///
  /// 不写 loadError：它是「获取失败」的信号，重连逻辑读到就会继续排重连，
  /// 对着一个没开播的房间无限重试。
  void _onRoomNotLive(LIVE_SHOW_STATUS_E status, LiveRoomInfo room, Stopwatch stopwatch) {
    roomInfo = null;
    roomDetail = null;
    defaultStream = null;
    loadError = null;
    unawaited(player.stop());
    roomShowStatus = status;
    debugPrint('[$runtimeType] 直播间未开播/不可用 ${stopwatch.elapsedMilliseconds}ms: ${_showStatusText(status)}');
    _abortWithDialog('无法进入直播间', '${_showStatusText(status)}${(room.owner_name ?? '').isEmpty ? '' : '\n${room.owner_name}'}');
  }

  /// 进不了直播间时的统一出口：小弹窗报错，关掉后自动退回上一页。
  ///
  /// 设计要点：
  ///   1) **用 dialog 而不是 snackbar** —— snackbar 从底部滑出、几秒就消失，
  ///      用户很可能错过；进不去房间是阻断性结果，需要用户确认一下。
  ///   2) **关掉后自动返回** —— 否则用户会停留在一个什么都放不了的播放页上，
  ///      还得自己点返回。返回动作串在 dialog 的 future 上，保证先看完提示再退。
  ///   3) **幂等** —— 一次进入只弹一次。_abortDialogShown 挡住重复调用
  ///      （未开播分支和 catch 分支在某些平台响应下可能先后触发）。
  bool _abortDialogShown = false;

  void _abortWithDialog(String title, String content) {
    if (_abortDialogShown || _disposed) return;
    _abortDialogShown = true;

    // 页面可能还没挂载完（_initBackendLogic 在 onInit 里就跑了），
    // 这时候弹 dialog 会因为拿不到 Navigator/Overlay 而失败。
    // 用 addPostFrameCallback 等一帧，确保首帧已构建、导航器已就绪。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 这一帧到来时页面可能已经因为别的原因退掉了（比如用户手快点了返回），
      // 此时再弹窗会盖在首页上，非常突兀，直接放弃。
      if (_disposed) return;
      // 【从 Get.dialog 换成 showDialog】
      // 路由迁到 go_router 后 GetX 不再持有 Navigator，Get.key / Get.dialog
      // 都失效了。这里改用 AppRouter.rootNavigatorKey 拿全局 context 弹窗。
      final context = AppRouter.rootNavigatorKey.currentContext;
      if (context == null) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Text(content, style: const TextStyle(fontSize: 14)),
          actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
          // 紧凑一点，避免在大屏上显得空旷
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.only(right: 12, bottom: 8),
        ),
        // 点外面不关闭：必须让用户明确点「知道了」再退出，避免误触后一脸茫然
        barrierDismissible: false,
      ).then((_) {
        if (_disposed) return;
        _leaveRoomPage();
      });
    });
  }

  /// 从播放页退回上一页。
  ///
  /// 【从 Get.back / Get.offAllNamed 换成 GoRouter】
  /// `Get.key.currentState` 只在 GetMaterialApp 下有效，现在路由是 go_router，
  /// 所以退页面统一走 `AppRouter.router`：
  ///   * 有上一页 → `pop()`：正常从名片进来的情况；
  ///   * 没有上一页（深链接直接起播、DevBoot 直达）→ `go('/home')` 回首页，
  ///     而不是留在空页面上。
  void _leaveRoomPage() {
    final router = AppRouter.router;
    if (router.canPop()) {
      router.pop();
      return;
    }
    router.go(RoutePath.p_home);
  }

  /// 状态文案：只在这里维护一份，页面直接用
  String _showStatusText(LIVE_SHOW_STATUS_E status) {
    // 用 switch 表达式而不是 switch 语句：枚举穷尽性由编译器保证，
    // 以后在 LIVE_SHOW_STATUS_E 里加状态时，这里会直接编译不过，不会静默漏掉。
    return switch (status) {
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE => '直播中',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE => '主播未开播',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN => '直播间已被封禁',
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN => '直播间状态未知',
    };
  }

  /// 拉取房间信息。
  ///
  /// 平台差异全部封在 LiveSource 实现里，这里不再按平台分支。
  Future<LiveRoomDetail?> _fetchRoomInfo() async {
    final source = _source;
    if (source == null) {
      throw Exception('没有可用的后端实现：${site.name}');
    }
    return source.fetchRoom(roomId);
  }

  // 给页面"刷新/重试"按钮用
  Future<void> reload() {
    // 用户手动重试 = 把重连配额还给他，否则一次重连打满后
    // 后面每次断流都会直接放弃。
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _userPaused = false;
    return _initBackendLogic();
  }

  // ===== 关注 / 特别关注 =====

  /// 按当前房间信息刷新「关注」「特别关注」两个按钮的高亮状态。
  /// 在 roomInfo 落地后调用（成功分支 / 未开播分支都要调，
  /// 未开播的房间同样能关注）。
  void _syncFavoriteState() {
    final info = roomInfo;
    final id = _favoriteRoomId(info);
    if (id == null) {
      isFavorited = false;
      isSpecialFollowed = false;
      return;
    }
    isFavorited = FavoriteStore.instance.contains(site, id);
    // 特别关注必须依附于关注：没关注时强制 false，避免出现「没关注却是特别关注」的脏状态
    isSpecialFollowed = isFavorited && FavoriteStore.instance.isSpecialFollowed(site, id);
  }

  /// 收藏用的房间号：直接用平台返回的 room_id。
  ///
  /// 斗鱼 = 房间号、抖音 = web_rid（都等于进入直播间用的那个号）；
  /// B 站 = 真实 room_id（不是 short_id，因为重进直播间用的就是它）；
  /// 虎牙 = 数字房间号；快手 = 带字母的短 id。
  /// room_id 为空时才退回 fake_room_id，避免存不进收藏。
  String? _favoriteRoomId(LiveRoomInfo? info) {
    if (info == null) return null;
    if (LiveRoomArgs.isValidRoomId(info.room_id)) return info.room_id.trim();
    final fallback = info.fake_room_id?.trim();
    return LiveRoomArgs.isValidRoomId(fallback) ? fallback : null;
  }

  /// 点「关注」：已关注则取消，未关注则写入。写入成功后按钮立即变色，
  /// 不需要等主页刷新。
  ///
  /// 取消关注时会连带的把特别关注一起清掉（记录整条删掉，无从保留）。
  Future<void> toggleFavorite() async {
    final info = roomInfo;
    final id = _favoriteRoomId(info);
    if (info == null || id == null) {
      AppSnackbar.show('关注失败', '还没有拿到直播间信息，稍后再试');
      return;
    }

    if (FavoriteStore.instance.contains(site, id)) {
      await FavoriteStore.instance.remove(site, id);
      isFavorited = false;
      isSpecialFollowed = false;
      // Get.snackbar('已取消关注', info.owner_name ?? '');
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
        // 普通关注默认不特别关注，用户想置顶到主页再点隔壁的按钮
        specialFollowed: false,
      ),
    );
    isFavorited = true;
    isSpecialFollowed = false;
    // Get.snackbar('已关注', info.owner_name ?? '');
  }

  /// 点「特别关注」：在关注与特别关注之间切换。
  ///
  /// 未关注时点它 = 一步到位「关注 + 特别关注」，
  /// 不让用户先点关注再点特别关注，多此一举。
  Future<void> toggleSpecialFollow() async {
    final info = roomInfo;
    final id = _favoriteRoomId(info);
    if (info == null || id == null) {
      AppSnackbar.show('操作失败', '还没有拿到直播间信息，稍后再试');
      return;
    }

    final next = !isSpecialFollowed;

    if (!FavoriteStore.instance.contains(site, id)) {
      // 还没关注：直接写一条 specialFollowed = true 的记录
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
      isFavorited = true;
      isSpecialFollowed = true;
      // Get.snackbar('已特别关注', info.owner_name ?? '');
      return;
    }

    await FavoriteStore.instance.setSpecialFollowed(site, id, next);
    isSpecialFollowed = next;
    // 取消特别关注后仍然是关注状态，按钮要跟着回到「已关注」
    isFavorited = true;
    // Get.snackbar(next ? '已特别关注' : '已取消特别关注', info.owner_name ?? '');
  }

  // ===== 断流重连 =====

  /// 断流后安排一次重连（带退避）。重复调用只保留先来的那一次。
  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    if (_reconnectTimer != null) return; // 已经排上了
    if (_userPaused) return; // 用户主动暂停
    if (isSwitchingQuality) return; // 切画质本来就要重新 open，别插一脚
    if (isLoading) return; // 已经有一轮加载在跑
    if (roomInfo == null && !_hasPlayedOnce) return; // 首播就失败：交给错误页，不重连
    // 未开播 / 被封禁：这是业务状态，不是断流。这条闸门必须有，两个原因：
    //   1) _onRoomNotLive 会 player.stop()，stop 的终态同样会推 completed(EOF)，
    //      上面「roomInfo 非空才算起播过」那道闸门挡不住（此时 roomInfo 恰好是有的）；
    //   2) 房间没开播时重取多少次都还是没开播，自愈无意义，界面上的「刷新」才该是出口。
    if (roomShowStatus != null) return;

    // 上一轮如果播够久了，说明这次断流是个新问题，计数清零重新算，
    // 避免「播 7 分钟断一次」被累计到上限后永久放弃重连。
    final startedAt = _roundStartedAt;
    if (startedAt != null && DateTime.now().difference(startedAt) >= _kStablePlaybackThreshold) {
      _reconnectAttempts = 0;
    }
    // 立刻作废本轮计时。否则若重连时「重新拉房间信息」就失败了，
    // _openCurrentStream 不会被执行、计时不会被刷新，于是每次重试看到的
    // 都还是上一轮那个「已经播了 7 分钟」的时间戳，计数被反复清零，
    // 变成 1 秒一次的死循环重连。置空后：直到真正起播成功才会重新计时。
    _roundStartedAt = null;

    if (_reconnectAttempts >= _kMaxReconnectAttempts) {
      debugPrint('[$runtimeType] $reason，但重连次数已达上限($_kMaxReconnectAttempts)，放弃');
      playError = '直播流已中断，请点击重试';
      return;
    }

    _reconnectAttempts++;
    // 退避 1s / 2s / 4s / 8s
    final seconds = 1 << (_reconnectAttempts - 1).clamp(0, 3).toInt();
    debugPrint('[$runtimeType] $reason ⇒ 第 $_reconnectAttempts/$_kMaxReconnectAttempts 次重连，${seconds}s 后重取地址');

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      unawaited(_reconnectStream());
    });
  }

  /// 真正重连：**重新拉一次房间信息**拿新地址，再起播。
  ///
  /// 不能拿旧 URL 再 open 一次：斗鱼地址带 expire=300 的短时效签名，
  /// 连接被 CDN 掐断后签名本身也已作废，重放必然立刻失败。
  Future<void> _reconnectStream() async {
    if (_disposed) return;
    // 如果这会儿已经有人在加载（例如用户手点了「重试」），让对方跑完即可，
    // 它自己就会重新起播。这里必须让位，否则 _initBackendLogic 的重入保护
    // 会直接 return，而下面就会读到一个陈旧的 loadError 并白排一次重连。
    if (isLoading) return;
    debugPrint('[$runtimeType] 开始重连：重新获取直播间信息以换取新的播放地址');
    // 复用现有的加载入口：它内部会重建 roomDetail 并调用 _openCurrentStream，
    // 渲染上下文闸门(epoch/stale 保护)也随之复用，不另起一套。
    await _initBackendLogic();
    if (_disposed) return;
    // 重新拉房间信息本身也可能失败（网络抖动）。这时不该就此放弃，
    // 继续走退避重试，直到 _kMaxReconnectAttempts 用完为止。
    if (loadError != null) {
      debugPrint('[$runtimeType] 重连拉取房间信息失败: ${loadError}');
      _scheduleReconnect('重连失败');
    }
  }

  // ===== media_kit：起播 / 切清晰度 =====

  /// 用当前选中的流打开播放器（切清晰度其实就是换一条 URL 重新 open）
  Future<void> _openCurrentStream() async {
    final stream = playingStream;
    if (stream == null) {
      playError = '没有可用的播放地址（可能未开播）';
      return;
    }

    final url = _pickPlayableUrl(stream, currentLine);
    // final url = "file:///C:/Users/yanmo/Pictures/evoles/evolesbian/hq1dMhgZfnq9v56Z.mp4";
    if (url == null) {
      playError = '当前清晰度没有可用的线路';
      return;
    }

    playError = null;
    // 用 debugPrint 而非 Get.log：后者在桌面端不写 stdout，终端排查时看不到。
    debugPrint('[$runtimeType] 起播: ${stream.name} -> $url');

    final epoch = ++_openEpoch;
    // 新一轮起播：本轮计时重置。否则「播够 10 秒就算稳定」会把上一轮的时间
    // 算进来，让「起来就死」被误判成稳定，重连计数被错误清零。
    _roundStartedAt = DateTime.now();

    // 【关键时序修复】必须在 player.open 之前完成 —— 见 _awaitRenderContextReady 注释
    await _awaitRenderContextReady();
    if (_disposed) return;
    // 等闸门期间如果又发起了一次起播（例如加载中点切换画质），本次就作废，
    // 避免两次 open 互相打断导致花屏/黑屏。
    if (epoch != _openEpoch) {
      debugPrint('[$runtimeType] 起播已被更新的请求取代，放弃本次(epoch=$epoch, now=$_openEpoch)');
      return;
    }
    try {
      // 必须带超时：纹理没注册时 mpv 永远不发 file-loaded，open() 会永久挂起，
      // 连带把 isLoading / 弹幕启动全部卡死（详见 _kOpenTimeout 注释）。
      await player.open(Media(url, httpHeaders: roomInfo?.http_header), play: true).timeout(_kOpenTimeout);
      // open 之后音量会被重置，这里补一次。
      //
      // 【必须带超时，否则「超时兜底」会变成「永久卡死」】media_kit 的 NativePlayer
      // 所有方法共用同一把 `static final Lock lock`，setVolume 默认 synchronized: true
      // 也要排队拿这把锁。上面那行 `.timeout()` 只是放弃「等待」open，**底层 open 仍在
      // 跑、仍占着锁**；一旦 open 是卡住的（正是我们要兜底的那种情况），这一句就会
      // 永远排在它后面拿不到锁 —— 于是 `_openCurrentStream` 永不返回、`_initBackendLogic`
      // 的 finally 永不执行、isLoading 一直是 true、日志也就此断掉，表现就是整体卡死。
      // 音量补写失败无所谓，绝不能让它拖死整条起播流程。
      try {
        await player.setVolume(volume).timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[$runtimeType] open 后补写音量失败/超时，忽略: $e');
      }
    } on TimeoutException {
      // 不 return：继续往下走，让弹幕能起来、让界面把问题显示出来，而不是静默黑屏
      playError = '打开播放器超时（原生渲染未就绪，画面可能仍是黑的）';
      debugPrint('[$runtimeType] player.open 超过 ${_kOpenTimeout.inSeconds}s 未返回，放弃等待继续后续流程');
    } catch (e) {
      playError = '播放失败: $e';
      debugPrint('[$runtimeType] 播放失败: $e');
    }

    // 诊断必须放在 open 之后，计时才有意义
    unawaited(_probeFirstFrame(epoch));
  }

  /// 【关键时序修复】起播前必须确保 mpv 的渲染上下文已经存在。
  ///
  /// 背景：mpv 初始化 `vo=libmpv` 时需要 render context。
  /// 如果 player.open() 先跑，而页面的 Video widget 还没 build（VideoController 未创建、
  /// 纹理/渲染上下文未注册），mpv 就会直接报：
  ///   [mpv][fatal][vo/libmpv] No render context set. → Video: no video
  /// 表现为「有声音、黑屏」，并且 VO 一旦初始化失败是**不可恢复**的（后续不会再重试）。
  ///
  /// 斗鱼的 FLV 直链几乎瞬间就完成 avformat_find_stream_info()，所以它总是抢在
  /// 页面布局之前，必黑；B 站/抖音的 HLS 起播要 1s 左右，恰好被页面布局盖住了这个竞态，
  /// 所以之前只有斗鱼黑屏。
  ///
  /// 这里等的是「页面已经把视频区域布局出来」的信号（页面在 LayoutBuilder 里
  /// post-frame 通知），此时 VideoController 一定已经构造完、渲染上下文已注册。
  /// 注意：**不能** await `_videoControllerReady.future` 来代替它 —— 那个 future 只有在
  /// 页面 build 到 Video widget 时才完成，而页面又依赖 isLoading，提前 await 会死锁。
  ///
  /// 两段等待都要做，缺一不可（依据实测日志）：
  ///   23:37 失败那轮：vo fatal=14.75s、布局完成=14.947s、纹理 ID 落地=15.381s。
  /// 布局完到纹理真正注册之间还有 ~0.4s，只等布局仍会让 open 抢跑，
  /// 所以第二段必须等 `videoController.id` 从 null 变成真实 ID ——
  /// 那是原生纹理输出（连同 render context）建好并回传的唯一可靠标志。
  /// 两段都是「有超时、超时就放行」，任何情况下都不会把起播卡死。
  Future<void> _awaitRenderContextReady() async {
    if (_disposed) return;

    // 第一段：等页面把视频区域布局出来（这一步会让 VideoController 被创建）
    //
    // 【超时不要 return】宁可继续往下等 VideoController / 纹理，
    // 直接返回等于跳过后面所有保障，又回到「open 抢跑 → 原生崩溃」那条路。
    try {
      await _videoSurfaceLaidOut.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (!_disposed) {
        debugPrint('[$runtimeType] 等待视频区域布局超时(3s)，继续等渲染上下文');
      }
    }
    if (_disposed) return;

    // 第二段：等 VideoController 真正被创建出来。
    //
    // 【这里曾经有个致命时序漏洞】
    // 原代码直接写 `final vc = _videoController; if (vc != null ...)` ——
    // 页面刚布局完、但还没 build 出 Video widget 时，_videoController 仍然是 null，
    // 于是这一段被**整个跳过**，player.open() 抢在渲染上下文之前执行。
    //
    // 实测日志（抖音直播间闪退）：
    //   [LiveStreamController] 起播: 蓝光 -> ....flv   ← open 先跑
    //   media_kit: VideoOutput: Flutter's EGL config ID: 51   ← 549ms 后才有 EGL
    //   Lost connection to device
    // mpv 在没有 render context 的情况下开始解 FLV，原生层直接崩。
    // B站/斗鱼没崩是因为它们的流起播慢、恰好被别的等待盖住了这个竞态。
    try {
      await _videoControllerReady.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (!_disposed) {
        debugPrint('[$runtimeType] 等待 VideoController 创建超时(3s)，继续尝试等纹理');
      }
    }
    if (_disposed) return;

    // 第三段：等原生纹理 ID 落地（= 渲染上下文已注册）
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

  /// 直播流每条清晰度下都有多条线路(协议+编码)，优先选兼容性最好的那条。
  ///
  /// [lineIndex] 是用户手动指定的线路序号；为 null 时按兼容性自动挑最优。
  /// 序号越界（比如换了画质后线路变少）会退回自动挑，不会抛错。
  static String? _pickPlayableUrl(LiveStreamInfo stream, [int? lineIndex]) {
    final candidates = _sortLines(stream);
    if (candidates.isEmpty) return null;

    if (lineIndex != null && lineIndex >= 0 && lineIndex < candidates.length) {
      return candidates[lineIndex].$3;
    }
    return candidates.first.$3;
  }

  /// 把某条清晰度下的所有线路按「兼容性从好到差」排好。
  /// 排序结果即 UI 上的线路序号：线路1 = 最优，线路2 = 次优 ……
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
    if (isSwitchingQuality) return;
    if (quality == LIVE_VIDEO_QUALITY.UNKNOWN) return;
    if (currentQuality == quality) return;

    isSwitchingQuality = true;
    try {
      // 该清晰度还没拿到地址（斗鱼只填了当前 rate 的那一条），按需向平台重取
      if (!(roomDetail?.roomInfo.video_set[quality]?.stream_url.isNotEmpty ?? false)) {
        final ok = await _fetchStreamForQuality(quality);
        if (!ok) {
          AppSnackbar.show('切换画质失败', '${qualityName(quality)} 暂时没有可用线路');
          return;
        }
      }

      selectedQuality = quality;
      // 换画质后线路条数和顺序都可能变（比如 B 站高清晰度才有 HEVC 那条），
      // 手上这个线路序号对新画质没有意义，复位成「自动挑最优」。
      selectedLine = 0;
      await _openCurrentStream();
    } finally {
      isSwitchingQuality = false;
    }
  }

  /// ===== 线路切换 =====
  ///
  /// 同一清晰度下平台往往给了多条流（不同协议/编码/CDN），它们内容相同、画质相同，
  /// 只是传输方式不一样 —— 某条线路卡顿或连不上时，换一条即可。
  /// 序号从 0 开始，对应 [_sortLines] 排序后的下标：0 = 兼容性最好的那条。

  /// 用户当前选中的线路序号，跟随 _openCurrentStream 生效
  /// 用户当前选中的线路序号，跟随 _openCurrentStream 生效
  int _selectedLine = 0;
  int get selectedLine => _selectedLine;
  set selectedLine(int v) {
    _selectedLine = v;
    notifyListeners();
  }

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
    // clamp 的返回类型是 num，这里显式取整
    return selectedLine.clamp(0, count - 1).toInt();
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
    if (isSwitchingQuality) return;

    final count = availableLines.length;
    if (count == 0 || index < 0 || index >= count) return;
    // 点的就是当前这条，不用重新 open（重开反而会黑屏一下）
    if (index == currentLine) return;

    isSwitchingQuality = true;
    try {
      selectedLine = index;
      await _openCurrentStream();
    } finally {
      isSwitchingQuality = false;
    }
  }

  /// 按需向平台再要一次指定清晰度的流；不支持/失败返回 false
  Future<bool> _fetchStreamForQuality(LIVE_VIDEO_QUALITY quality) async {
    final source = _source;
    if (source == null) return false;

    try {
      // 清晰度到平台参数的映射（qn / video_rate / sdk_key）在各平台适配器里，
      // 这里只管「要这个清晰度」和「把结果挂上去」。
      final stream = await source.fetchStream(roomId, quality);
      return _adoptFetchedStream(quality, stream);
    } catch (e) {
      debugPrint('[$runtimeType] 重取清晰度失败($quality): $e');
      return false;
    }
  }

  /// 把平台重取回来的流挂到当前 roomDetail 上。
  ///
  /// 抖音在地址过期时会重新拉一次房间信息，生成的是**新的** LiveRoomInfo，
  /// 而页面读的一直是 roomDetail 里那个旧对象；这里显式回写，避免切完画质
  /// 页面还拿着旧 map（表现为点了没反应）。
  bool _adoptFetchedStream(LIVE_VIDEO_QUALITY quality, LiveStreamInfo? stream) {
    if (stream == null || stream.stream_url.isEmpty) return false;

    final room = roomDetail?.roomInfo;
    if (room != null && !identical(room.video_set[quality], stream)) {
      room.video_set[quality] = stream;
    }
    return true;
  }

  // ===== media_kit：音量 =====

  /// 设置音量 0~100
  Future<void> setVolume(double value) async {
    final v = value.clamp(0.0, 100.0).toDouble();
    volume = v;
    if (v > 0) _lastVolume = v;
    await player.setVolume(v);
  }

  /// 静音 / 恢复
  Future<void> toggleMute() async {
    if (volume > 0) {
      _lastVolume = volume;
      await setVolume(0);
    } else {
      await setVolume(_lastVolume <= 0 ? 100 : _lastVolume);
    }
  }

  // ===== 操作方法 =====
  Future<void> togglePlay() async {
    // isPlaying 由 player.stream.playing 回写，这里只发指令
    final playing = player.state.playing;
    if (playing) {
      // 用户主动暂停：把待重连取消掉，别在暂停状态下自己又起播
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
    isDanmakuOn = !isDanmakuOn;
    // TODO: 挂起/恢复弹幕渲染逻辑
  }

  void setShowControls(bool show) {
    // 画质菜单展开期间不接受「收起」请求：菜单挂在 overlay 上，鼠标过去必然触发 onExit，
    // 直接透传就会把控制栏收掉，导致弹框和控制栏不能同时出现。
    if (!show && isQualityMenuOpen) return;

    // 取消上一次的自动隐藏计时器（不管是「显示」重置倒计时，还是「隐藏」直接收掉）
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;

    showControls = show;

    // 显示后启动自动隐藏：桌面端也启用（鼠标静止太久也该收），
    // 但桌面端 MouseRegion.onExit 会更快触发隐藏，这里只是兜底。
    if (show) {
      _hideControlsTimer = Timer(_kControlsAutoHideDelay, () {
        if (!isQualityMenuOpen) {
          showControls = false;
        }
      });
    }
  }

  /// 切换控制栏显隐（点击视频区时调用）。
  ///
  /// 当前隐藏 → 显示并启动自动隐藏计时器；
  /// 当前显示 → 立即隐藏。
  void toggleControls() {
    if (showControls) {
      setShowControls(false);
    } else {
      setShowControls(true);
    }
  }

  /// 上次点击视频区的时间，用于手动双击检测（避免 StatelessWidget 重建丢失）。
  DateTime? _lastVideoTapTime;

  /// 视频区点击：单击切换控制栏，300ms 内第二次点击触发退出全屏/自适应。
  void onVideoTap() {
    final now = DateTime.now();
    if (_lastVideoTapTime != null && now.difference(_lastVideoTapTime!) < const Duration(milliseconds: 300)) {
      // 双击：退出全屏或退出自适应（两者都是"铺满"状态）
      _lastVideoTapTime = null;
      if (isFullscreen) {
        toggleFullscreen();
      } else if (isFitWindow) {
        toggleFitWindow();
      }
    } else {
      // 单击：切换控制栏
      _lastVideoTapTime = now;
      toggleControls();
    }
  }

  /// 标记画质菜单的展开状态。
  void setQualityMenuOpen(bool open) {
    isQualityMenuOpen = open;
    if (open) showControls = true;
  }

  // ===== 播放页控制栏：刷新 / 全屏 / 适配窗口 =====
  bool _isFullscreen = false;
  bool get isFullscreen => _isFullscreen;
  set isFullscreen(bool v) {
    _isFullscreen = v;
    notifyListeners();
  }

  /// 是否处于「适配窗口」状态：视频画面铺满整个 App 窗口（BoxFit.cover）。
  bool _isFitWindow = false;
  bool get isFitWindow => _isFitWindow;
  set isFitWindow(bool v) {
    _isFitWindow = v;
    notifyListeners();
  }

  /// 直链：取当前正在播放的那条流的原始地址。
  Future<String> get_clarity_vido_play_url() async {
    final stream = playingStream;
    if (stream == null) return '';

    // 和起播走同一套选路逻辑，保证「复制到的就是正在播的」
    final url = _pickPlayableUrl(stream, currentLine);
    return url ?? '';
  }

  /// 刷新：重新拉一次房间信息并重新起播。
  Future<void> refreshStream() async {
    if (isLoading) return;
    // 用户手动刷新，把自动重连的退避计时器一并清掉，避免刷新后又被旧定时器打断
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    playError = null;
    await reload();
  }

  /// 适配窗口：把视频画面放大到铺满整个 App 窗口（不改变窗口本身的大小）。
  void toggleFitWindow() {
    final next = !isFitWindow;
    isFitWindow = next;
    if (next) {
      // 适配窗口期间画满全屏由它自己负责，别和全屏叠加
      exitFullscreenIfNeeded();
      // 用 setShowControls 而不是直接赋值：顺带启动自动隐藏计时器，
      // 否则顶部悬浮工具栏会一直挂着不自动收起。
      setShowControls(true);
    }
  }

  /// 正在切换全屏。
  ///
  /// 【必须有这个开关】toggleFullscreen 里有多处 await（切方向、切窗口、等帧），
  /// 期间用户再点一次就会并发跑第二遍：两次 _setWindowFullscreen 交错执行，
  /// 窗口尺寸来回跳，纹理更容易卡死。加了它之后快速连点会被忽略，
  /// 视觉上也更符合直觉。
  bool _isTogglingFullscreen = false;

  /// 全屏/退出全屏：视频区铺满 App 窗口 + 窗口本身进入全屏
  ///
  /// 【桌面端和移动端必须分开处理，原因是「屏幕方向」】
  ///
  /// 桌面端没有屏幕旋转，只有窗口尺寸变化：
  ///   界面先切布局、窗口在后台跟上，用户立刻看到响应，手感最顺。
  ///
  /// 移动端必须先切方向、再切布局：
  ///   如果像桌面端那样「先改 isFullscreen，再异步转屏幕」，
  ///   退出全屏时页面会先按**横屏宽度**重建上下布局，
  ///   等屏幕转回竖屏时布局已经算完、不会重算 ——
  ///   表现就是「视频区缩在左侧一小块，没恢复上下结构」。
  ///   所以移动端必须 await 方向切换，让布局在正确的屏幕尺寸下计算。
  Future<void> toggleFullscreen() async {
    // 上一次切换还没跑完：直接忽略，避免窗口尺寸被两次调用来回拉扯
    if (_isTogglingFullscreen) {
      debugPrint('[$runtimeType] 正在切换全屏，忽略这次点击');
      return;
    }
    _isTogglingFullscreen = true;

    try {
      final next = !isFullscreen;

      if (PlatformSupport.isDesktop) {
        // ---------- 桌面端：界面先动，窗口并发 ----------
        //
        // 平台通道调用（setFullScreen）要等系统把窗口状态切完才返回，
        // 但界面上的布局切换不等它 —— 用户要的是「点了立刻有反应」，
        // 窗口的标题栏稍后消失完全不影响观感。
        _applyFullscreenState(next);
        unawaited(_setWindowFullscreen(next));

        // 等一帧把新尺寸的布局画完，再刷新纹理，避免画面停在最后一帧
        await WidgetsBinding.instance.endOfFrame;
      } else {
        // ---------- 移动端：先转屏幕，再切布局 ----------
        //
        // 顺序不能反：布局必须在**目标屏幕尺寸**下计算。
        // 这里 await 是必要的，代价是退出全屏时多等一次旋转（系统行为，
        // 桌面端那种「不等」在移动端会直接导致布局错乱）。
        await _setLandscapeOrientation(next);
        if (_disposed) return;

        _applyFullscreenState(next);

        // 旋转完成后布局已经用新尺寸算过，再等一帧刷新纹理
        await WidgetsBinding.instance.endOfFrame;
      }

      if (_disposed) return;
      textureRefreshTick++;
      debugPrint('[$runtimeType] 全屏切换完成 next=$next tick=${textureRefreshTick}');
    } finally {
      // 无论成功、提前 return 还是抛异常，都必须解锁，
      // 否则用户会永久卡在「正在切换全屏，忽略这次点击」。
      _isTogglingFullscreen = false;
    }
  }

  /// 真正改布局状态（两部分共用，保证行为一致）。
  void _applyFullscreenState(bool next) {
    if (next) isFitWindow = false;
    isFullscreen = next;
    // 进全屏时把控制栏亮出来，否则一进去就是「看不见任何按钮」的黑屏感。
    // 用 setShowControls 顺带启动自动隐藏计时器，顶部悬浮工具栏也会跟着自动收起。
    if (next) setShowControls(true);
    // 全屏时保持屏幕常亮（手机端默认会进入睡眠，全屏看直播不能睡）
    // 桌面端 wakelock_plus 是空操作，不会出错
    unawaited(WakelockPlus.toggle(enable: next));
  }

  /// 纹理刷新计数器。
  ///
  /// 【为什么需要它】全屏切换后 Flutter 只重新布局视频区，不会重新提交
  /// 原生纹理，画面就停在最后一帧（声音正常）。自增这个值能让页面那边的
  /// Video/Texture 重新构建一次，把纹理重新绑定上去。
  ///
  /// 只在全屏切换后自增，平时不动，避免无谓的重建。
  int _textureRefreshTick = 0;
  int get textureRefreshTick => _textureRefreshTick;
  set textureRefreshTick(int v) {
    _textureRefreshTick = v;
    notifyListeners();
  }

  /// 手机端切换屏幕方向。桌面端空操作（桌面没有「屏幕方向」这个概念）。
  ///
  /// 进入全屏 → 锁定横屏 + 隐藏系统栏；
  /// 退出全屏 → 恢复竖屏 + 显示系统栏。
  ///
  /// 用 SystemChrome 而不是引入 orientation 包：这是 Flutter 自带的系统通道，
  /// 桌面端调用会被引擎忽略，不会报错，所以桌面端其实不需要额外判断；
  /// 这里仍然显式跳过，避免在桌面上产生无意义的日志。
  Future<void> _setLandscapeOrientation(bool landscape) async {
    if (PlatformSupport.isDesktop) return;

    try {
      if (landscape) {
        // 横屏：两个方向都允许，跟随手机翻转（左横屏/右横屏都行）
        await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        // 沉浸式：隐藏状态栏和导航栏，让画面真正铺满
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        // 退出全屏：恢复竖屏（手机端主界面是竖屏布局）
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
        // 恢复系统栏
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (e) {
      debugPrint('[$runtimeType] 切换屏幕方向失败: $e');
    }
  }

  /// 如果当前在窗口全屏，就退出来。供「适配窗口」等场景复用
  void exitFullscreenIfNeeded() {
    if (!isFullscreen) return;
    isFullscreen = false;
    unawaited(_setWindowFullscreen(false));
  }

  /// 设置窗口的最外层全屏状态（标题栏、任务栏一起隐藏）。
  ///
  /// 和「适配窗口」的区别：那个只改画面填充方式、不动窗口；
  /// 这个是让窗口本身全屏，退出只能靠 Esc 或界面上的退出全屏按钮。
  Future<void> _setWindowFullscreen(bool full) async {
    // 移动端没有窗口管理，全屏靠系统 UI 处理：
    // 这里直接跳过，页面层的 isFullscreen 状态照常生效（隐藏顶栏/侧栏，
    // 视频区铺满），只是不去动系统窗口。
    if (!PlatformSupport.supportsWindowManager) return;

    try {
      await windowManager.setFullScreen(full);
    } catch (e) {
      debugPrint('[$runtimeType] 设置窗口全屏失败: $e');
    }
  }

  /// 退出播放页时务必还原窗口/屏幕方向，否则用户返回后整个程序卡在全屏无从操作。
  ///
  /// 屏幕方向也要还原：手机端全屏时转成了横屏，如果用户按返回键退出，
  /// 而这里不恢复竖屏，回到首页就是横着的，很难受。
  void _restoreWindowOnLeave() {
    isFitWindow = false;
    // 释放屏幕常亮（全屏时开了 wakelock，离开必须关，否则回到首页手机也永不睡眠）
    unawaited(WakelockPlus.disable());
    if (!isFullscreen) return;
    isFullscreen = false;
    // 恢复竖屏 + 系统栏（移动端有效，桌面端空操作）
    unawaited(_setLandscapeOrientation(false));
    unawaited(_setWindowFullscreen(false));
  }
}
