import 'package:flutter/material.dart';

import 'package:ym_live_stream/contract/auth_source.dart';

import 'package:ym_live_stream/presentation/controller/favorites_controller.dart';
import 'package:ym_live_stream/presentation/controller/home_page_control.dart';
// 设置页的控制器（已从 GetX 迁到 ChangeNotifier）
import 'package:ym_live_stream/presentation/controller/settings_controller.dart';
import 'package:ym_live_stream/presentation/favorites_scope.dart';
import 'package:ym_live_stream/presentation/settings_scope.dart';

import 'package:ym_live_stream/presentation/widgets/app_snackbar.dart';
import 'package:ym_live_stream/presentation/widgets/bilibili_login_dialog.dart';
import 'package:ym_live_stream/presentation/widgets/dashed_divider_with_label.dart';
import 'package:ym_live_stream/presentation/widgets/live_card_grid.dart';
import 'package:ym_live_stream/presentation/widgets/live_search_bar.dart';

/// 程序主页。
///
/// 布局：
///   左：40px 宽的页面切换栏（主页 / 收藏 / 设置）
///   右：上下两块，中间虚线写“收藏列表刷新”（点击重新下查开播状态）
///     上：搜索栏（与虚线同宽、同处一列，横轴居中，贴近虚线）
///     下：名片网格
///
/// 搜索栏、虚线、名片网格都用同一个 contentWidth，保证三者左右对齐。
///
/// 【为什么外面套一层 StatefulWidget】
/// 收藏列表的控制器（FavoritesController）挂在 App 根部的 FavoritesScope 上，
/// 但它的**首次加载**（铺本地快照 + 下查开播状态）不能放在 App 启动时做 ——
/// 用户可能根本不看关注列表，白跑几十个网络请求。
/// 所以由本页面在 initState 里触发一次（`init()` 内部有幂等保护）。
///
/// 同时要把 controller 实例交给 HomeController：进房回来 / 未开播弹窗关掉之后，
/// 需要通知它按存储重建名片。用「页面注入」而不是 HomeController 直接持有
/// FavoritesController，是为了避免两个 controller 互相依赖。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageHost();
}

class _HomePageHost extends State<HomePage> {
  late final HomeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomeController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 收藏列表控制器（App 级共享，录播页以后也用同一份）
    final favorites = FavoritesScope.of(context);

    // 注入给 HomeController：它需要在「进房返回」「弹窗关闭」时触发名片重建。
    // 放在 build 里赋值而不是 initState，是因为 FavoritesScope 只能从 context 取。
    // 重复赋值无害（同一个实例）。
    _controller.favorites = favorites;

    // 首次加载收藏：只跑一次（FavoritesController.init 内部幂等）。
    favorites.init();

    return _HomePageView(controller: _controller);
  }
}

class _HomePageView extends StatelessWidget {
  final HomeController controller;

  const _HomePageView({super.key, required this.controller});

  /// 左侧切换栏宽度（桌面）
  static const double navRailWidth = 40;

  /// 左侧切换栏宽度（窄屏）。
  ///
  /// 桌面 40 够用，但在手机上 40 逻辑像素的点击区域太小、
  /// 而且图标挤在一起不好点。窄屏放宽到 56（贴近 Material 的最小触控目标）。
  static const double navRailWidthCompact = 56;

  /// 当前屏幕是否属于「窄屏」（手机 / 分屏）。
  ///
  /// 用 600 作为分界：Material 的断点规范里
  ///   < 600   = compact（手机竖屏）
  ///   600~840 = medium（平板竖屏 / 手机横屏）
  ///   > 840   = expanded（桌面）
  /// 当前屏幕是否属于「窄屏」（手机 / 分屏）。
  ///
  /// 用 600 作为分界：Material 的断点规范里
  ///   < 600   = compact（手机竖屏）
  ///   600~840 = medium（平板竖屏 / 手机横屏）
  ///   > 840   = expanded（桌面）
  ///
  /// 【为什么不接 BuildContext 参数】这个判断在很多辅助方法里要用
  /// （_buildNavRail、_buildContentColumn…），而它们本身没有 context 参数。
  /// 之前写成 _isCompactWidth(context) 直接报了 Undefined name 'context' ——
  /// 那些方法的签名里根本没有 context。
  /// 改成从当前 FlutterView 取尺寸：结果等价于 MediaQuery.sizeOf，
  /// 而且任何地方都能调，不用为了一个数字把 context 层层往下传。
  static bool get _isCompactWidth {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return false; // 拿不到视图时按桌面处理，布局不会崩
    return view.physicalSize.width / view.devicePixelRatio < 600;
  }

  /// 内容区最大宽度：搜索栏 / 虚线 / 网格共用，保证宽度一致
  static const double contentMaxWidth = 1120;

  /// 内容区左右留白（桌面）
  static const double contentPadding = 24;

  /// 内容区左右留白（窄屏）。手机上 24 两边加起来 48 太浪费，收到 12。
  static const double contentPaddingCompact = 12;

  /// 搜索栏底边与虚线之间的距离（桌面）
  static const double searchGap = 40;

  /// 搜索栏底边与虚线之间的距离（窄屏）。手机上竖向空间紧张，压缩到 16。
  static const double searchGapCompact = 16;

  /// 上半区（搜索区）与下半区的高度比。
  /// 需求：虚线再往下移 -> 继续加大上半区比例。
  /// 想微调虚线位置，只改这两个值即可。
  static const int _topSectionFlex = 5;
  static const int _bottomSectionFlex = 4;

  /// 窄屏下的上下区比例：手机上搜索区不需要那么高，
  /// 多让给名片区（名片更适合滚动浏览）。
  static const int _topSectionFlexCompact = 2;
  static const int _bottomSectionFlexCompact = 5;

  /// 背景图
  static const String _backgroundAsset = 'assets/background/caho_background_pciture.jpg';

  // ===================== 关于页信息 =====================
  //
  // 【为什么集中在这里】这些值以后还要给「设置」页和打包信息用，
  // 写在页面里一处，改版本号/换链接只改这一块。
  //
  // 【和 pubspec.yaml 的 version 保持一致】项目没有接入 package_info_plus，
  // 版本号只能手写。以后引入 package_info_plus 后，
  // 这里换成运行时读取，就不用两处同步了。
  static const String _kAppName = 'YM Live Stream';

  static const String _kAppVersion = '0.2.0-beta';

  static const String _kAppAuthor = 'YanMo';
  static const String _kAppCopyrightYear = '2026';

  static const String _kAppHomepage = 'https://github.com/yanmo-null/ym_live_stream';
  static const String _kAppHomepageText = 'github.com/yanmo-null/ym_live_stream';

  static const String _kAppGithubUrl = 'https://github.com/yanmo-null/ym_live_stream';
  static const String _kAppGithubText = 'github.com/yanmo-null/ym_live_stream';

  static const String _kAppTelegramUrl = 'https://t.me/+OWI9FPLB2CcwMzI1';
  static const String _kAppTelegramText = 't.me/+OWI9FPLB2CcwMzI1';

  // static const String _kAppDiscordUrl = 'https://discord.gg/your_invite';
  // static const String _kAppDiscordText = 'discord.gg/your_invite';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 背景图铺满整页，导航栏与内容浮在上面
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackground(),

          // 【必须用 SafeArea 包住内容】原来内容直接顶到屏幕四边，
          // 在 Android 上会被状态栏、刘海/挖孔（前置摄像头）盖住：
          // 顶部按钮跑到摄像头位置、底部被手势条挡住，都是这个原因。
          // SafeArea 会按各平台的实际安全区（也是 iOS 刘海屏的基础保障）留出内边距。
          SafeArea(child: _buildBody(context)),
        ],
      ),
    );
  }

  /// [context] 必须从 build 一路传下来。
  ///
  /// 【为什么不能省】设置页要用 `SettingsScope.of(context)` 取 controller，
  /// 而 `Obx` 的 builder 是 `Widget Function()`，**没有 context 参数**；
  /// `_buildBody` / `_buildSettingsTab` 自己也不带 context。
  /// 之前这里写成 `_buildBody()` 会直接报 Undefined name 'context'。
  Widget _buildBody(BuildContext context) {
    return Row(
      children: [
        _buildNavRail(),
        Expanded(
          child: ListenableBuilder(listenable: controller, builder: (context, _) {
            final tab = controller.selectedTab;

            // 【关于页单独处理】它不在 IndexedStack 里：
            // 前三个页面靠 IndexedStack 保状态（切走再切回来，搜索框内容和滚动位置都还在），
            // 而「关于」是一张静态信息页，没有需要保持的状态，
            // 硬塞进 IndexedStack 就得给它补一个占位子节点，反而干扰已有顺序。
            if (tab == HomeTab.about) {
              return _buildAboutTab();
            }

            // 三个主页面共用同一个 HomeController，用 IndexedStack 保状态。
            // index 直接用枚举序号：HomeTab 里前三个分别是 home/collection/settings，
            // 和下面三个子页面的顺序一一对应。
            return IndexedStack(
              index: tab.index,
              children: [_buildHomeTab(context), _buildCollectionTab(context), _buildSettingsTab(context)],
            );
          }),
        ),
      ],
    );
  }

  // ===================== 背景 =====================
  Widget _buildBackground() {
    return Image.asset(
      _backgroundAsset,
      fit: BoxFit.cover,
      // 背景图偏浅（白底粉蓝），整体叠一层白色蒙版，
      // 保证后续文字/控件始终有足够对比度。
      errorBuilder: (context, error, stackTrace) => const ColoredBox(color: Color(0xFFF7F3F5)),
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return _withScrim(child);
        return AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 250), child: _withScrim(child));
      },
    );
  }

  Widget _withScrim(Widget child) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // 提亮蒙版：轻微压掉背景细节，让控件更清晰
        const ColoredBox(color: Color(0x66FFFFFF)),
      ],
    );
  }

  // ===================== 内容宽度约束 =====================
  /// 把内容限制在 contentMaxWidth 内并水平居中，
  /// 搜索栏 / 虚线 / 网格都套这一层 -> 三者同宽且左对齐。
  Widget _buildContentColumn({required Widget child}) {
    // 手机左右留白比桌面小，否则可用宽度太窄
    final padding = _isCompactWidth ? contentPaddingCompact : contentPadding;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: contentMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: child,
        ),
      ),
    );
  }

  // ===================== 左侧切换栏 =====================
  Widget _buildNavRail() {
    final railWidth = _isCompactWidth ? navRailWidthCompact : navRailWidth;

    return Container(
      width: railWidth,
      // 半透明，透出背景图
      color: Colors.white.withValues(alpha: 0.55),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // 主页面按钮（主页 / 关注 / 设置）
          //
          // navItems 是固定列表，不需要 Obx 包住；
          // 变化的是“选中项”，所以把 Obx 放在每个按钮内部（见 _buildNavButton）。
          for (var i = 0; i < HomeController.primaryNavCount; i++) _buildNavButton(i, railWidth),

          // 【关于固定在底部】Spacer 把剩下的竖向空间吃掉，
          // 于是「关于」始终贴在导航栏最下沿，不跟随上面三个按钮往上排。
          // 手机端导航栏变窄，但高度逻辑一样。
          const Spacer(),

          // 「关于」按钮：index 就是它在 navItems 里的实际位置（第 4 项）
          _buildNavButton(HomeController.primaryNavCount, railWidth),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildNavButton(int index, double railWidth) {
    final item = controller.navItems[index];

    // 每个按钮自己订阅 selectedTab：这样读可观察值的位置就在 Obx 内部，
    // 避免 Obx 包住一个“自身不读可观察值”的子方法而报 improper use。
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final isActive = controller.selectedTab.index == index;

      return Tooltip(
        message: item.title,
        child: InkWell(
          // 点击切换；真正的页面跳转逻辑按需求留空，
          // 若要改成独立路由，在 HomeController.switchTab 里补 Get.toNamed 即可。
          onTap: () => controller.switchTab(HomeTab.values[index]),
          child: Container(
            width: railWidth,
            // 手机上加大点击高度，44 是 Material 建议的最小触控尺寸
            height: 48,
            alignment: Alignment.center,
            child: Icon(isActive ? item.activeIcon : item.icon, size: 22, color: isActive ? const Color(0xFF3D7EFF) : const Color(0xFF888888)),
          ),
        ),
      );
    });
  }

  // ===================== 关于 =====================
  //
  // 布局参照单机软件常见的「关于」页：
  //
  //   [logo] 应用名
  //   Version x.y.z
  //
  //   一句话介绍
  //   © 年份 作者 / 项目名
  //
  //   官网：xxx
  //   GitHub：xxx
  //
  //   [问题反馈] [检查更新] [确定]
  //
  // 【为什么不用弹窗】需求明确要求放在导航栏最下面作为独立页面，
  // 所以这里是正常的一页，不是 Dialog。
  //
  // 【窄屏处理】手机宽度只有 360，内容区用可滚动 + 限宽居中，
  // 避免链接文字换行后按钮被挤出屏幕。
  Widget _buildAboutTab() {
    final compact = _isCompactWidth;

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        // 顶部留白参照截图：标题与内容之间有明显间距
        horizontal: compact ? 20 : 32,
        vertical: compact ? 28 : 40,
      ),
      child: Center(
        // 桌面端不要把内容拉到整屏宽，居中一块更像「关于」页
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- 顶部：logo + 应用名 ----------
              Row(
                children: [
                  // 应用自己的 logo，和桌面图标是同一张
                  // （图本身是圆角方块，四角透明，直接显示即可，不用再裁剪）
                  Image.asset(
                    'assets/icon/ymlive_logo.png',
                    width: compact ? 40 : 48,
                    height: compact ? 40 : 48,
                    // 图缺失时兜底：显示一个电视图标，避免出现红色错误块
                    errorBuilder: (context, error, stackTrace) => Icon(Icons.live_tv, size: compact ? 40 : 48, color: const Color(0xFF3D7EFF)),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _kAppName,
                    style: TextStyle(fontSize: compact ? 22 : 26, fontWeight: FontWeight.bold, color: const Color(0xFF1F1F1F)),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // ---------- 版本号 ----------
              Text('Version $_kAppVersion', style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),

              const SizedBox(height: 20),

              // ---------- 一句话介绍 ----------
              const Text(
                '        一款开源的跨平台多平台直播聚合客户端, 初衷有两点, 一是为了解决旧设备因性能不足导致观看直播卡顿的问题,'
                '二是解决观看不同平台主播需要频繁切换APP的问题。目前支持哔哩哔哩、斗鱼、抖音、虎牙、快手，后续会支持官网的录播播放，以及Youtube、Twitch、PandaTv等海外平台。',
                style: TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF333333)),
              ),

              const SizedBox(height: 6),

              // ---------- 版权 ----------
              Text('© $_kAppCopyrightYear $_kAppAuthor / $_kAppName Project', style: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF555555))),

              const SizedBox(height: 24),

              // ---------- 链接 ----------
              _buildAboutLink('官网', _kAppHomepage, '$_kAppHomepageText'),
              const SizedBox(height: 10),
              _buildAboutLink('GitHub', _kAppGithubUrl, '$_kAppGithubText'),
              const SizedBox(height: 10),
              _buildAboutLink('Telegram', _kAppTelegramUrl, '$_kAppTelegramText'),
              const SizedBox(height: 10),
              // _buildAboutLink('Discord', _kAppDiscordUrl, '$_kAppDiscordText'),

              const SizedBox(height: 32),

              // ---------- 底部按钮 ----------
              //
              // 手机端可用宽度窄，三个按钮横排会挤，改成纵向排列。
              if (compact)
                Column(
                  children: [
                    _buildAboutButton('问题反馈', icon: Icons.bug_report_outlined, onTap: _showAboutFeedbackTip),
                    const SizedBox(height: 10),
                    _buildAboutButton('检查更新', icon: Icons.refresh, onTap: _showAboutUpdateTip),
                    // const SizedBox(height: 10),
                    // _buildAboutButton('返回', icon: Icons.arrow_back, onTap: () => controller.switchTab(HomeTab.home)),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: _buildAboutButton('问题反馈', icon: Icons.bug_report_outlined, onTap: _showAboutFeedbackTip),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildAboutButton('检查更新', icon: Icons.refresh, onTap: _showAboutUpdateTip),
                    ),
                    // const SizedBox(width: 12),
                    // Expanded(
                    //   child: _buildAboutButton('返回', icon: Icons.arrow_back, onTap: () => controller.switchTab(HomeTab.home)),
                    // ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「关于」页里的一行「标签：链接」，样式参照截图里的下划线链接。
  Widget _buildAboutLink(String label, String url, String displayText) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标签用固定宽度，让几行的冒号能对齐
        SizedBox(
          width: 72,
          child: Text('$label：', style: const TextStyle(fontSize: 13, color: Color(0xFF555555))),
        ),
        Expanded(
          child: InkWell(
            onTap: () => _openAboutUrl(url),
            child: Text(
              displayText,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF3D7EFF),
                // 截图里链接是带下划线的
                decoration: TextDecoration.underline,
                decorationColor: Color(0xFF3D7EFF),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 「关于」页的按钮：浅灰底 + 圆角，对应截图里的三个按钮。
  Widget _buildAboutButton(String label, {required IconData icon, required VoidCallback onTap}) {
    return SizedBox(
      height: 40,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: const Color(0xFF444444)),
        label: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFFF2F2F2),
          foregroundColor: const Color(0xFF333333),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  /// 打开外部链接。
  ///
  /// 【当前是占位实现】项目还没引入 url_launcher，
  /// 这里先弹提示，避免点了没反应让人以为坏了。
  /// 接入 url_launcher 后把这里换成 launchUrl(Uri.parse(url)) 即可。
  void _openAboutUrl(String url) {
    AppSnackbar.show('链接', url);
  }

  void _showAboutFeedbackTip() {
    AppSnackbar.show('问题反馈', '请到 GitHub Issues 提交：$_kAppGithubUrl/issues', duration: const Duration(seconds: 4));
  }

  void _showAboutUpdateTip() {
    AppSnackbar.show('检查更新', '当前版本 $_kAppVersion，尚未接入更新检查');
  }

  // ===================== 主页 =====================
  //
  // 结构（按需求）：
  //   把“导航栏右侧”看作一个整体，用虚线把它分成上下两份，
  //   虚线本身包含在下半部分的最顶部。
  //
  //   ┌──────────────────────────────┐
  //   │  上半部分                      │
  //   │        [输入框][下拉][放大镜]  │ ← 贴近本区域底部，距虚线 searchGap
  //   ├──────────────────────────────┤ ← 虚线 + “收藏列表刷新”
  //   │  下半部分（虚线在它顶部）        │
  //   │        名片网格                │
  //   └──────────────────────────────┘
  Widget _buildHomeTab(BuildContext context) {
    // 窄屏把竖向空间多让给名片区，搜索区不需要占那么高
    final compact = _isCompactWidth;

    return Column(
      children: [
        // ---------- 上半部分：搜索区 ----------
        Expanded(
          flex: compact ? _topSectionFlexCompact : _topSectionFlex,
          child: Align(
            // bottomCenter：水平居中（在右侧内容区里居中）
            //              垂直贴底 -> 紧贴虚线上方
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: compact ? searchGapCompact : searchGap),
              // 【可滚动兜底】搜索栏的输入框会随内容长高（最长 LiveSearchBar.maxInputHeight），
              // 加上上方可能出现的错误提示，极端情况（小屏/横屏、键盘弹出后可用高度变矮）
              // 会超出这一段的可用高度，直接 Column 就是底部溢出条纹。
              // 包一层反向滚动：内容够高时贴底不变，超出时能往上滚着看全。
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 错误提示放在搜索栏上方：
                    // 放下面会把搜索栏顶离“距虚线 searchGap”的位置
                    ListenableBuilder(listenable: controller, builder: (context, _) {
                      final error = controller.searchError;
                      if (error == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFD32F2F), fontSize: 12),
                        ),
                      );
                    }),

                    LiveSearchBar(controller: controller),
                  ],
                ),
              ),
            ),
          ),
        ),

        // ---------- 下半部分（虚线是它的第一行）----------
        Expanded(
          flex: compact ? _bottomSectionFlexCompact : _bottomSectionFlex,
          child: Column(
            children: [
              // 虚线：属于下半部分，位于其顶部
              // 中间的「特别关注列表刷新」是透明按钮，点它重新下查开播状态
              _buildContentColumn(
                child: ListenableBuilder(
                  listenable: FavoritesScope.of(context),
                  builder: (context, _) => DashedDividerWithLabel(
                    label: '特别关注列表刷新',
                    color: const Color(0x55000000),
                    labelColor: const Color(0xFF555555),
                    onLabelTap: () => FavoritesScope.read(context).refreshLiveStatus(),
                  ),
                ),
              ),

              // 名片网格：主页只显示「特别关注」的房间
              Expanded(
                // 【Obx → ListenableBuilder】收藏列表已迁到 FavoritesController
                // （ChangeNotifier），不再是 GetX 的 RxList，所以订阅方式跟着换。
                child: ListenableBuilder(
                  listenable: FavoritesScope.of(context),
                  builder: (context, _) => LiveCardGrid(
                    items: FavoritesScope.read(context).specialCards,
                    padding: const EdgeInsets.only(top: 16, bottom: 16),
                    onTapItem: (item) {
                      if (item.roomId != null && item.site != null) {
                        controller.openLiveRoom(item.site!, item.roomId!);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ===================== 关注页（显示全部关注）=====================
  Widget _buildCollectionTab(BuildContext context) {
    return Column(
      children: [
        // 标题行：左侧「我的关注」，右侧一个透明按钮刷新开播状态
        _buildContentColumn(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                const Text(
                  '我的关注',
                  style: TextStyle(color: Color(0xFF333333), fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _buildRefreshStatusButton(context),
              ],
            ),
          ),
        ),
        Expanded(
          child: _buildContentColumn(
            // 关注页显示全部关注（含特别关注），和主页那份不是同一个列表。
            // 按平台分组：每组一条水平居中的虚线标题 + 该平台的卡片网格。
            child: ListenableBuilder(
              listenable: FavoritesScope.of(context),
              builder: (context, _) => _buildFollowedGroups(FavoritesScope.read(context)),
            ),
          ),
        ),
      ],
    );
  }

  /// 关注页的平台分组列表。
  ///
  /// 每组形如：
  ///   ────────── 哔哩哔哩 ──────────
  ///   [卡片] [卡片] [卡片]
  /// 组内用 LiveCardGrid（自带列数自适应），组间用虚线标题隔开。
  Widget _buildFollowedGroups(FavoritesController favorites) {
    final groups = favorites.followedGroups;

    if (groups.isEmpty) {
      return const LiveCardGrid(items: [], emptyText: '还没有关注的直播间');
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 平台名称虚线：水平居中显示在两条虚线中间
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: DashedDividerWithLabel(label: group.title, color: const Color(0x33000000), labelColor: const Color(0xFF555555)),
            ),
            // 该平台的卡片。
            // 每组一个独立的 GridView 时外层必须是 ListView，而 GridView 会去抢
            // 无限高度约束 —— 所以这里用 shrinkWrap + 禁滚动，让高度由内容决定，
            // 滚动统一交给外层 ListView。
            LiveCardGrid(
              items: group.cards,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              onTapItem: (item) {
                if (item.roomId != null && item.site != null) {
                  controller.openLiveRoom(item.site!, item.roomId!);
                }
              },
            ),
          ],
        );
      },
    );
  }

  /// 透明按钮：刷新收藏列表的开播状态。
  /// 刷新中显示小转圈并禁用点击，避免连点。
  ///
  /// [context] 用来从 FavoritesScope 取 controller（刷新状态属于收藏列表）。
  Widget _buildRefreshStatusButton(BuildContext context) {
    return ListenableBuilder(
      listenable: FavoritesScope.of(context),
      builder: (context, _) {
        final refreshing = FavoritesScope.read(context).isRefreshing;

        return TextButton(
          onPressed: refreshing ? null : () => FavoritesScope.read(context).refreshLiveStatus(),
          style: TextButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: const Color(0xFF3D7EFF),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (refreshing)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3D7EFF)))
              else
                const Icon(Icons.refresh, size: 16),
              const SizedBox(width: 4),
              const Text('刷新状态', style: TextStyle(fontSize: 13)),
            ],
          ),
        );
      },
    );
  }

  // ===================== 设置页 =====================
  //
  // 结构：左侧分类列表 + 右侧内容区（窄屏改成上下）。
  //   常规配置   → 关注列表导入/导出
  //   哔哩哔哩   → 用户登录（扫码）
  //   斗鱼 / 抖音 → 暂无可配置项，给一句占位说明
  //
  // 【这一块已经换成 ChangeNotifier】不再是 `ListenableBuilder(listenable: controller, builder: (context, _) => controller.xxx.value)`，
  // 而是从 SettingsScope 取 SettingsController，用 ListenableBuilder 订阅。
  // 这样做的好处：设置页的状态和 HomeController 彻底解耦，
  // 改设置页不会碰主页那几百行，也不会因为 GetX 停更而一起完蛋。
  Widget _buildSettingsTab(BuildContext context) {
    final settings = SettingsScope.of(context);

    final content = ListenableBuilder(
      listenable: settings,
      builder: (innerContext, _) {
        return switch (settings.section) {
          0 => _buildGeneralSettings(settings),
          1 => _buildBilibiliSettings(innerContext, settings),
          2 => _buildPlaceholderSettings('斗鱼', '暂无可配置项'),
          _ => _buildPlaceholderSettings('抖音', '暂无可配置项'),
        };
      },
    );

    // 【窄屏改成上下布局】原来固定 150px 侧栏，
    // 手机屏幕只有 360，留给内容的就剩 210 ——
    // 卡片里的标题、说明、按钮全挤在一起，就是「登录框挤成一团」的原因。
    // 窄屏改成「顶部分类横向标签 + 下方内容」，内容能拿到整个宽度。
    if (_isCompactWidth) {
      return Column(
        children: [
          _buildSettingsTopTabs(settings),
          Expanded(child: content),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左：分类
        SizedBox(width: 150, child: _buildSettingsSidebar(settings)),
        // 右：内容
        Expanded(child: content),
      ],
    );
  }

  /// 窄屏下的设置分类：顶部横向排开，可横向滚动
  Widget _buildSettingsTopTabs(SettingsController settings) {
    const items = <String>['常规配置', '哔哩哔哩', '斗鱼', '抖音'];

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final selected = settings.section;

        return Container(
          height: 48,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
          ),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final active = index == selected;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  onTap: () => settings.section = index,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFF3D7EFF).withValues(alpha: 0.1) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      items[index],
                      style: TextStyle(
                        fontSize: 13,
                        color: active ? const Color(0xFF3D7EFF) : const Color(0xFF666666),
                        fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 设置页左侧分类列表
  Widget _buildSettingsSidebar(SettingsController settings) {
    const items = <String>['常规配置', '哔哩哔哩', '斗鱼', '抖音'];

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final selected = settings.section;

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final active = index == selected;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => settings.section = index,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: active ? const Color(0xFF3D7EFF).withValues(alpha: 0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    items[index],
                    style: TextStyle(
                      fontSize: 13,
                      color: active ? const Color(0xFF3D7EFF) : const Color(0xFF666666),
                      fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 常规配置：关注列表导入 / 导出
  Widget _buildGeneralSettings(SettingsController settings) {
    return ListView(
      padding: EdgeInsets.all(_isCompactWidth ? 12 : 24),
      children: [
        ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            final exporting = settings.isExporting;
            final importing = settings.isImporting;
            final busy = settings.isFileBusy;

            return Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFEEEEEE)),
              ),
              child: Row(
                children: [
                  // 左：标题 + 灰色注释
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '关注列表配置',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF222222)),
                        ),
                        const SizedBox(height: 4),
                        const Text('包含关注和特殊关注', style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
                      ],
                    ),
                  ),

                  // 右：导入 / 导出
                  //
                  // 【不要用 CrossAxisAlignment.stretch】这个 Column 是 Row 的直接子项，
                  // 横向约束是松的（0..infinity），stretch 会要求子项取无限宽，
                  // 直接抛 "BoxConstraints forces an infinite width"。
                  // 两个按钮本身已经用 SizedBox(width: 80) 定了宽，不需要拉伸。
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: 30,
                        width: 80,
                        child: OutlinedButton(
                          onPressed: busy ? null : () => _handleImportFollows(context, settings),
                          style: _settingsButtonStyle(),
                          child: importing
                              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('导入', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 30,
                        width: 80,
                        child: OutlinedButton(
                          onPressed: busy ? null : () => _handleExportFollows(settings),
                          style: _settingsButtonStyle(),
                          child: exporting
                              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('导出', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  ButtonStyle _settingsButtonStyle() {
    return OutlinedButton.styleFrom(
      foregroundColor: const Color(0xFF3D7EFF),
      side: const BorderSide(color: Color(0xFFCCDDFF)),
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    );
  }

  /// 导入关注列表：调文件选择 → 合并 → snackbar 反馈
  ///
  /// [context] 用来取 FavoritesScope —— 导入完要让名片跟着刷新。
  Future<void> _handleImportFollows(BuildContext context, SettingsController settings) async {
    final r = await settings.importFollows();
    // message 为空表示用户取消了选择，静默返回不打扰
    if (r.message.isEmpty) return;
    // 【导入成功后要让主页/关注页的名片跟着刷新】
    // 这件事原来在 HomeController.importFollows 里顺手做；现在导入逻辑在
    // SettingsController、名片数据在 FavoritesController，两者互不认识，
    // 所以由**页面**在拿到结果后通知收藏列表重读存储。
    if (r.ok) FavoritesScope.read(context).reloadFromStore();
    AppSnackbar.show(r.ok ? '导入成功' : '导入失败', r.message);
  }

  /// 导出关注列表：调保存位置选择 → 写文件 → snackbar 反馈
  Future<void> _handleExportFollows(SettingsController settings) async {
    final r = await settings.exportFollows();
    if (r.message.isEmpty) return;
    AppSnackbar.show(r.ok ? '导出成功' : '导出失败', r.message);
  }

  /// 哔哩哔哩配置：只有用户登录一项
  /// [context] 用于弹扫码登录窗（showDialog 需要 context）。
  Widget _buildBilibiliSettings(BuildContext context, SettingsController settings) {
    return ListView(
      padding: EdgeInsets.all(_isCompactWidth ? 12 : 24),
      children: [
        ListenableBuilder(
          listenable: settings,
          builder: (cardContext, _) {
            final loggedIn = settings.isLoggedIn;
            final loggingIn = settings.isLoggingIn;

            return Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFEEEEEE)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '用户登录',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF222222)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          loggedIn ? settings.loginLabel : '未登录，登录后可解锁更高清晰度',
                          style: TextStyle(fontSize: 12, color: loggedIn ? const Color(0xFF2E7D32) : const Color(0xFF999999)),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 30,
                    width: 80,
                    child: OutlinedButton(
                      onPressed: loggingIn ? null : () => _handleBilibiliLogin(cardContext, settings),
                      style: _settingsButtonStyle(),
                      child: loggingIn
                          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(loggedIn ? '重新登录' : '登录', style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// 弹出扫码登录窗，结束后 snackbar 提示成功/失败
  Future<void> _handleBilibiliLogin(BuildContext context, SettingsController settings) async {
    settings.isLoggingIn = true;
    try {
      // 弹窗自己去注册表取登录实现，这里不用再传配置路径
      //
      // 【从 Get.dialog 换成 showDialog】GetX 的 dialog 依赖 GetMaterialApp
      // 初始化的 Overlay，路由换到 MaterialApp.router 后用不了。
      // 这里直接用 BuildContext 弹窗，是 Flutter 标准写法。
      final result = await showDialog<Object?>(context: context, barrierDismissible: false, builder: (dialogContext) => const BilibiliLoginDialog());

      if (result is LoginResult) {
        // 成功后刷新登录态摘要
        await settings.refreshBilibiliLoginState();
        final who = result.nickname?.isNotEmpty == true ? result.nickname! : '哔哩哔哩账号';
        AppSnackbar.show('登录成功', '$who 已登录');
      } else if (result is String) {
        AppSnackbar.show('登录失败', result);
      }
      // result == null 表示用户点了取消，不提示
    } finally {
      settings.isLoggingIn = false;
    }
  }

  /// 斗鱼 / 抖音的占位页
  Widget _buildPlaceholderSettings(String title, String desc) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, color: Color(0xFF666666))),
          const SizedBox(height: 6),
          Text(desc, style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
        ],
      ),
    );
  }
}
