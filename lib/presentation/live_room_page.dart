import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ym_live_stream/core/route_path.dart';

import 'package:ym_live_stream/features/live_common.dart';
import 'package:ym_live_stream/features/live_site_meta.dart';

import 'controller/live_room_controller.dart';
import 'widgets/danmaku_overlay.dart';

class LiveStreamPage extends GetView<LiveStreamController> {
  const LiveStreamPage({super.key});

  static const Key _videoAreaKey = ValueKey<String>('live-video-area');

  /// 顶部导航栏高度（和 _buildTopNavigationBar 里的 height 保持一致）
  static const double _kTopBarHeight = 48;

  /// 视频下方操作栏高度（和 _buildVideoBottomToolbar 里的 height 保持一致）
  static const double _kBottomToolbarHeight = 40;

  /// 右侧栏宽度（和 _buildRightSidebar 里的 width 保持一致）
  static const double _kSidebarWidth = 320;

  /// 右侧弹幕列表的字号。
  static const double _kDanmakuFontSize = 15;

  /// 右侧弹幕列表的固定行高（含上下留白）。
  static const double _kDanmakuRowHeight = 27;

  static const double _kCompactVideoAspect = 16 / 9;

  static bool get _isCompactWidth {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return false;
    return view.physicalSize.width / view.devicePixelRatio < 600;
  }

  static bool get isMobilePlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

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
        LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(height: constraints.maxWidth / _kCompactVideoAspect, width: constraints.maxWidth);
          },
        ),
        _buildVideoBottomToolbar(),
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

    return _buildScaffold(context);
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        top: !controller.isFullscreen.value,
        bottom: !controller.isFullscreen.value,
        left: true,
        right: true,
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Obx(() {
      final loading = controller.isLoading.value;
      final info = controller.roomInfo.value;
      final err = controller.loadError.value;

      MediaQuery.sizeOf(context);

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

      final videoArea = _buildVideoPlayerArea(context, controller, info);

      final fullscreen = controller.isFullscreen.value || controller.isFitWindow.value;

      final compact = _isCompactWidth;

      return Stack(
        children: [
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

  Widget _buildTopNavigationBar(LiveRoomInfo roomInfo) {
    return Container(
      height: _kTopBarHeight,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back, size: 20), tooltip: '返回', onPressed: _handleBack),
          const SizedBox(width: 8),

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

  void _handleBack() {
    final navigator = Get.key.currentState;
    if (navigator != null && navigator.canPop()) {
      Get.back();
      return;
    }
    Get.offAllNamed(RoutePath.p_home);
  }

  Widget _buildPlatformIcon(LIVE_SITE_E? liveSite, {double size = 20}) {
    if (liveSite == null) {
      return Icon(Icons.live_tv, color: Colors.blueAccent, size: size);
    }

    return Image.asset(
      LiveSites.of(liveSite).iconAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Icon(Icons.live_tv, color: Colors.blueAccent, size: size);
      },
    );
  }

  Widget _buildVideoPlayerArea(BuildContext context, LiveStreamController controller, LiveRoomInfo roomInfo) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (controller.isFullscreen.value) {
            controller.toggleFullscreen();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          onHover: (event) => controller.setShowControls(true),
          onExit: (event) => controller.setShowControls(false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () {
              if (controller.isFullscreen.value) {
                controller.toggleFullscreen();
              }
            },
            child: _buildVideoStack(context, controller),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoStack(BuildContext context, LiveStreamController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoSize = Size(constraints.maxWidth, constraints.maxHeight);
        return _buildVideoStackBody(context, controller, videoSize);
      },
    );
  }

  Widget _buildVideoStackBody(BuildContext context, LiveStreamController controller, Size videoSize) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const SizedBox.expand(),

        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (!controller.videoSurfaceLaidOutNotified) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    controller.notifyVideoSurfaceLaidOut();
                  });
                }

                return Obx(() {
                  final tick = controller.textureRefreshTick.value;
                  controller.isFullscreen.value || controller.isFitWindow.value;

                  return Video(
                    key: ValueKey<int>(tick),
                    controller: controller.videoController,
                    fit: BoxFit.contain,
                    controls: (state) => const SizedBox.shrink(),
                    wakelock: false,
                  );
                });
              },
            ),
          ),
        ),

        Obx(() {
          final showOverlay = controller.isDanmakuOn.value && (controller.isFullscreen.value || controller.isFitWindow.value);
          if (!showOverlay) return const SizedBox.shrink();

          return Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Builder(
              builder: (context) {
                final fontSize = DanmakuOverlay.resolveFontSize(videoSize: videoSize, devicePixelRatio: MediaQuery.devicePixelRatioOf(context));

                return Obx(() {
                  if (!controller.isDanmakuOn.value) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: DanmakuOverlay(messages: controller.danmakuList.value, maxLines: 6, fontSize: fontSize),
                  );
                });
              },
            ),
          );
        }),

        Obx(() {
          final buffering = controller.isBuffering.value;
          final playing = controller.isPlaying.value;
          final playError = playing ? null : controller.playError.value;
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

        Obx(() {
          if (!controller.showControls.value) return const SizedBox.shrink();

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
      ],
    );
  }

  Widget _buildControlBarContent(BuildContext context, LiveStreamController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: available),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Obx(() => IconButton(icon: Icon(controller.isPlaying.value ? Icons.pause : Icons.play_arrow), onPressed: controller.togglePlay)),

                    Obx(() {
                      final overlayAvailable = controller.isFullscreen.value || controller.isFitWindow.value;
                      if (!overlayAvailable) return const SizedBox.shrink();

                      return IconButton(
                        icon: Icon(controller.isDanmakuOn.value ? Icons.subtitles : Icons.subtitles_off),
                        tooltip: controller.isDanmakuOn.value ? '关闭弹幕' : '开启弹幕',
                        onPressed: controller.toggleDanmaku,
                      );
                    }),
                  ],
                ),

                const SizedBox(width: 16),

                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildVolumeControl(context, controller),

                    const SizedBox(width: 8),

                    _buildQualityButton(controller),

                    _buildLineButton(controller),

                    if (!isMobilePlatform)
                      Obx(
                        () => IconButton(
                          icon: Icon(controller.isFitWindow.value ? Icons.zoom_in_map : Icons.fit_screen),
                          tooltip: controller.isFitWindow.value ? '退出适配窗口' : '适配窗口',
                          onPressed: controller.toggleFitWindow,
                        ),
                      ),
                    Obx(
                      () => IconButton(
                        icon: Icon(controller.isFullscreen.value ? Icons.fullscreen_exit : Icons.fullscreen),
                        tooltip: controller.isFullscreen.value ? '退出全屏' : '全屏',
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

  Widget _buildVolumeControl(BuildContext context, LiveStreamController controller) {
    final compact = _isCompactWidth;

    return Obx(() {
      final volume = controller.volume.value;
      final icon = volume <= 0
          ? Icons.volume_off
          : volume < 50
          ? Icons.volume_down
          : Icons.volume_up;

      if (compact) {
        return Builder(
          builder: (btnContext) =>
              IconButton(iconSize: 20, icon: Icon(icon), tooltip: '音量 ${volume.round()}', onPressed: () => _showVolumePopup(btnContext, controller)),
        );
      }

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

  Future<void> _showVolumePopup(BuildContext buttonContext, LiveStreamController controller) async {
    final buttonBox = buttonContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(buttonContext, rootOverlay: true).context.findRenderObject() as RenderBox?;
    if (buttonBox == null || !buttonBox.hasSize || overlay == null) return;

    const popupWidth = 64.0;
    const popupHeight = 200.0;
    const gap = 6.0;

    final size = buttonBox.size;
    final topLeft = buttonBox.localToGlobal(Offset.zero, ancestor: overlay);

    var left = topLeft.dx + (size.width - popupWidth) / 2;
    if (left < 0) left = 0;
    if (left + popupWidth > overlay.size.width) left = overlay.size.width - popupWidth;

    var bottom = topLeft.dy - gap;
    if (bottom - popupHeight < 0) {
      bottom = topLeft.dy + size.height + gap + popupHeight;
    }
    if (bottom > overlay.size.height) bottom = overlay.size.height - gap;

    controller.setQualityMenuOpen(true);
    try {
      await showMenu<void>(
        context: buttonContext,
        position: RelativeRect.fromLTRB(left, bottom - popupHeight, overlay.size.width - left - popupWidth, overlay.size.height - bottom),
        constraints: BoxConstraints.tightFor(width: popupWidth, height: popupHeight),
        color: Colors.white,
        items: [
          PopupMenuItem<void>(
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

  Widget _buildVolumePopupBody(LiveStreamController controller) {
    return Obx(() {
      final volume = controller.volume.value;

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

  static const double _kQualityItemHeight = 26;

  /// 下拉弹框与按钮之间留的缝隙（紧贴但不粘边）
  static const double _kQualityMenuGap = 2;

  /// 画质切换：按钮上显示当前画质，点开后在按钮**正上方**弹出与按钮等宽的菜单
  Widget _buildQualityButton(LiveStreamController controller) {
    return Obx(() {
      final qualities = controller.availableQualities;
      final current = controller.currentQuality;
      final switching = controller.isSwitchingQuality.value;

      final label = current == null ? '画质' : controller.qualityName(current);

      if (qualities.isEmpty) {
        return TextButton(
          onPressed: null,
          child: Text(label, style: const TextStyle(color: Colors.white54)),
        );
      }

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
    return Obx(() {
      final lines = controller.availableLines;
      final current = controller.currentLine;
      final switching = controller.isSwitchingQuality.value;

      final label = lines.isEmpty ? '线路' : controller.lineName(current);

      if (lines.length <= 1) {
        return TextButton(
          onPressed: null,
          child: Text(label, style: const TextStyle(color: Colors.white54)),
        );
      }

      return Builder(
        builder: (buttonContext) => InkWell(
          onTap: switching
              ? null
              : () => _showAnchoredMenu<int>(
                  buttonContext: buttonContext,
                  controller: controller,
                  options: List<int>.generate(lines.length, (i) => i),
                  current: current,
                  labelOf: (i) => '线路${i + 1}',
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

    final menuHeight = options.length * _kQualityItemHeight;
    var menuBottom = topLeft.dy - _kQualityMenuGap;
    if (menuBottom - menuHeight < 0) {
      menuBottom = topLeft.dy + size.height + _kQualityMenuGap + menuHeight;
    }
    if (menuBottom > overlay.size.height) {
      menuBottom = overlay.size.height - _kQualityMenuGap;
    }

    controller.setQualityMenuOpen(true);
    T? selected;
    try {
      selected = await showMenu<T>(
        context: buttonContext,
        position: RelativeRect.fromLTRB(topLeft.dx, menuBottom - menuHeight, overlay.size.width - topLeft.dx - size.width, overlay.size.height - menuBottom),
        constraints: BoxConstraints.tightFor(width: size.width),
        color: Colors.white,
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
                        color: option == current ? const Color(0xFF1976D2) : Colors.black87,
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
      controller.setQualityMenuOpen(false);
    }

    if (selected != null) {
      await onSelected(selected);
    }
  }

  Widget _buildVideoBottomToolbar() {
    final compact = _isCompactWidth;
    final barHeight = compact ? 48.0 : _kBottomToolbarHeight;
    final gap = compact ? 20.0 : 16.0;

    return Container(
      height: barHeight,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: available),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildFavoriteAction(),
                      SizedBox(width: gap),
                      _buildSpecialFollowAction(),
                      SizedBox(width: gap),
                      _buildBottomActionItem(Icons.refresh, '刷新', () => controller.refreshStream()),
                    ],
                  ),
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

  Widget _buildFavoriteAction() {
    return Obx(() {
      final favorited = controller.isFavorited.value;
      return _buildBottomActionItem(
        favorited ? Icons.favorite : Icons.favorite_border,
        favorited ? '已关注' : '关注',
        () => controller.toggleFavorite(),
        color: favorited ? const Color(0xFFE53935) : null,
      );
    });
  }

  Widget _buildSpecialFollowAction() {
    return Obx(() {
      final special = controller.isSpecialFollowed.value;
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
    final iconSize = compact ? 18.0 : 14.0;
    final fontSize = compact ? 13.0 : 12.0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 0, vertical: compact ? 6 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: color ?? Colors.black54),
            SizedBox(width: compact ? 6 : 4),
            Text(
              label,
              style: TextStyle(fontSize: fontSize, color: color ?? Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCopyStreamUrl() async {
    final url = await controller.get_clarity_vido_play_url();

    if (url.isEmpty) {
      Get.snackbar(
        '直链',
        '暂时取不到播放地址（可能还在加载，或当前清晰度没有可用线路）',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: url));
    Get.snackbar(
      '直链已复制',
      url.length > 60 ? '${url.substring(0, 60)}…' : url,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 3),
    );
  }

  Widget _buildRightSidebar(LiveRoomInfo roomInfo, {bool fillWidth = false}) {
    return Container(
      width: fillWidth ? double.infinity : _kSidebarWidth,
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/background/danmaku_background.jpg'),
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.82)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                        Text(
                          roomInfo.owner_name ?? '未知主播',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 4),

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

            Container(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: Row(children: [_buildTabItem('互动', true), _buildTabItem('醒目留言(3)', false), _buildTabItem('设置与屏蔽', false)]),
            ),

            Expanded(child: _buildDanmakuList()),
          ],
        ),
      ),
    );
  }

  Widget _buildDanmakuList() {
    return Obx(() {
      final list = controller.danmakuList;
      final status = controller.danmakuStatus.value;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: [
                  Icon(
                    controller.danmakuConnected.value ? Icons.cloud_done : Icons.cloud_queue,
                    size: 13,
                    color: controller.danmakuConnected.value ? Colors.greenAccent : Colors.amber,
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
                    child: Text('暂无弹幕', style: TextStyle(fontSize: 12, color: Colors.black38)),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: list.length,
                    itemExtent: _kDanmakuRowHeight,
                    itemBuilder: (context, index) {
                      final msg = list[list.length - 1 - index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6.0),
                        child: RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
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
            color: isActive ? Colors.blueAccent : Colors.black54,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
