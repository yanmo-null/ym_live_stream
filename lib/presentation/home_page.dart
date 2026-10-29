import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:ym_live_stream/contract/auth_source.dart';

import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

import 'package:ym_live_stream/presentation/widgets/bilibili_login_dialog.dart';
import 'package:ym_live_stream/presentation/widgets/dashed_divider_with_label.dart';
import 'package:ym_live_stream/presentation/widgets/live_card_grid.dart';
import 'package:ym_live_stream/presentation/widgets/live_search_bar.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  /// 左侧切换栏宽度（桌面）
  static const double navRailWidth = 40;

  static const double navRailWidthCompact = 56;

  static bool get _isCompactWidth {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return false;
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

  static const int _topSectionFlex = 5;
  static const int _bottomSectionFlex = 4;

  static const int _topSectionFlexCompact = 2;
  static const int _bottomSectionFlexCompact = 5;

  /// 背景图
  static const String _backgroundAsset = 'assets/background/caho_background_pciture.jpg';

  static const String _kAppName = 'YM Live Stream';

  /// 对应 pubspec.yaml 的 version: 0.1.0-beta.1+1（这里只显示版本名部分）
  static const String _kAppVersion = '0.1.0-beta.1';

  static const String _kAppAuthor = 'YanMo';
  static const String _kAppCopyrightYear = '2026';

  static const String _kAppHomepage = 'https://github.com/your-name/ym_live_stream';
  static const String _kAppHomepageText = 'github.com/your-name/ym_live_stream';

  static const String _kAppGithubUrl = 'https://github.com/your-name/ym_live_stream';
  static const String _kAppGithubText = 'github.com/your-name/ym_live_stream';

  static const String _kAppTelegramUrl = 'https://t.me/your_group';
  static const String _kAppTelegramText = 't.me/your_group';

  static const String _kAppDiscordUrl = 'https://discord.gg/your_invite';
  static const String _kAppDiscordText = 'discord.gg/your_invite';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackground(),

          SafeArea(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Row(
      children: [
        _buildNavRail(),
        Expanded(
          child: Obx(() {
            final tab = controller.selectedTab.value;

            if (tab == HomeTab.about) {
              return _buildAboutTab();
            }

            return IndexedStack(index: tab.index, children: [_buildHomeTab(), _buildCollectionTab(), _buildSettingsTab()]);
          }),
        ),
      ],
    );
  }

  Widget _buildBackground() {
    return Image.asset(
      _backgroundAsset,
      fit: BoxFit.cover,
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
        const ColoredBox(color: Color(0x66FFFFFF)),
      ],
    );
  }

  Widget _buildContentColumn({required Widget child}) {
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

  Widget _buildNavRail() {
    final railWidth = _isCompactWidth ? navRailWidthCompact : navRailWidth;

    return Container(
      width: railWidth,
      color: Colors.white.withValues(alpha: 0.55),
      child: Column(
        children: [
          const SizedBox(height: 12),
          for (var i = 0; i < HomeController.primaryNavCount; i++) _buildNavButton(i, railWidth),

          const Spacer(),

          _buildNavButton(HomeController.primaryNavCount, railWidth),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildNavButton(int index, double railWidth) {
    final item = controller.navItems[index];

    return Obx(() {
      final isActive = controller.selectedTab.value.index == index;

      return Tooltip(
        message: item.title,
        child: InkWell(
          onTap: () => controller.switchTab(HomeTab.values[index]),
          child: Container(
            width: railWidth,
            height: 48,
            alignment: Alignment.center,
            child: Icon(isActive ? item.activeIcon : item.icon, size: 22, color: isActive ? const Color(0xFF3D7EFF) : const Color(0xFF888888)),
          ),
        ),
      );
    });
  }

  Widget _buildAboutTab() {
    final compact = _isCompactWidth;

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 20 : 32,
        vertical: compact ? 28 : 40,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Image.asset(
                    'assets/icon/ymlive_logo.png',
                    width: compact ? 40 : 48,
                    height: compact ? 40 : 48,
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

              Text('Version $_kAppVersion', style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),

              const SizedBox(height: 20),

              const Text(
                '        一款开源的跨平台多平台直播聚合客户端, 初衷有两点, 一是为了解决旧设备因性能不足导致观看直播卡顿的问题,'
                '二是解决观看不同平台主播需要频繁切换APP的问题。目前支持哔哩哔哩、斗鱼、抖音，近期会支持虎牙和快手，后续会支持Youtube、Twitch、PandaTv等海外平台。',
                style: TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF333333)),
              ),

              const SizedBox(height: 6),

              Text('© $_kAppCopyrightYear $_kAppAuthor / $_kAppName Project', style: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF555555))),

              const SizedBox(height: 24),

              _buildAboutLink('官网', _kAppHomepage, '$_kAppHomepageText'),
              const SizedBox(height: 10),
              _buildAboutLink('GitHub', _kAppGithubUrl, '$_kAppGithubText'),
              const SizedBox(height: 10),
              _buildAboutLink('Telegram', _kAppTelegramUrl, '$_kAppTelegramText'),
              const SizedBox(height: 10),
              _buildAboutLink('Discord', _kAppDiscordUrl, '$_kAppDiscordText'),

              const SizedBox(height: 32),

              if (compact)
                Column(
                  children: [
                    _buildAboutButton('问题反馈', icon: Icons.bug_report_outlined, onTap: _showAboutFeedbackTip),
                    const SizedBox(height: 10),
                    _buildAboutButton('检查更新', icon: Icons.refresh, onTap: _showAboutUpdateTip),
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

  void _openAboutUrl(String url) {
    Get.snackbar('链接', url, snackPosition: SnackPosition.BOTTOM, duration: const Duration(seconds: 3));
  }

  void _showAboutFeedbackTip() {
    Get.snackbar('问题反馈', '请到 GitHub Issues 提交：$_kAppGithubUrl/issues', snackPosition: SnackPosition.BOTTOM, duration: const Duration(seconds: 4));
  }

  void _showAboutUpdateTip() {
    Get.snackbar('检查更新', '当前版本 $_kAppVersion，尚未接入更新检查', snackPosition: SnackPosition.BOTTOM, duration: const Duration(seconds: 3));
  }

  Widget _buildHomeTab() {
    final compact = _isCompactWidth;

    return Column(
      children: [
        Expanded(
          flex: compact ? _topSectionFlexCompact : _topSectionFlex,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: compact ? searchGapCompact : searchGap),
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Obx(() {
                      final error = controller.searchError.value;
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

        Expanded(
          flex: compact ? _bottomSectionFlexCompact : _bottomSectionFlex,
          child: Column(
            children: [
              _buildContentColumn(
                child: DashedDividerWithLabel(
                  label: '特别关注列表刷新',
                  color: const Color(0x55000000),
                  labelColor: const Color(0xFF555555),
                  onLabelTap: () => controller.refreshLiveStatus(),
                ),
              ),

              Expanded(
                child: Obx(
                  () => LiveCardGrid(
                    items: controller.specialCardList.value,
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

  Widget _buildCollectionTab() {
    return Column(
      children: [
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
                _buildRefreshStatusButton(),
              ],
            ),
          ),
        ),
        Expanded(
          child: _buildContentColumn(
            child: Obx(() => _buildFollowedGroups()),
          ),
        ),
      ],
    );
  }

  Widget _buildFollowedGroups() {
    final groups = controller.followedGroups;

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
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: DashedDividerWithLabel(label: group.title, color: const Color(0x33000000), labelColor: const Color(0xFF555555)),
            ),
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

  Widget _buildRefreshStatusButton() {
    return Obx(() {
      final refreshing = controller.isRefreshingStatus.value;

      return TextButton(
        onPressed: refreshing ? null : () => controller.refreshLiveStatus(),
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
    });
  }

  Widget _buildSettingsTab() {
    final content = Obx(() {
      return switch (controller.settingsSection.value) {
        0 => _buildGeneralSettings(),
        1 => _buildBilibiliSettings(),
        2 => _buildPlaceholderSettings('斗鱼', '暂无可配置项'),
        _ => _buildPlaceholderSettings('抖音', '暂无可配置项'),
      };
    });

    if (_isCompactWidth) {
      return Column(
        children: [
          _buildSettingsTopTabs(),
          Expanded(child: content),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 150, child: _buildSettingsSidebar()),
        Expanded(child: content),
      ],
    );
  }

  /// 窄屏下的设置分类：顶部横向排开，可横向滚动
  Widget _buildSettingsTopTabs() {
    const items = <String>['常规配置', '哔哩哔哩', '斗鱼', '抖音'];

    return Obx(() {
      final selected = controller.settingsSection.value;

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
                onTap: () => controller.settingsSection.value = index,
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
    });
  }

  /// 设置页左侧分类列表
  Widget _buildSettingsSidebar() {
    const items = <String>['常规配置', '哔哩哔哩', '斗鱼', '抖音'];

    return Obx(() {
      final selected = controller.settingsSection.value;

      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final active = index == selected;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: InkWell(
              onTap: () => controller.settingsSection.value = index,
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
    });
  }

  /// 常规配置：关注列表导入 / 导出
  Widget _buildGeneralSettings() {
    return ListView(
      padding: EdgeInsets.all(_isCompactWidth ? 12 : 24),
      children: [
        Obx(() {
          final exporting = controller.isExportingFollows.value;
          final importing = controller.isImportingFollows.value;
          final busy = exporting || importing;

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
                        '关注列表配置',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF222222)),
                      ),
                      const SizedBox(height: 4),
                      const Text('包含关注和特殊关注', style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
                    ],
                  ),
                ),

                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      height: 30,
                      width: 80,
                      child: OutlinedButton(
                        onPressed: busy ? null : () => _handleImportFollows(),
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
                        onPressed: busy ? null : () => _handleExportFollows(),
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
        }),
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
  Future<void> _handleImportFollows() async {
    final r = await controller.importFollows();
    if (r.message.isEmpty) return;
    Get.snackbar(r.ok ? '导入成功' : '导入失败', r.message, snackPosition: SnackPosition.BOTTOM);
  }

  /// 导出关注列表：调保存位置选择 → 写文件 → snackbar 反馈
  Future<void> _handleExportFollows() async {
    final r = await controller.exportFollows();
    if (r.message.isEmpty) return;
    Get.snackbar(r.ok ? '导出成功' : '导出失败', r.message, snackPosition: SnackPosition.BOTTOM);
  }

  /// 哔哩哔哩配置：只有用户登录一项
  Widget _buildBilibiliSettings() {
    return ListView(
      padding: EdgeInsets.all(_isCompactWidth ? 12 : 24),
      children: [
        Obx(() {
          final loggedIn = controller.bilibiliLoginLabel.value.isNotEmpty;
          final loggingIn = controller.isBilibiliLoggingIn.value;

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
                        loggedIn ? controller.bilibiliLoginLabel.value : '未登录，登录后可解锁更高清晰度',
                        style: TextStyle(fontSize: 12, color: loggedIn ? const Color(0xFF2E7D32) : const Color(0xFF999999)),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 30,
                  width: 80,
                  child: OutlinedButton(
                    onPressed: loggingIn ? null : () => _handleBilibiliLogin(),
                    style: _settingsButtonStyle(),
                    child: loggingIn
                        ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(loggedIn ? '重新登录' : '登录', style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// 弹出扫码登录窗，结束后 snackbar 提示成功/失败
  Future<void> _handleBilibiliLogin() async {
    controller.isBilibiliLoggingIn.value = true;
    try {
      final result = await Get.dialog<Object?>(const BilibiliLoginDialog(), barrierDismissible: false);

      if (result is LoginResult) {
        await controller.refreshBilibiliLoginState();
        final who = result.nickname?.isNotEmpty == true ? result.nickname! : '哔哩哔哩账号';
        Get.snackbar('登录成功', '$who 已登录', snackPosition: SnackPosition.BOTTOM);
      } else if (result is String) {
        Get.snackbar('登录失败', result, snackPosition: SnackPosition.BOTTOM);
      }
    } finally {
      controller.isBilibiliLoggingIn.value = false;
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
