import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// LogicalKeyboardKey 在 services 里，material 不会导出它
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ym_live_stream/core/route_path.dart';

import 'package:ym_live_stream/features/live_common.dart';
import 'package:ym_live_stream/features/live_site_meta.dart';
import 'package:ym_live_stream/presentation/app_router.dart';

import 'controller/live_room_controller.dart';
import 'widgets/app_snackbar.dart';
import 'widgets/danmaku_overlay.dart';

/// 直播间页面。
///
/// 【路由换到 go_router 之后，参数怎么进来】
/// 房间参数由 [AppRouter] 从 URL/extra 解析好，在构造页面前传入 `LiveStreamPage(args:)`，
/// 页面内部在 [_LiveStreamPageHost] 的 State 里创建 [LiveStreamController] 并持有，
/// 不再依赖 GetX 全局容器。
///
/// 【为什么外面套一层 StatefulWidget】
/// [LiveStreamController] 持有播放器、弹幕连接、重连定时器等重资源，
/// 必须由页面 State 的生命周期托管：initState 创建、dispose 回收，
/// 避免离开房间后资源泄漏。
class LiveStreamPage extends StatefulWidget {
  /// 打开哪个房间（由路由解析好传进来）
  final LiveRoomArgs args;

  const LiveStreamPage({super.key, required this.args});

  @override
  State<LiveStreamPage> createState() => _LiveStreamPageHost();
}

class _LiveStreamPageHost extends State<LiveStreamPage> {
  late final LiveStreamController _controller;

  /// 弹幕设置面板的 OverlayEntry。由 State 持有，dispose 时 remove。
  OverlayEntry? _danmakuPanelEntry;

  @override
  void initState() {
    super.initState();
    _controller = LiveStreamController(args: widget.args);
    _controller.init();
    // onReady 的逻辑需要等首帧渲染后再跑（弹 snackbar 需要 Navigator 就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.onReady();
    });
  }

  @override
  void dispose() {
    // 页面销毁 = 离开直播间：关掉弹幕面板，再回收 controller（含播放器/弹幕/定时器）
    _danmakuPanelEntry?.remove();
    _danmakuPanelEntry = null;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 【用 args 做 key】房间变了要换一个新的 View 元素（视频纹理、滚动位置
    // 都不能沿用上一个房间的）；同一房间重建时 key 不变，状态得以保留。
    return _LiveStreamPageView(
      key: ValueKey<String>('live_room_${widget.args.site.name}_${widget.args.roomId}'),
      args: widget.args,
      controller: _controller,
      danmakuPanelEntryRef: () => _danmakuPanelEntry,
      setDanmakuPanelEntry: (entry) => _danmakuPanelEntry = entry,
    );
  }
}

/// 直播间页面主体（StatelessWidget，由 [_LiveStreamPageHost] 持有 controller 实例传入）。
class _LiveStreamPageView extends StatelessWidget {
  /// 打开哪个房间（由路由解析好传进来）
  final LiveRoomArgs args;

  /// 由 Host State 创建并持有的 controller 实例。
  final LiveStreamController controller;

  /// 弹幕设置面板的 OverlayEntry 读写回调（面板条目存在 Host State 里，dispose 时统一 remove）。
  final OverlayEntry? Function() danmakuPanelEntryRef;
  final void Function(OverlayEntry? entry) setDanmakuPanelEntry;

  const _LiveStreamPageView({
    super.key,
    required this.args,
    required this.controller,
    required this.danmakuPanelEntryRef,
    required this.setDanmakuPanelEntry,
  });


  /// 视频区的稳定标识。
  ///
  /// 全屏切换时视频区的**包裹结构**会变（普通模式带具体边距、全屏是 Positioned.fill），
  /// 只有带上同一个 key，Flutter 才会把它认成同一个元素而不是新建一个。
  /// 不带 key 的话 Video 会被卸载重挂，原生纹理跟着重挂，
  /// 表现就是「进全屏后画面卡在最后一帧，退出再进又好了」。
  static const Key _videoAreaKey = ValueKey<String>('live-video-area');

  /// 顶部导航栏高度（和 _buildTopNavigationBar 里的 height 保持一致）
  static const double _kTopBarHeight = 48;

  /// 视频下方操作栏高度（和 _buildVideoBottomToolbar 里的 height 保持一致）
  static const double _kBottomToolbarHeight = 50;

  /// 右侧栏宽度（和 _buildRightSidebar 里的 width 保持一致）
  static const double _kSidebarWidth = 320;

  /// 右侧弹幕列表的字号。
  static const double _kDanmakuFontSize = 15;

  /// 右侧弹幕列表的固定行高（含上下留白）。
  static const double _kDanmakuRowHeight = 27;

  /// 手机端视频区域的宽高比。
  ///
  /// 直播源基本都是 16:9，手机竖屏下如果让视频铺满剩余空间，
  /// 画面会按 contain 缩放到中间一小条、上下全黑，很难看。
  /// 所以固定 16:9 高度，剩下的空间全部让给下方的信息 + 弹幕区。
  static const double _kCompactVideoAspect = 16 / 9;

  /// 当前是否窄屏（手机竖屏布局）。
  ///
  /// 用 600 作为分界（Material 规范里 compact / medium 的界线），
  /// 和首页那套判断保持一致。
  ///
  /// 【为什么不接 BuildContext】这个判断在很多辅助方法里要用
  /// （_buildVideoBottomToolbar、_buildBottomActionItem 等），
  /// 而它们本身没有 context 参数 —— 写成带参函数就会到处报
  /// Undefined name 'context'（这个坑已经踩过两次了）。
  /// 改成从 FlutterView 取尺寸：结果等价于 MediaQuery.sizeOf(context).width，
  /// 但任何地方都能调，不用为了一个布尔值把 context 层层往下传。
  ///
  /// 【注意：它只表示「布局该用哪种」，不代表「是不是手机」】
  /// 手机横屏全屏时宽度会超过 600（720×1600 的机器转横屏就是 1600×720，
  /// 逻辑宽 800），这时它返回 false，会走桌面布局分支 —— 这是对的，
  /// 因为横屏确实该按宽布局。但要判断「是不是移动端」，必须用 [isMobilePlatform]。
  static bool get _isCompactWidth {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return false; // 拿不到视图时按桌面处理，布局不会崩
    return view.physicalSize.width / view.devicePixelRatio < 600;
  }

  /// 是否是移动平台（Android / iOS）。
  ///
  /// 和 [_isCompactWidth] 的区别很关键：
  ///   * _isCompactWidth 看的是**当前屏幕宽度**，横屏就变 false；
  ///   * isMobilePlatform 看的是**运行平台**，横竖屏都不变。
  /// 「适配窗口」按钮该按后者判断 —— 它是桌面专属功能，
  /// 手机上不论竖屏横屏都没有意义。用前者会导致横屏全屏时按钮又冒出来。
  static bool get isMobilePlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// 手机端视频区的位置占位。
  ///
  /// 这里只负责「算出 16:9 的高度并把 videoArea 塞进去」，
  /// 注意 key 必须挂在 videoArea 上（而不是外层），
  /// 这样它和其它布局分支之间才能被识别为同一个元素。
  Widget _buildCompactVideoSlot(Widget videoArea) {
    return AspectRatio(
      aspectRatio: _kCompactVideoAspect,
      child: KeyedSubtree(key: _videoAreaKey, child: videoArea),
    );
  }

  /// 手机端主体：上视频（占位）+ 下信息/弹幕
  Widget _buildCompactBody(LiveRoomInfo info) {
    return Column(
      children: [
        // 视频占位：与上面 Positioned 里的视频区同高（16:9）。
        // 用 LayoutBuilder 拿宽度算高度，保证和视频区严丝合缝。
        LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(height: constraints.maxWidth / _kCompactVideoAspect, width: constraints.maxWidth);
          },
        ),
        // 视频下方操作栏（关注/刷新等）
        _buildVideoBottomToolbar(),
        // 剩下全部给主播信息 + 弹幕
        Expanded(child: _buildRightSidebar(info, fillWidth: true)),
      ],
    );
  }

  /// 桌面端主体：左（视频占位 + 操作栏）右（侧栏）
  Widget _buildWideBody(LiveRoomInfo info) {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              // 这里只放一块占位，真正的视频区在外层的 Positioned 里
              const Expanded(child: SizedBox.expand()),
              _buildVideoBottomToolbar(),
            ],
          ),
        ),
        _buildRightSidebar(info),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {

    // 【不要在这里套 Focus/CallbackShortcuts】之前用
    //   CallbackShortcuts(... child: Focus(autofocus: true, child: Scaffold))
    // 把整个页面包了一层，结果进房间后一直停在「正在连接直播间…」：
    // 页面根节点抢焦点会把 build/布局拖进异常状态，起播流程的后续日志一条都不打。
    //
    // Esc 退出全屏改用 _buildVideoPlayerArea 里局部生效的快捷键实现，
    // 作用域只在视频区，不影响页面主体（详见那里的说明）。
    return _buildScaffold(context);
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      // 避开状态栏和挖孔（前置摄像头）：顶部导航栏的返回按钮、
      // 视频区上方的弹幕层都需要落在安全区内，否则手机上会被遮挡。
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          // 全屏观看时不要再留安全区 —— 视频本来就该铺满，
          // 系统会隐藏状态栏，这时留白反而出现一圈难看的边框。
          final fs = controller.isFullscreen;
          return SafeArea(
            top: !fs,
            bottom: !fs,
            left: true,
            right: true,
            child: _buildBody(context),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      // 先一次性读出三个状态，避免同一个 build 里读多次可能读到不同值
      final loading = controller.isLoading;
      final info = controller.roomInfo;
      final err = controller.loadError;

      // 【显式订阅屏幕尺寸】
      // 下面的 compact 判定用 _isCompactWidth（读的是 FlutterView 的物理尺寸），
      // 但 ListenableBuilder 只订阅 controller 状态，屏幕旋转**不会**触发它重建 ——
      // 于是安卓端退出全屏转回竖屏后，布局还按横屏宽度算，
      // 表现就是「视频区缩在左侧、没恢复上下结构」。
      // 这里读一次 MediaQuery.sizeOf，让 ListenableBuilder 对尺寸变化建立依赖，
      // 旋转时一定会重建一次，compact 随之重算。
      MediaQuery.sizeOf(context);

      // 1. 加载中：只要**还没拿到直播间信息**就显示加载页（既没数据也没错误，也算加载中，
      //    避免首帧误判成错误页而闪一下）。
      //
      //    【关键时序修复】这里绝对不要再带上 `loading` 条件。
      //    roomInfo 在起播之前就已赋值（controller 拿到详情立即写入，然后才 open），
      //    而 isLoading 会一直保持 true 到 player.open 结束。如果页面在 isLoading 期间
      //    仍被拦在加载分支，视频区（以及 Video/VideoController/渲染上下文）就永远
      //    晚于 mpv 的 vo 初始化 —— 斗鱼 FLV 秒级就绪，必然抢跑并黑屏：
      //      [mpv][fatal][vo/libmpv] No render context set. → Video: no video
      //    放宽成"有 info 就渲染"，视频区就能在 open 之前完成布局。
      if (info == null && (loading || err == null)) {
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.blueAccent),
              SizedBox(height: 16),
              Text("正在连接直播间...", style: TextStyle(color: Colors.black54)),
            ],
          ),
        );
      }

      // 2. 数据异常兜底：此时必然是 err != null（上面的分支已排除双空）
      //    注意这里只是**弹窗背后的兜底画面**：获取失败时 controller 会弹小窗，
      //    用户点「知道了」后自动退回上一页。在用户点掉弹窗之前，本页仍然要在，
      //    所以保留这块内容 + 返回箭头（防止弹窗因故没能弹出时用户被困住）。
      if (info == null) {
        return Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: IconButton(icon: const Icon(Icons.arrow_back, size: 20), tooltip: '返回', onPressed: _handleBack),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    err ?? '直播间信息获取失败',
                    style: const TextStyle(color: Colors.black87),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: controller.reload, child: const Text('重试')),
                ],
              ),
            ),
          ],
        );
      }

      // 3. 数据准备完毕，渲染主界面
      //
      // 【未开播 / 被封禁不再走这里】这两种情况现在由 controller 弹小窗提示后
      // 自动退回上一页（见 _abortWithDialog），根本不会停留在播放页上。
      // 所以这里不再判断 roomShowStatus、也不再渲染中性状态面板。
      final videoArea = _buildVideoPlayerArea(context, controller, info);

      // 全屏 / 适配窗口：两者都是让视频画面铺满整个 App 窗口，
      // 所以顶栏、右侧弹幕栏、视频下方操作栏全部不渲染。
      // 区别只在窗口本身：全屏会把窗口也切成全屏，适配窗口不动窗口。
      //
      // 【必须用 Stack + Positioned 而不是两个 return 不同结构】
      // 曾经的写法是：
      //   if (全屏) return ColoredBox(child: videoArea);
      //   return Column(顶栏, Expanded(Row(videoArea, 侧栏)));
      // 返回的 widget 子树结构完全不同，Flutter 会**销毁重建** videoArea，
      // 也就是把 Video 从树上摘下来再装回去。VideoController 是复用的没错，
      // 但原生纹理随 widget 卸载/重挂会出现「画面卡在最后一帧」：
      // 实测进入全屏时偶尔卡住，退出再进就正常（第二次重建时恰好没踩到）。
      // 现在视频区永远是同一个 widget（同一位置、同一 key），
      // 全屏切换只改变它被分配到的矩形区域，Video 本身不会被重建。
      final fullscreen = controller.isFullscreen || controller.isFitWindow;

      // 【窄屏判定】手机竖屏（< 600 逻辑像素）走上下布局：
      //   上：视频（16:9 定比，不占满剩余空间，避免拉伸变形）
      //   下：主播信息 + 弹幕列表
      // 桌面/平板保持左右布局不变。
      final compact = _isCompactWidth;

      return Stack(
        children: [
          // 底层：非全屏时的常规界面（全屏时保留但不显示视频占位）
          Positioned.fill(
            child: Offstage(
              offstage: fullscreen,
              child: Column(
                children: [
                  _buildTopNavigationBar(info),
                  Expanded(child: compact ? _buildCompactBody(info) : _buildWideBody(info)),
                ],
              ),
            ),
          ),

          // 视频区：同一实例，只换它被分配到的矩形。
          //
          // 【这里是全屏卡顿的另一半原因，必须只有一个 Positioned】
          // 之前是按状态写 if/else 三个分支，每个分支的 Positioned 参数完全不同
          // （top/bottom/left/right 的组合 vs fill）。Flutter 的 Stack 子节点
          // 复用靠「位置 + 类型 + key」，三套分支等于三个不同的节点，
          // 每次切换都要销毁重建整棵子树 —— 即使 Video 本身不换 key 也救不回来。
          //
          // 现在统一成一个 Positioned，用几个变量表达三种布局：
          //   全屏        → 四边都贴边（等价 Positioned.fill）
          //   桌面常规    → 扣掉顶栏、底部操作栏、右侧侧栏
          //   手机常规    → 顶栏下方按 16:9 定高（右侧贴边，高度由 _buildCompactVideoSlot 给）
          // 参数变了只会触发 layout，不会重建元素。
          Positioned(
            top: fullscreen ? 0 : _kTopBarHeight,
            bottom: fullscreen ? 0 : (compact ? null : _kBottomToolbarHeight),
            left: 0,
            right: fullscreen ? 0 : (compact ? 0 : _kSidebarWidth),
            child: KeyedSubtree(key: _videoAreaKey, child: compact && !fullscreen ? _buildCompactVideoSlot(videoArea) : videoArea),
          ),
        ],
      );
    });
  }

  // ================= 模块一：顶部导航栏 =================
  Widget _buildTopNavigationBar(LiveRoomInfo roomInfo) {
    return Container(
      // 用常量：外层 Positioned 的 top 也是这个值，改一处就够
      height: _kTopBarHeight,
      // 白底 + 底部分隔线：原来这里是 0xFF1E1E1E 黑底，而标题文字是默认黑色，
      // 黑字压黑底等于看不见，所以整条一起改白
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back, size: 20), tooltip: '返回', onPressed: _handleBack),
          const SizedBox(width: 8),

          // 动态平台图标
          _buildPlatformIcon(roomInfo.live_site),

          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${roomInfo.room_name ?? "未知直播间"} - ${roomInfo.owner_name ?? "未知主播"}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  /// 返回上一界面。
  /// 直播间页是被 push 进来的，正常情况下 pop 即可；
  /// 但深链接直接起播时它是栈底，没有可回退的页面，
  /// 这种情况下退回首页，避免点了箭头没反应。
  ///
  /// 【从 Get.back 换成 GoRouter】路由已交给 go_router，GetX 不再持有 Navigator。
  void _handleBack() {
    final router = AppRouter.router;
    if (router.canPop()) {
      router.pop();
      return;
    }
    router.go(RoutePath.p_home);
  }

  // 平台图标：直接复用 LiveSites 元数据，避免图标路径散落在多个文件里
  Widget _buildPlatformIcon(LIVE_SITE_E? liveSite, {double size = 20}) {
    if (liveSite == null) {
      return Icon(Icons.live_tv, color: Colors.blueAccent, size: size);
    }

    return Image.asset(
      LiveSites.of(liveSite).iconAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      // 如果图片找不到，显示默认Icon，防止报错
      errorBuilder: (context, error, stackTrace) {
        return Icon(Icons.live_tv, color: Colors.blueAccent, size: size);
      },
    );
  }

  // ================= 模块二：视频播放区 =================

  Widget _buildVideoPlayerArea(BuildContext context, LiveStreamController controller, LiveRoomInfo roomInfo) {
    // 【Esc 退出全屏：焦点只放在视频区，不放到页面根】
    //
    // 为什么不给整个页面套 CallbackShortcuts/Focus（踩过坑）：
    // 页面根节点抢焦点会把 build/布局拖进异常状态，
    // 进房间后一直停在「正在连接直播间…」，起播流程的日志一条都不打。
    //
    // 这里的做法：一个 autofocus 的 Focus 包住视频区，
    // 快捷键只在这个子树内生效 —— 用户在设置/弹幕面板里按 Esc 不会被抢走。
    // 离开直播间页面时 Focus 随之销毁，不影响别的地方。
    return CallbackShortcuts(
      bindings: {
        // Esc：退出全屏 / 自适应模式，非全屏且非自适应时按了什么都不做
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (controller.isFullscreen) {
            controller.toggleFullscreen();
          } else if (controller.isFitWindow) {
            controller.toggleFitWindow();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          onHover: (event) => controller.setShowControls(true),
          onExit: (event) => controller.setShowControls(false),
          // 单击：切换控制栏显隐（手机端主要靠这个，桌面端也兼容）。
          // 双击：全屏时退出全屏。
          //
          // 【为什么不用 onTap + onDoubleTap】Flutter 同时注册这两个会延迟 ~300ms
          // 判断是否双击，单击切换控制栏就有明显延迟感。
          // 改用 onTapUp + 手动双击检测：第一次 tap 立即切控制栏，
          // 300ms 内第二次 tap 触发退出全屏（控制栏状态由 toggleControls 再切一次）。
          //
          // 【只在全屏时响应双击退出】非全屏下双击视频没有明确语义，
          // 硬要做成「进入全屏」会和「双击暂停」这类常见习惯冲突，
          // 进入仍然走右下角按钮。
          //
          // 用 GestureDetector 包住整块视频区：弹幕层和控制栏是 Stack 的
          // 上层子节点，它们自己的点击会先被消费，不会误触这里。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (_) => controller.onVideoTap(),
            child: _buildVideoStack(context, controller),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoStack(BuildContext context, LiveStreamController controller) {
    // 用 LayoutBuilder 包住整个视频栈：全屏 / 适配窗口 / 窗口缩放导致视频区尺寸
    // 变化时，这里会重新 build，里面所有依赖尺寸的子节点（弹幕层、
    // 视频区的布局回调）都跟着拿到最新约束。
    // 不能拿 MediaQuery 的窗口尺寸代替：视频区还要扣掉顶栏、底部操作栏和侧栏，
    // 而且全屏时整个窗口都被视频占满，两者差距很大。
    return LayoutBuilder(builder: (context, constraints) => _buildVideoStackBody(context, controller));
  }

  Widget _buildVideoStackBody(BuildContext context, LiveStreamController controller) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 【修复白屏根因】Stack 只有在存在“非定位子节点”时才会按父级最大尺寸撑开。
        // 本 Stack 的子节点原本全是 Positioned / SizedBox.shrink，没有任何东西提供宽度，
        // 于是 RenderStack 从 constraints.minWidth 起算，宽度塌缩成 0
        // （外层 Column 未设 crossAxisAlignment: stretch，宽度约束是松的 0..maxWidth）。
        // 结果 Positioned.fill 里的 Video 拿到 0x593，纹理被释放 ⇒ 有声音、画面全白，
        // 且 mpv 报 “mpv_render_context_render() not being called or stuck.”。
        // 用一个空白的非定位子节点 + StackFit.expand 把 Stack 撑满父级即可根治。
        const SizedBox.expand(),

        // 1. 底层：media_kit 视频画面
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 【关键时序修复】通知 controller「渲染上下文已就绪」，让它在起播前等一等。
                // 注意这一行会在布局阶段执行，此时 Video widget 还没 build、
                // 原生渲染上下文也还没注册完成，所以要推到帧末（addPostFrameCallback）。
                // controller 侧自带幂等，这里只用 getter 过滤掉重复入队。
                if (!controller.videoSurfaceLaidOutNotified) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    controller.notifyVideoSurfaceLaidOut();
                  });
                }

                // 【key 的选法决定了全屏卡不卡】
                //
                // 曾经的写法是 `key: ValueKey<bool>(全屏状态)`，想让全屏切换时
                // Video 重新挂载、纹理按新约束重建。实测这是个坑：
                // 全屏状态在一次切换过程中会连续变好几次（窗口 resize 引发的
                // 重建、布局状态更新……），每次都销毁重建 VideoState
                // （连同 stream 订阅、Wakelock、纹理关联一起重来），
                // 频繁进出时重建必然抢在上一帧渲染完成之前，画面直接卡死。
                //
                // 但完全不换 key 也不行：Flutter 只重新布局视频区，
                // 不会重新提交原生纹理，画面停在最后一帧（声音照常）。
                //
                // 现在的做法：key 只跟 controller.textureRefreshTick 走。
                // 那个值只在 toggleFullscreen 完成、尺寸稳定之后自增**一次**，
                // 于是重建恰好发生在「该刷新纹理」的时刻，而不是 resize 过程中。
                //
                // fit 一律 contain：全屏只是让**区域**变大，不是放大画面本身，
                // 所以任何时候都等比缩放放得下，留必要的黑边，不裁切。
                return ListenableBuilder(listenable: controller, builder: (context, _) {
                  // 订阅 controller：textureRefreshTick 变化时重建以强制 Texture 重新提交，
                  // isFullscreen / isFitWindow 变化时重建以供后续按全屏切 fit。
                  // ListenableBuilder 订阅整个 controller，这些字段任一变化都会触发重建。
                  final tick = controller.textureRefreshTick;

                  return Video(
                    // 【key 只跟 tick 走，不跟全屏状态走】
                    //
                    // 全屏状态变化本身**不能**进 key：那样每次切换都会销毁重建
                    // VideoState，正是之前卡死的原因。
                    // 但全屏切换后 Flutter 只重新布局、不重新提交原生纹理，
                    // 画面会停在最后一帧（声音正常）—— 所以由 controller 在
                    // 尺寸稳定后自增 tick，这里跟着重建一次，把纹理重新绑上去。
                    //
                    // 两者区别：全屏状态变化会连续触发多次重建（窗口 resize
                    // 过程中反复变化），而 tick 只在切换**完成后**自增一次。
                    key: ValueKey<int>(tick),
                    controller: controller.videoController,
                    fit: BoxFit.contain,
                    // 关闭 media_kit 自带控制栏，统一用页面自己的底部控制栏
                    controls: (state) => const SizedBox.shrink(),
                    // 【关掉 media_kit 自带 Wakelock】它默认开启，每次 VideoState 重建
                    // 都会 disable + enable 各发一次平台通道调用；
                    // 而 tick 变化本来就会重建一次，等于每次全屏切换多两次往返，
                    // 手感上就是「点完要等一下才动」。
                    // 屏幕常亮改由 LiveStreamController 在全屏时通过 WakelockPlus 统一控制，
                    // 不依赖 Video widget 的生命周期，避免重建时的引用计数抖动。
                    wakelock: false,
                  );
                });
              },
            ),
          ),
        ),

        // 2. 弹幕滚动层：横向飞行，从右往左
        //
        // 【全屏 / 非全屏都显示】早期只在全屏时叠，是因为非全屏画面小、
        // 容易被糊住。现在区域高度、字号、同屏条数都能调，用户自己就能
        // 把干扰压到可接受的程度，所以默认都给显示，靠「弹幕」按钮一键关掉。
        //
        // 【区域高度 = 视频区当前尺寸 × 比例】
        // 外层用 LayoutBuilder 把它铺满整个视频区，内层再按比例取高度：
        // 这样全屏 / 适配窗口 / 窗口缩放导致视频区变化时，高度**每次都重算**，
        // 而不是依赖某个缓存的数字。
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return ListenableBuilder(listenable: controller, builder: (context, _) {
                if (!controller.isDanmakuOn) return const SizedBox.shrink();

                // 每次都读最新的视频区高度（不是 build 时捕获的旧值）
                final areaHeight = constraints.maxHeight * controller.danmakuAreaRatio;

                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: areaHeight,
                    child: RepaintBoundary(
                      // 弹幕每帧都在动，用 RepaintBoundary 把它和视频/控制栏的
                      // 重绘隔离开，避免整块播放区跟着标脏。
                      child: DanmakuOverlay(
                        // danmakuList 是 controller 暴露的 List 引用，
                        // controller 在新弹幕到达时会 notifyListeners 触发重建。
                        messages: controller.danmakuList,
                        // 字号在控制器里是 int（面板按整数调节），这里转成 double 给渲染用
                        fontSize: controller.danmakuFontSize.toDouble(),
                        maxOnScreen: controller.danmakuMaxOnScreen,
                        // 飞行时长由 controller 控制（设置面板可调，越大越慢）
                        flightDuration: Duration(seconds: controller.danmakuFlightSeconds),
                        // 【不要按尺寸给 key】那会让每次全屏切换都重建组件状态，
                        // 正在飞的弹幕全部清空 —— 正是「一切全屏弹幕就没了」的成因。
                        // 尺寸变化由组件内部的 LayoutBuilder 感知，它会把越界的
                        // 轨道重新分配，弹幕不中断。
                      ),
                    ),
                  ),
                );
              });
            },
          ),
        ),

        // 3. 缓冲中 / 播放出错提示
        ListenableBuilder(listenable: controller, builder: (context, _) {
          final buffering = controller.isBuffering;
          final playing = controller.isPlaying;
          // 【画面在播就不显示错误浮层】mpv 的错误输出存在滞后，
          // 上一次 open / 旧解码器的报错可能在新流已经正常播放后才送达，
          // 表现为「画面明明在播，屏幕中间一直挂着 could not open codec」。
          // controller 侧已经过滤了一层，这里再兜一层：播放状态是最高优先级，
          // 只要在播，就不要用浮层盖住画面。
          final playError = playing ? null : controller.playError;
          if (!buffering && playError == null) return const SizedBox.shrink();

          return Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (buffering) const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 3)),
                    if (playError != null) ...[
                      const Icon(Icons.error_outline, color: Colors.white70, size: 36),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          playError,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }),

        // 4. 底部控制栏 (ListenableBuilder 监听)
        ListenableBuilder(listenable: controller, builder: (context, _) {
          if (!controller.showControls) return const SizedBox.shrink();

          return Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Colors.transparent, Colors.black.withOpacity(0.8)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
              ),
              child: _buildControlBarContent(context, controller),
            ),
          );
        }),

        // 5. 顶部悬浮工具栏（仅全屏 / 自适应模式显示）
        //
        // 全屏或自适应窗口时，是铺满整个 App 窗口的纯视频画面，
        // 原本的顶部导航栏（_buildTopNavigationBar）被 Offstage 隐藏了，
        // 于是没有任何「返回」入口 —— 用户要么按 Esc、要么只能依赖系统返回键。
        // 这里补一条半透明工具栏：最左侧一个返回箭头，点击退出直播间回到上一页。
        //
        // 【随 showControls 显隐 + 自动隐藏】复用底部控制栏那套状态：
        // 点视频区亮出、4 秒无操作自动收起、鼠标移出视频区立即收起（桌面），
        // 和底部栏的显隐逻辑完全同步，观感一致。
        ListenableBuilder(listenable: controller, builder: (context, _) {
          // 只在铺满状态（全屏 / 自适应）下才显示；普通模式已有常规顶栏
          if (!(controller.isFullscreen || controller.isFitWindow)) {
            return const SizedBox.shrink();
          }
          if (!controller.showControls) return const SizedBox.shrink();

          return Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              // 半透明：上面深、下面渐隐到透明，和底部栏上下呼应
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black.withOpacity(0.6), Colors.transparent],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              // 顶部工具栏放在全屏时没有安全区（SafeArea top:false），
              // 手机横屏时可能有刘海/挖孔，用 SafeArea 兜住左侧避免箭头被挡。
              child: SafeArea(
                bottom: false,
                left: true,
                top: true,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 22, color: Colors.white),
                      tooltip: '退出直播间',
                      onPressed: _handleBack,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  /// 视频区底部控制栏的内容。
  ///
  /// 【左右两组分居两端】
  ///   左：播放/暂停、弹幕开关
  ///   右：音量、画质、线路、适配窗口（仅桌面）、全屏
  /// 中间由 spaceBetween 的空白撑开，两组分别贴住控制栏的最左和最右。
  ///
  /// 【桌面和手机都是单行】之前手机上因为「横向音量滑块 + 画质 + 线路 + 全屏」
  /// 一行放不下，被迫拆成两行，结果控制栏明显加高、压到画面上很突兀。
  /// 现在手机端的音量改成竖向浮层（点图标才展开，见 _buildVolumeControl），
  /// 控制栏里只剩一个 48 宽的图标，其余控件就排得下一行了。
  ///
  /// 仍然保留横向滚动：极窄机型上万一还是超出，能滑出来总比溢出条纹好。
  /// 但正常手机宽度下不需要滑，全屏按钮就在第一屏。
  ///
  /// 【宽度必须来自 LayoutBuilder】见下面 builder 里的说明：
  /// 用屏幕宽减常数去猜可用宽度，Row 撑不满，两组都会缩成一坨。
  Widget _buildControlBarContent(BuildContext context, LiveStreamController controller) {
    // 【必须用 LayoutBuilder 量真实宽度，不能用 MediaQuery 屏幕宽】
    // 之前是 `minWidth: MediaQuery.sizeOf(context).width - 32`，那个数字是猜的：
    // 桌面上视频区右侧还要让出 320 的侧栏，实际可用宽度比屏幕窄得多，
    // 于是 Row 比容器窄、又按 end 对齐 —— 表现就是「暂停、弹幕开关这些全挤在右边」。
    // 现在拿布局给的真实 maxWidth，内容比容器窄时 Row 就正好撑满，
    // 两端的对齐才有意义。
    return LayoutBuilder(
      builder: (context, constraints) {
        // 约束无限（父级把横向约束放开了）时给个 0，
        // 让 ConstrainedBox 退化成只由内容决定宽度，不要让 minWidth 变成 Infinity。
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            // 内容比容器窄时，让 Row 撑满可用宽度，好让 mainAxisAlignment 生效
            constraints: BoxConstraints(minWidth: available),
            child: Row(
              // 【两端分居】左边是常用操作（播放/暂停；全屏时还有弹幕开关），
              // 右边是配置类（音量、画质、线路、适配窗口、全屏）。
              //
              // 用 spaceBetween：子节点之间均分剩余空白，
              // 于是左组贴最左、右组贴最右，中间那个 16 宽的空隙只是保底间距
              // （容器太窄、没有剩余空白时，两组不至于完全粘在一起）。
              // 之前一律 end，所有控件都贴在右边，左侧一大片空白。
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // ---------- 左组：播放 / 弹幕 ----------
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListenableBuilder(listenable: controller, builder: (context, _) => IconButton(icon: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow), onPressed: controller.togglePlay)),

                    // 弹幕设置：点开后在按钮正上方弹出面板，
                    // 里面是「开关 / 显示范围 / 字号 / 同屏条数」四项。
                    //
                    // 【全屏和非非全屏都显示】弹幕层现在两种状态都会渲染，
                    // 所以这个按钮不再按 isFullscreen 隐藏。
                    Builder(
                      builder: (buttonContext) => IconButton(
                        icon: Icon(controller.isDanmakuOn ? Icons.subtitles : Icons.subtitles_off),
                        tooltip: '弹幕设置',
                        onPressed: () => _showDanmakuSettings(buttonContext, controller),
                      ),
                    ),
                  ],
                ),

                // ---------- 中间弹性空白：把左右两组分别顶到两端 ----------
                const SizedBox(width: 16),

                // ---------- 右组：音量 / 画质 / 线路 / 适配窗口 / 全屏 ----------
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ===== 音量：桌面横向滑块，手机竖向浮层 =====
                    _buildVolumeControl(context, controller),

                    const SizedBox(width: 8),

                    // ===== 画质切换 =====
                    _buildQualityButton(controller),

                    // ===== 线路切换（同一画质下的多条流） =====
                    _buildLineButton(controller),

                    // ===== 适配窗口：把视频画面铺满整个 App 窗口（不动窗口本身） =====
                    //
                    // 【移动端一律不显示】「适配窗口」是桌面概念：桌面可以既有窗口全屏、
                    // 又有「窗口内铺满」这种中间态。手机上屏幕就那么大，
                    // 想大就进全屏，这个按钮没有实际用途。
                    //
                    // 【为什么用 isMobilePlatform 而不是 _isCompactWidth】
                    // 后者看的是当前屏幕宽度，手机横屏全屏时宽度会超过 600 变 false，
                    // 按钮就会重新冒出来。按运行平台判断才是「所有时候都不显示」。
                    if (!isMobilePlatform)
                      ListenableBuilder(listenable: controller, builder: (context, _) => IconButton(
                          icon: Icon(controller.isFitWindow ? Icons.zoom_in_map : Icons.fit_screen),
                          tooltip: controller.isFitWindow ? '退出适配窗口' : '适配窗口',
                          onPressed: controller.toggleFitWindow,
                        ),
                      ),
                    // 图标要跟着全屏状态切换，单独包一层 ListenableBuilder 订阅 isFullscreen
                    ListenableBuilder(listenable: controller, builder: (context, _) => IconButton(
                        icon: Icon(controller.isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                        tooltip: controller.isFullscreen ? '退出全屏' : '全屏',
                        onPressed: controller.toggleFullscreen,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 音量控制。
  ///
  /// 桌面：图标 + 横向滑块 + 数值，一行排开（保持原样）。
  /// 手机：只有图标；点图标弹出一个**竖向浮层**调音量。
  ///
  /// 为什么手机要竖起来：横向滑块要占 170 多像素（图标 + 滑块 + 数值），
  /// 加上画质/线路/全屏，控制栏一行根本放不下，只能拆成两行 ——
  /// 而两行会明显加高控制栏，压到画面上很突兀。
  /// 改成竖向浮层后，控制栏里只剩一个 48 宽的图标，其余控件就排得下一行了。
  Widget _buildVolumeControl(BuildContext context, LiveStreamController controller) {
    final compact = _isCompactWidth;

    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final volume = controller.volume;
      final icon = volume <= 0
          ? Icons.volume_off
          : volume < 50
          ? Icons.volume_down
          : Icons.volume_up;

      if (compact) {
        // 手机：图标点击弹竖向音量条
        return Builder(
          builder: (btnContext) =>
              IconButton(iconSize: 20, icon: Icon(icon), tooltip: '音量 ${volume.round()}', onPressed: () => _showVolumePopup(btnContext, controller)),
        );
      }

      // 桌面：保持原来的横向排布
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(iconSize: 20, icon: Icon(icon), tooltip: volume <= 0 ? '取消静音' : '静音', onPressed: controller.toggleMute),
          SizedBox(
            width: 100,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(min: 0, max: 100, value: volume.clamp(0.0, 100.0), onChanged: controller.setVolume),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '${volume.round()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      );
    });
  }

  /// 弹幕设置面板：在弹幕按钮**正上方**弹出。
  ///
  /// 【为什么不用 showMenu】showMenu 的内容会被包进一个 Scrollable，
  /// 即使内容装得下也会出现滚动条和滚动手势，观感很脏。
  /// 这里面板尺寸完全由内部配置项决定、写死在 [_kDanmakuPanelWidth] /
  /// [_kDanmakuPanelHeight]，不需要滚动，所以直接用 OverlayEntry 自己摆。
  Future<void> _showDanmakuSettings(BuildContext buttonContext, LiveStreamController controller) async {
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(buttonContext, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize || overlayBox == null) return;

    // 手机端内部控件整体缩小（桌面保持原尺寸），面板高度按 scale 折算。
    // 【宽度不跟着缩太多】缩太窄滑块不好点；只保证不超屏宽（留边）。
    final scale = _panelScale;
    final panelWidth = _kDanmakuPanelWidth > overlayBox.size.width * 0.9
        ? overlayBox.size.width * 0.9
        : _kDanmakuPanelWidth;
    final panelHeight = _kDanmakuPanelHeight * scale;

    final size = buttonBox.size;
    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox);

    var left = topLeft.dx + (size.width - panelWidth) / 2;
    if (left < 0) left = 0;
    if (left + panelWidth > overlayBox.size.width) {
      left = overlayBox.size.width - panelWidth;
    }

    // 面板底边贴着按钮顶边；上方放不下就翻到按钮下方
    var top = topLeft.dy - panelHeight - 6;
    if (top < 0) top = topLeft.dy + size.height + 6;
    if (top + panelHeight > overlayBox.size.height) {
      top = overlayBox.size.height - panelHeight;
    }
    if (top < 0) top = 0;

    final entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点面板外任意位置关闭
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: () => _closeDanmakuPanel()),
          ),
          Positioned(left: left, top: top, width: panelWidth, height: panelHeight, child: _buildDanmakuSettingsBody(controller, scale: scale)),
        ],
      ),
    );

    setDanmakuPanelEntry(entry);
    // 面板打开期间锁住控制栏，否则鼠标移出去就被自动收起了
    controller.setQualityMenuOpen(true);
    overlay.insert(entry);
  }

  /// 关闭弹幕设置面板（幂等）
  void _closeDanmakuPanel() {
    final entry = danmakuPanelEntryRef();
    if (entry == null) return;
    setDanmakuPanelEntry(null);
    entry.remove();
    controller.setQualityMenuOpen(false);
  }

  /// 弹幕设置面板的基准尺寸（桌面端）。
  /// 4 个滑块行 × 78 + 开关 36 + Divider 1 + 上下 padding 22 ≈ 371，取 380 留余量。
  /// 手机端会按 [_panelScale] 整体缩放（见 [_showDanmakuSettings]）。
  static const double _kDanmakuPanelWidth = 268;
  static const double _kDanmakuPanelHeight = 380;

  /// 面板整体缩放因子：手机窄屏缩到 0.8，避免控件偏大、面板压满半个屏幕。
  /// 桌面保持 1.0 原尺寸。
  static double get _panelScale => _isCompactWidth ? 0.8 : 1.0;

  /// 弹幕设置面板的内容。传入 [scale] 让内部所有尺寸/字号跟着缩放。
  Widget _buildDanmakuSettingsBody(LiveStreamController controller, {double scale = 1.0}) {
    return Material(
      // 黑底半透明：压在视频画面上，不透出一点底就像贴了块板子；
      // 0.82 足够压住底下的亮部，又不至于完全看不见画面
      color: Colors.black.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(listenable: controller, builder: (context, _) {
        final on = controller.isDanmakuOn;
        // 关掉弹幕后，其余三项没有意义，统一置灰
        final dim = on ? Colors.white : Colors.white38;

        return Padding(
          padding: EdgeInsets.fromLTRB(14 * scale, 10 * scale, 14 * scale, 12 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- 开关 ----------
              SizedBox(
                height: 36 * scale,
                child: Row(
                  children: [
                    Expanded(
                      child: Text('滚动弹幕', style: TextStyle(fontSize: 13 * scale, color: dim)),
                    ),
                    SizedBox(
                      height: 28 * scale,
                      child: Transform.scale(
                        scale: _isCompactWidth ? 0.66 : 0.75,
                        child: Switch(value: on, onChanged: (_) => controller.toggleDanmaku(), activeTrackColor: const Color(0xFF3D7EFF)),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, color: Colors.white24),

              // ---------- 显示范围（离散三档：1/4、1/3、1/2） ----------
              _buildDanmakuSliderRow(
                label: '显示范围',
                valueText: LiveStreamController.danmakuAreaLabel(controller.danmakuAreaRatio),
                enabled: on,
                scale: scale,
                // 三档等分：滑块停在 0、1、2 三个位置上
                min: 0,
                max: (LiveStreamController.kDanmakuAreaOptions.length - 1).toDouble(),
                divisions: LiveStreamController.kDanmakuAreaOptions.length - 1,
                value: LiveStreamController.kDanmakuAreaOptions
                    .indexWhere((r) => (r - controller.danmakuAreaRatio).abs() < 0.01)
                    .clamp(0, LiveStreamController.kDanmakuAreaOptions.length - 1)
                    .toDouble(),
                ticks: [for (final r in LiveStreamController.kDanmakuAreaOptions) LiveStreamController.danmakuAreaLabel(r)],
                onChanged: (v) {
                  final idx = v.round().clamp(0, LiveStreamController.kDanmakuAreaOptions.length - 1);
                  controller.danmakuAreaRatio = LiveStreamController.kDanmakuAreaOptions[idx];
                },
              ),

              // ---------- 字体大小（16~34 任意整数） ----------
              _buildDanmakuSliderRow(
                label: '字体大小',
                valueText: controller.danmakuFontSize.toString(),
                enabled: on,
                scale: scale,
                min: LiveStreamController.kDanmakuFontSizeMin.toDouble(),
                max: LiveStreamController.kDanmakuFontSizeMax.toDouble(),
                // divisions = 区间长度，保证滑块只能停在整数上
                divisions: LiveStreamController.kDanmakuFontSizeMax - LiveStreamController.kDanmakuFontSizeMin,
                value: controller.danmakuFontSize.toDouble(),
                ticks: ['${LiveStreamController.kDanmakuFontSizeMin}', '${LiveStreamController.kDanmakuFontSizeMax}'],
                onChanged: (v) {
                  controller.danmakuFontSize = v.round().clamp(LiveStreamController.kDanmakuFontSizeMin, LiveStreamController.kDanmakuFontSizeMax);
                },
              ),

              // ---------- 同屏条数（20~50 任意整数） ----------
              _buildDanmakuSliderRow(
                label: '同屏条数',
                valueText: controller.danmakuMaxOnScreen.toString(),
                enabled: on,
                scale: scale,
                min: LiveStreamController.kDanmakuMaxOnScreenMin.toDouble(),
                max: LiveStreamController.kDanmakuMaxOnScreenMax.toDouble(),
                divisions: LiveStreamController.kDanmakuMaxOnScreenMax - LiveStreamController.kDanmakuMaxOnScreenMin,
                value: controller.danmakuMaxOnScreen.toDouble(),
                ticks: ['${LiveStreamController.kDanmakuMaxOnScreenMin}', '${LiveStreamController.kDanmakuMaxOnScreenMax}'],
                onChanged: (v) {
                  controller.danmakuMaxOnScreen = v.round().clamp(
                    LiveStreamController.kDanmakuMaxOnScreenMin,
                    LiveStreamController.kDanmakuMaxOnScreenMax,
                  );
                },
              ),

              // ---------- 滚动速度（8~24 秒，越大越慢） ----------
              _buildDanmakuSliderRow(
                label: '滚动速度',
                // 显示秒数并标注快慢方向：数值大 = 慢
                valueText: '${controller.danmakuFlightSeconds}s',
                enabled: on,
                scale: scale,
                min: LiveStreamController.kDanmakuFlightSecondsMin.toDouble(),
                max: LiveStreamController.kDanmakuFlightSecondsMax.toDouble(),
                divisions: LiveStreamController.kDanmakuFlightSecondsMax - LiveStreamController.kDanmakuFlightSecondsMin,
                value: controller.danmakuFlightSeconds.toDouble(),
                // 左快右慢：左端秒数小（快），右端秒数大（慢）
                ticks: ['快', '慢'],
                onChanged: (v) {
                  controller.danmakuFlightSeconds = v.round().clamp(
                    LiveStreamController.kDanmakuFlightSecondsMin,
                    LiveStreamController.kDanmakuFlightSecondsMax,
                  );
                },
              ),
            ],
          ),
        );
      }),
    );
  }

  /// 一行「标签 + 当前值 + 离散滑块 + 刻度文字」。
  ///
  /// 每行固定高度 78（乘以 [scale]）：标题 20 + 滑块 40 + 刻度 16 + 少量间隙，
  /// 这样面板总高可以精确算出来（见 [_kDanmakuPanelHeight]），不会溢出。
  /// [scale] 让手机端整体缩小（行高、字号、滑块一起缩）。
  Widget _buildDanmakuSliderRow({
    required String label,
    required String valueText,
    required bool enabled,
    required double min,
    required double max,
    required int divisions,
    required double value,
    required List<String> ticks,
    required ValueChanged<double> onChanged,
    double scale = 1.0,
  }) {
    final labelColor = enabled ? Colors.white : Colors.white38;

    return SizedBox(
      height: 78 * scale,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 20 * scale,
            child: Row(
              children: [
                Text(label, style: TextStyle(fontSize: 12 * scale, color: labelColor)),
                const Spacer(),
                Text(
                  valueText,
                  style: TextStyle(fontSize: 12 * scale, color: enabled ? const Color(0xFF8FC0FF) : Colors.white38, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40 * scale,
            child: SliderTheme(
              // 直接构造 SliderThemeData，不基于 SliderTheme.of(context) 复制 ——
              // 这个方法拿不到 context，也正好避免继承页面主题里不合适的高度/颜色。
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: enabled ? const Color(0xFF3D7EFF) : Colors.white24,
                inactiveTrackColor: Colors.white24,
                thumbColor: enabled ? const Color(0xFF3D7EFF) : Colors.white38,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7 * scale),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 14 * scale),
                activeTickMarkColor: Colors.transparent,
                inactiveTickMarkColor: Colors.transparent,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                // 关掉时禁用，避免“关了弹幕还在调参数”的困惑
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
          SizedBox(
            height: 16 * scale,
            // 刻度文字：和滑块两端对齐，让用户知道能选哪些值
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [for (final t in ticks) Text(t, style: TextStyle(fontSize: 10 * scale, color: enabled ? Colors.white54 : Colors.white24))],
            ),
          ),
        ],
      ),
    );
  }

  /// 手机端：在音量图标**正上方**弹出竖向滑块。
  ///
  /// 复用画质/线路那套 showMenu 的定位思路（按按钮实际位置算 RelativeRect），
  /// 只是内容换成一个可拖的竖向 Slider。
  /// 用 showMenu 而不是自己写 OverlayEntry：点击外部关闭、返回键关闭、
  /// 焦点管理等都由框架处理好了，不用重复实现。
  Future<void> _showVolumePopup(BuildContext buttonContext, LiveStreamController controller) async {
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(buttonContext, rootOverlay: true).context.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize || overlay == null) return;

    const popupWidth = 64.0;
    const popupHeight = 200.0;
    const gap = 6.0;

    final size = buttonBox.size;
    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlay);

    // 弹层水平居中于按钮，底边贴在按钮顶边上方
    var left = topLeft.dx + (size.width - popupWidth) / 2;
    // 不允许超出 overlay 左右边界
    if (left < 0) left = 0;
    if (left + popupWidth > overlay.size.width) left = overlay.size.width - popupWidth;

    var bottom = topLeft.dy - gap;
    // 上方放不下就翻到按钮下方（按钮通常在画面底部，正常不会走到这）
    if (bottom - popupHeight < 0) {
      bottom = topLeft.dy + size.height + gap + popupHeight;
    }
    if (bottom > overlay.size.height) bottom = overlay.size.height - gap;

    // 和画质菜单一样，弹层打开期间锁住控制栏，否则鼠标/手指移开就被收掉了
    controller.setQualityMenuOpen(true);
    try {
      await showMenu<void>(
        context: buttonContext,
        position: RelativeRect.fromLTRB(left, bottom - popupHeight, overlay.size.width - left - popupWidth, overlay.size.height - bottom),
        constraints: BoxConstraints.tightFor(width: popupWidth, height: popupHeight),
        color: Colors.white,
        items: [
          PopupMenuItem<void>(
            // 不可点选，只是承载内容；enabled:false 会让它不响应点击、也不高亮
            enabled: false,
            height: popupHeight,
            padding: EdgeInsets.zero,
            child: _buildVolumePopupBody(controller),
          ),
        ],
      );
    } finally {
      controller.setQualityMenuOpen(false);
    }
  }

  /// 竖排音量条的内容：数值 + 竖向滑块 + 静音按钮
  ///
  /// 【为什么每块尺寸都写死】这个内容被塞进 showMenu 的
  /// `BoxConstraints.tightFor(width: 64, height: 200)` 里，约束是紧的。
  /// 而 RotatedBox 会把「宽高约束方向」交换一次 —— 一旦某层是
  /// Expanded/Flexible 这种「依赖父级剩余空间」的组件，
  /// 交换后就会算出矛盾约束，安卓上表现为布局死循环导致进程被杀。
  ///
  /// 所以这里全程用固定高度：Column 不用 Expanded，滑块高度直接给死，
  /// RotatedBox 拿到的永远是确定的数字，不会触发约束推导。
  Widget _buildVolumePopupBody(LiveStreamController controller) {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final volume = controller.volume;

      // 各块高度加总必须 <= popupHeight(200)，否则紧约束下会溢出报错。
      // 16 + 4 + 140 + 4 + 32 = 196，留 4px 余量。
      const textHeight = 16.0;
      const sliderHeight = 140.0;
      const buttonHeight = 32.0;

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: textHeight,
            child: Center(
              child: Text('${volume.round()}', style: const TextStyle(fontSize: 12, color: Colors.black87)),
            ),
          ),
          const SizedBox(height: 4),

          // 竖向滑块：把水平 Slider 旋转 -90°。
          // 旋转后它的「长度」对应父级给的宽度，所以这里用 SizedBox 明确给宽高，
          // 再交给 RotatedBox 交换长短边 —— 全程固定数字，不依赖父级剩余空间。
          SizedBox(
            height: sliderHeight,
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: const Color(0xFF3D7EFF),
                  inactiveTrackColor: const Color(0xFFDDDDDD),
                ),
                child: Slider(min: 0, max: 100, value: volume.clamp(0.0, 100.0), onChanged: controller.setVolume),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // 静音快捷开关：竖条底部顺手放一个
          SizedBox(
            height: buttonHeight,
            child: IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(volume <= 0 ? Icons.volume_off : Icons.volume_up, color: const Color(0xFF666666)),
              onPressed: controller.toggleMute,
            ),
          ),
        ],
      );
    });
  }

  /// 控制栏下拉菜单（画质 / 线路）里每一项的高度。
  ///
  /// 默认的 PopupMenuItem 用的是 kMinInteractiveDimension(48)，一长串列出来非常笨重，
  /// 这里压到 26，让弹框整体和 40 高的控制栏观感接近。
  static const double _kQualityItemHeight = 26;

  /// 下拉弹框与按钮之间留的缝隙（紧贴但不粘边）
  static const double _kQualityMenuGap = 2;

  /// 画质切换：按钮上显示当前画质，点开后在按钮**正上方**弹出与按钮等宽的菜单
  Widget _buildQualityButton(LiveStreamController controller) {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final qualities = controller.availableQualities;
      final current = controller.currentQuality;
      final switching = controller.isSwitchingQuality;

      final label = current == null ? '画质' : controller.qualityName(current);

      // 没有可选项就退化成纯文本，不给点
      if (qualities.isEmpty) {
        return TextButton(
          onPressed: null,
          child: Text(label, style: const TextStyle(color: Colors.white54)),
        );
      }

      // 用 Builder 拿到「按钮自己」这一层的 context，才量得到按钮的尺寸和位置
      return Builder(
        builder: (buttonContext) => InkWell(
          onTap: switching
              ? null
              : () => _showAnchoredMenu<LIVE_VIDEO_QUALITY>(
                  buttonContext: buttonContext,
                  controller: controller,
                  options: qualities,
                  current: current,
                  labelOf: controller.qualityName,
                  onSelected: controller.switchQuality,
                ),
          child: _buildControlBarButton(icon: switching ? null : Icons.high_quality, label: label, busy: switching),
        ),
      );
    });
  }

  /// 线路切换：同一画质下的多条流（协议/编码不同，内容相同），样式与画质切换一致
  Widget _buildLineButton(LiveStreamController controller) {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final lines = controller.availableLines;
      final current = controller.currentLine;
      final switching = controller.isSwitchingQuality;

      final label = lines.isEmpty ? '线路' : controller.lineName(current);

      // 只有一条线路时没什么可切的，退化成纯文本
      if (lines.length <= 1) {
        return TextButton(
          onPressed: null,
          child: Text(label, style: const TextStyle(color: Colors.white54)),
        );
      }

      // 菜单项和按钮用同一套文案：线路号 + 协议 + 编码，
      // 这样在菜单里就能直接看出各条线路的差别（FLV / HLS、H.264 / H.265），
      // 不用先选中再回头查按钮上的字。
      return Builder(
        builder: (buttonContext) => InkWell(
          onTap: switching
              ? null
              : () => _showAnchoredMenu<int>(
                  buttonContext: buttonContext,
                  controller: controller,
                  options: List<int>.generate(lines.length, (i) => i),
                  current: current,
                  labelOf: controller.lineName,
                  onSelected: controller.switchLine,
                ),
          child: _buildControlBarButton(icon: switching ? null : Icons.swap_horiz, label: label, busy: switching),
        ),
      );
    });
  }

  /// 控制栏里「图标 + 文字」按钮的统一长相，画质和线路共用，保证两个按钮观感一致
  Widget _buildControlBarButton({required IconData? icon, required String label, required bool busy}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          else if (icon != null)
            Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  /// 在按钮正上方弹出选单。宽度与按钮完全一致，每项高度见 [_kQualityItemHeight]。
  ///
  /// 画质和线路共用这一份实现，所以两者的弹框样式天然保持一致。
  /// 这里刻意不用 PopupMenuButton：它的菜单宽度被框架夹在 112~280 之间
  /// （_kMenuMinWidth = 2 * 56），而控制栏按钮只有 60 多像素宽，弹框必然大一圈；
  /// 它也没有「锚定在按钮上方」的锚点选项，默认是覆盖按钮或向下展开。
  Future<void> _showAnchoredMenu<T>({
    required BuildContext buttonContext,
    required LiveStreamController controller,
    required List<T> options,
    required T? current,
    required String Function(T option) labelOf,
    required Future<void> Function(T option) onSelected,
  }) async {
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(buttonContext, rootOverlay: true).context.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize || overlay == null) return;

    final size = buttonBox.size;
    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlay);

    // 菜单整体高度：全是定高项，直接算得出，不需要等布局完成再回填位置
    final menuHeight = options.length * _kQualityItemHeight;
    // 菜单底边贴着按钮顶边（再留一条缝）；按钮太靠上放不下时退回按钮下方
    var menuBottom = topLeft.dy - _kQualityMenuGap;
    if (menuBottom - menuHeight < 0) {
      menuBottom = topLeft.dy + size.height + _kQualityMenuGap + menuHeight;
    }
    // 无论向上还是向下，都不允许越出 overlay 底边（否则顶部几条会被裁掉）
    if (menuBottom > overlay.size.height) {
      menuBottom = overlay.size.height - _kQualityMenuGap;
    }

    // 菜单一展开就锁住底部控制栏：菜单是独立 route 盖在 overlay 上，
    // 鼠标移上去会触发播放区 MouseRegion 的 onExit，不锁的话控制栏就被收掉了。
    controller.setQualityMenuOpen(true);
    T? selected;
    try {
      selected = await showMenu<T>(
        context: buttonContext,
        position: RelativeRect.fromLTRB(topLeft.dx, menuBottom - menuHeight, overlay.size.width - topLeft.dx - size.width, overlay.size.height - menuBottom),
        // 宽度锁死成按钮宽度，消除框架默认的 112 最小宽度
        constraints: BoxConstraints.tightFor(width: size.width),
        // 黑底半透明：和弹幕设置面板保持一致的观感，压在视频画面上也不突兀
        color: Colors.black.withValues(alpha: 0.82),
        // 关掉默认阴影：半透明的底 + 一层实阴影会显得发灰，边框也更利落
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
        // 每项定高 + 内边距清零，菜单总高才等于 options.length * _kQualityItemHeight
        items: options
            .map(
              (option) => PopupMenuItem<T>(
                value: option,
                height: _kQualityItemHeight,
                padding: EdgeInsets.zero,
                child: SizedBox(
                  height: _kQualityItemHeight,
                  child: Center(
                    child: Text(
                      labelOf(option),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        // 黑底白字，当前项用亮蓝加粗区分（深色底上纯蓝会发暗）
                        color: option == current ? const Color(0xFF6FA8FF) : Colors.white,
                        fontWeight: option == current ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      );
    } finally {
      // 无论选中、点空白取消还是异常退出，都要解除控制栏的锁定
      controller.setQualityMenuOpen(false);
    }

    if (selected != null) {
      await onSelected(selected);
    }
  }

  // ================= 模块三：视频下方操作栏 =================
  Widget _buildVideoBottomToolbar() {
    final compact = _isCompactWidth;
    // 手机上操作栏加高、文字加大：40 高 + 12 号字在触屏上很难点准。
    final barHeight = compact ? 48.0 : _kBottomToolbarHeight;
    final gap = compact ? 20.0 : 16.0;

    return Container(
      height: barHeight,
      // 白底 + 顶部一条浅灰分隔线，和白色页面背景连成一片
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      // 手机上左右留白也收一点，给按钮更多空间
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
      // 【横向可滚动 + 两端布局】
      // 按钮数量固定但文字长短不一，手机竖屏下会超出（实测溢出 267px），
      // 所以保留横向滚动兜底。
      //
      // 【宽度要给满】SingleChildScrollView 里的 Row 默认按内容收缩，
      // 那样 spaceBetween 没有多余空白可分，直链只能紧跟着刷新贴在左边。
      // 这里用 LayoutBuilder 拿真实可用宽度并铺成 minWidth，
      // Row 撑满后「关注/特别关注/刷新」贴左、「直链」贴右才是真的分两端。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: available),
              child: Row(
                // 垂直居中：操作栏加高后按钮不该贴在顶部
                crossAxisAlignment: CrossAxisAlignment.center,
                // 左组（关注/特别关注/刷新）与右组（直链）分居两端
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildFavoriteAction(),
                      SizedBox(width: gap),
                      // 特别关注：关注之上的附加状态，只会上主页名片区
                      _buildSpecialFollowAction(),
                      SizedBox(width: gap),
                      _buildBottomActionItem(Icons.refresh, '刷新', () => controller.refreshStream()),
                    ],
                  ),
                  // 保底间距：容器窄到没有剩余空白时，直链不至于贴住刷新
                  const SizedBox(width: 16),
                  _buildBottomActionItem(Icons.link, '直链', () => _handleCopyStreamUrl()),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 「关注」按钮：已关注用实心红心高亮，未关注用空心。
  /// 用 ListenableBuilder 单独订阅 isFavorited，避免整条工具栏跟着重建。
  Widget _buildFavoriteAction() {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final favorited = controller.isFavorited;
      return _buildBottomActionItem(
        favorited ? Icons.favorite : Icons.favorite_border,
        favorited ? '已关注' : '关注',
        () => controller.toggleFavorite(),
        color: favorited ? const Color(0xFFE53935) : null,
      );
    });
  }

  /// 「特别关注」按钮：点亮后会上主页名片区。
  ///
  /// 用星形而不是心形，和「关注」区分开；
  /// 未特别关注时用空心星（灰），已特别关注用实心星（橙）。
  Widget _buildSpecialFollowAction() {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final special = controller.isSpecialFollowed;
      return _buildBottomActionItem(
        special ? Icons.star : Icons.star_border,
        special ? '已特别关注' : '特别关注',
        () => controller.toggleSpecialFollow(),
        color: special ? const Color(0xFFFFA000) : null,
      );
    });
  }

  Widget _buildBottomActionItem(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    final compact = _isCompactWidth;
    // 手机上放大图标与文字，并给足内边距 —— 触屏没有鼠标精度，
    // 40 高 / 12 号字的点击区太小，容易点不中或点错相邻项。
    final iconSize = compact ? 18.0 : 14.0;
    final fontSize = compact ? 13.0 : 12.0;

    return InkWell(
      onTap: onTap,
      // 圆角 + 内边距，让点击区域更明确（也让相邻按钮之间有呼吸感）
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 0, vertical: compact ? 6 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 白底：默认用深灰，带 color 的（例如已关注的红心）保持传入色
            Icon(icon, size: iconSize, color: color ?? Colors.black87),
            SizedBox(width: compact ? 6 : 4),
            Text(
              label,
              style: TextStyle(fontSize: fontSize, color: color ?? Colors.black87),
            ),
          ],
        ),
      ),
    );
  }

  /// 「直链」按钮：取当前正在播放的流地址，复制到剪贴板。
  ///
  /// 复制而不是弹窗展示，是因为直播流地址往往很长（几百字符，
  /// 带一堆签名参数），弹窗里既看不清也不好选中。
  /// 复制后弹一条轻提示，用户自己去下载器/播放器里粘贴。
  Future<void> _handleCopyStreamUrl() async {
    final url = await controller.get_clarity_vido_play_url();

    if (url.isEmpty) {
      AppSnackbar.show('直链', '暂时取不到播放地址（可能还在加载，或当前清晰度没有可用线路）');
      return;
    }

    try {
      await Clipboard.setData(ClipboardData(text: url));
      AppSnackbar.show('已复制', url.length > 44 ? '${url.substring(0, 44)}…' : url);
    } catch (_) {
      // 剪贴板被系统占用等异常，同样用提示反馈，不要静默失败
      AppSnackbar.show('复制链接失败', '系统剪贴板不可用，请稍后重试');
    }
  }

  // ================= 模块四：主播信息 + 弹幕区 =================
  //
  // 桌面：右侧固定 320 宽的侧栏
  // 手机：视频下方的整块区域（fillWidth = true，不限宽，铺满屏幕）
  Widget _buildRightSidebar(LiveRoomInfo roomInfo, {bool fillWidth = false}) {
    return Container(
      // 手机端铺满宽度，桌面端固定 320
      width: fillWidth ? double.infinity : _kSidebarWidth,
      // 背景图：assets/background/danmaku_background.jpg
      //
      // 图上再叠一层白色遮罩（不透明度 0.82）后才画内容，原因有两个：
      //   1) 侧边栏里的文字全是深色（black87/black54/black45），
      //      直接压在图片上，遇到图片的深色区域会看不清；
      //   2) 弹幕是滚动的高频内容，背景要足够"静"，不能抢文字。
      // 遮罩留 18% 的透光率，图片还能隐约透出来，不至于变成纯白。
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/background/danmaku_background.jpg'),
          // cover 铺满整个侧边栏，超出部分裁掉，不留黑边
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.82)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 主播信息区：[主播头像] + 右侧整体上下布局的 [主播名字] / [主播平台]
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.pinkAccent,
                    backgroundImage: roomInfo.owner_profile_url != null ? NetworkImage(roomInfo.owner_profile_url!) : null,
                    child: roomInfo.owner_profile_url == null ? const Icon(Icons.person, color: Colors.white) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 上：主播名字
                        Text(
                          roomInfo.owner_name ?? '未知主播',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 4),

                        // 下：主播平台 = 平台图标 + 平台名字
                        Row(
                          children: [
                            _buildPlatformIcon(roomInfo.live_site, size: 14),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                roomInfo.live_site == null ? '未知平台' : LiveSites.of(roomInfo.live_site!).displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: Colors.black45),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.local_fire_department, size: 12, color: Colors.orange),
                            const Text('1', style: TextStyle(fontSize: 12, color: Colors.black45)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 选项卡
            Container(
              decoration: const BoxDecoration(
                // 白底上的分隔线要用浅灰，white12 在白底上完全看不见
                border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: Row(children: [_buildTabItem('互动', true), _buildTabItem('醒目留言(3)', false), _buildTabItem('设置与屏蔽', false)]),
            ),

            // 聊天弹幕列表（真实弹幕，来自 controller.danmakuList）
            Expanded(child: _buildDanmakuList()),
          ],
        ),
      ),
    );
  }

  /// 右侧栏的弹幕列表。
  ///
  /// 单独包一层 ListenableBuilder：弹幕是高频流（每秒可能好几条），如果不隔离，
  /// 每条弹幕都会把整个页面（含视频区）重建一次。
  Widget _buildDanmakuList() {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final list = controller.danmakuList;
      final status = controller.danmakuStatus;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 连接状态：首测阶段用来判断是哪一端没连上。
          // 未确认时用中性图标（amber）：斗鱼的 connect() 会把握手异常吞掉去重连，
          // 所以「没红叉」不等于失败，真的收到弹幕才会变绿。
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: [
                  Icon(
                    controller.danmakuConnected ? Icons.cloud_done : Icons.cloud_queue,
                    size: 13,
                    color: controller.danmakuConnected ? Colors.greenAccent : Colors.amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: list.isEmpty
                ? const Center(
                    // 白底上的占位文字用浅灰，white38 在白底上完全看不见
                    child: Text('暂无弹幕', style: TextStyle(fontSize: 12, color: Colors.black38)),
                  )
                // reverse: True 让列表贴底：新弹幕从底部进，且不需要 ScrollController
                // 就能自动跟随最新一条（用户往上翻看历史时不会被强行拽回底部）。
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: list.length,
                    // 【固定行高】不给 itemExtent 的话，ListView 每帧都要
                    itemExtent: _kDanmakuRowHeight,
                    itemBuilder: (context, index) {
                      final msg = list[list.length - 1 - index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6.0),
                        child: RichText(
                          // 单行 + 省略号：超长弹幕不换行，保证行高恒定
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            // 白底：正文深灰、昵称蓝色，保证在白色背景上可读
                            style: const TextStyle(fontSize: _kDanmakuFontSize, color: Colors.black87),
                            children: [
                              TextSpan(
                                text: '${msg.nickname}: ',
                                style: TextStyle(color: Colors.blue[700]),
                              ),
                              TextSpan(text: msg.content),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    });
  }

  Widget _buildTabItem(String title, bool isActive) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: isActive ? Colors.blueAccent : Colors.transparent, width: 2)),
        ),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            // 白底：选中蓝、未选中深灰
            color: isActive ? Colors.blueAccent : Colors.black87,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
