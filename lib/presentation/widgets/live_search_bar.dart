import 'package:flutter/material.dart';

import 'package:ym_live_stream/features/live_site_meta.dart';
import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

/// 搜索栏：文本输入框 + 平台下拉 + 放大镜按钮。
///
/// 布局（按需求）：
///   [ 文本输入框 ][ 平台图标下拉 ][ 放大镜 ]
///
/// 【输入框会随内容长高】抖音分享文本动辄上百字符
/// （`1- #在抖音，记录美好生活#【xxx】正在直播…… https://v.douyin.com/xxx/ 7@0.com :9pm`），
/// 原来输入框是定高 40 的单行 TextField，超出的部分直接被横向裁掉，
/// 手机上只能看到开头几个字，根本没法确认自己粘了什么。
/// 现在改成多行自适应：从一行的高度起，内容多了整条搜索栏往上长，
/// 长到上限后内部滚动（不无限长高去挤压下方的名片网格）。
///
/// 右侧「平台下拉」「放大镜」不跟着长高，始终对齐输入框的**第一行**。
class LiveSearchBar extends StatelessWidget {
  final HomeController controller;

  /// 整条搜索栏的目标宽度（三个组件加起来 = 这个宽度）。
  ///
  /// 【这是「上限」不是「固定值」】原来这里直接当固定宽用，
  /// 而默认值是 520 —— 手机上屏幕宽度往往只有 360~420，
  /// 520 的 Row 塞进 360 的容器里，三个组件就会互相挤压重叠，
  /// 表现就是「登录框都挤在一起」。
  /// 现在由 LayoutBuilder 拿父级实际可用宽度，取 min(width, 可用宽度)，
  /// 桌面保持 520 的原样，手机自动缩到屏幕宽。
  final double width;

  /// 单行时的高度（也是右侧按钮的高度、输入框的最小高度）
  static const double height = 40;

  /// 输入框最多长到多少高（约 5~6 行）。
  ///
  /// 为什么要有上限：搜索区在上半部分、下面是 Expanded 的名片网格，
  /// 这里的 Column 是 mainAxisSize.min 的，输入框无限长高会把
  /// 上方 Expanded 分到的空间吃干净，名片区被挤没。
  /// 超过这个高度就让 TextField 自己滚动（外层还有 SingleChildScrollView 兜底）。
  ///
  /// 取 140 的依据：手机的输入框可用宽度约 300 逻辑像素、字号 13，
  /// 一行约 25~30 个字；抖音分享文本大约 100~150 字，
  /// 140 高差不多能一次看全 5~6 行，正好覆盖整段分享文本。
  static const double maxInputHeight = 140;

  /// 平台下拉框宽度：只显示图标，所以做得比较窄
  static const double _siteBoxWidth = 56;

  /// 搜索按钮宽度
  static const double _searchButtonWidth = 44;

  /// 组件之间的水平间距
  static const double _gap = 8;

  /// 平台图标尺寸
  static const double _siteIconSize = 22;

  /// 输入框内边距：上下留 10，让单行时文字大致落在 40 高的中线上
  static const EdgeInsets _inputPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  const LiveSearchBar({super.key, required this.controller, this.width = 520});

  @override
  Widget build(BuildContext context) {
    // 【高度不再写死】原来外层是 SizedBox(height: 40)，
    // 现在只给宽度，高度由输入框自己的行数决定（见 _buildTextField）。
    // 行高变了整条 Row 跟着变高，父级 Align(bottomCenter) 会自动把它往上推。
    return LayoutBuilder(
      builder: (context, constraints) {
        // 取「目标宽度」和「父级可用宽度」的较小值。
        // 父级约束可能是无限的（放在某些 Row 里），那种情况直接用 width。
        final available = constraints.maxWidth;
        final finalWidth = available.isFinite ? (width < available ? width : available) : width;

        return SizedBox(
          width: finalWidth,
          child: Row(
            // 【顶部对齐，不再 stretch】
            // 输入框长高后，右侧两个按钮必须留在第一行，
            // 用 stretch 会把它们拉成和输入框一样高，看着像个巨大的方块。
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- 文本输入框（占剩余宽度）----------
              Expanded(child: _buildTextField()),
              const SizedBox(width: _gap),

              // ---------- 平台下拉框（只显示图标）----------
              _buildSiteDropdown(context),
              const SizedBox(width: _gap),

              // ---------- 搜索按钮（放大镜，透明背景）----------
              _buildSearchButton(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextField() {
    // 【封顶】TextField 设成 maxLines: null 后不会自己停止长高，
    // 必须由外部给一个 maxHeight，超出的部分才会变成内部滚动。
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: height,
        maxHeight: maxInputHeight,
      ),
      child: TextField(
        controller: controller.searchTextController,
        style: const TextStyle(color: Color(0xFF333333), fontSize: 13),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => controller.submitSearch(),
        onChanged: (_) {
          // 用户重新输入时清掉上一次的报错
          if (controller.searchError != null) controller.searchError = null;
        },

        // 【自适应高度的核心三行】
        // maxLines: null + minLines: 1 —— 从 1 行起，内容多一行就长高一行；
        // 配合外层 ConstrainedBox(maxHeight) 封顶，超过就内部滚动。
        // 注意不能设 maxLines: 1（原来的行为），那会把多出来的文字横向裁掉。
        maxLines: null,
        minLines: 1,
        // 用 text 而不是 multiline：multiline 会让部分手机键盘把回车键渲染成「换行」，
        // 按下去不触发 onSubmitted，用户得去点放大镜。
        // 这里的主要用途是「让长内容能显示出来」，不是让用户手打换行，
        // 所以回车仍然要能直接搜索。
        keyboardType: TextInputType.text,
        // 滚动由 TextField 自己接管，长文本能上下翻
        scrollPadding: const EdgeInsets.all(20),

        decoration: InputDecoration(
          isDense: true,
          // 上下等高 -> 单行时文字在中线
          contentPadding: _inputPadding,
          hintText: '输入直播间链接或房间号',
          hintStyle: const TextStyle(color: Color(0xFF999999), fontSize: 13),
          filled: true,
          // 背景图偏浅，输入框用半透明白 + 边框，保证文字可读
          fillColor: Colors.white.withValues(alpha: 0.85),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x33000000)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF3D7EFF), width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _buildSiteDropdown(BuildContext context) {
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final current = controller.selectedSite;
      return SizedBox(
        width: _siteBoxWidth,
        height: height,
        child: PopupMenuButton<LiveSiteMeta>(
          tooltip: current.displayName,
          onSelected: controller.selectSite,
          padding: EdgeInsets.zero,
          // 下拉菜单项仍带名字，方便选择；触发按钮上只显示图标
          itemBuilder: (context) => LiveSites.all
              .map(
                (meta) => PopupMenuItem<LiveSiteMeta>(
                  value: meta,
                  child: Row(children: [_siteIcon(meta, size: 18), const SizedBox(width: 8), Text(meta.displayName)]),
                ),
              )
              .toList(),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33000000)),
            ),
            // 只放图标 + 一个小箭头，居中排布
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _siteIcon(current, size: _siteIconSize),
                const Icon(Icons.arrow_drop_down, color: Color(0xFF666666), size: 16),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _siteIcon(LiveSiteMeta meta, {double size = 18}) {
    return Image.asset(
      meta.iconAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      // 缺图标时兜底，避免下拉框里出现红叉
      errorBuilder: (context, error, stackTrace) => Icon(Icons.live_tv, size: size, color: const Color(0xFF666666)),
    );
  }

  Widget _buildSearchButton() {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SizedBox(
        width: _searchButtonWidth,
        height: height,
        child: TextButton(
          onPressed: controller.isSearching ? null : () => controller.submitSearch(),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            // 透明背景，只留放大镜图标
            backgroundColor: Colors.transparent,
            foregroundColor: const Color(0xFF333333),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: controller.isSearching
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3D7EFF)))
              : const Icon(Icons.search, size: 22),
        ),
      ),
    );
  }
}
