import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:ym_live_stream/features/live_site_meta.dart';
import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

class LiveSearchBar extends StatelessWidget {
  final HomeController controller;

  final double width;

  /// 单行时的高度（也是右侧按钮的高度、输入框的最小高度）
  static const double height = 40;

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final finalWidth = available.isFinite ? (width < available ? width : available) : width;

        return SizedBox(
          width: finalWidth,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildTextField()),
              const SizedBox(width: _gap),

              _buildSiteDropdown(context),
              const SizedBox(width: _gap),

              _buildSearchButton(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextField() {
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
          if (controller.searchError.value != null) controller.searchError.value = null;
        },

        maxLines: null,
        minLines: 1,
        keyboardType: TextInputType.text,
        scrollPadding: const EdgeInsets.all(20),

        decoration: InputDecoration(
          isDense: true,
          contentPadding: _inputPadding,
          hintText: '输入直播间链接或房间号',
          hintStyle: const TextStyle(color: Color(0xFF999999), fontSize: 13),
          filled: true,
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
    return Obx(() {
      final current = controller.selectedSite.value;
      return SizedBox(
        width: _siteBoxWidth,
        height: height,
        child: PopupMenuButton<LiveSiteMeta>(
          tooltip: current.displayName,
          onSelected: controller.selectSite,
          padding: EdgeInsets.zero,
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
      errorBuilder: (context, error, stackTrace) => Icon(Icons.live_tv, size: size, color: const Color(0xFF666666)),
    );
  }

  Widget _buildSearchButton() {
    return Obx(
      () => SizedBox(
        width: _searchButtonWidth,
        height: height,
        child: TextButton(
          onPressed: controller.isSearching.value ? null : () => controller.submitSearch(),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: Colors.transparent,
            foregroundColor: const Color(0xFF333333),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: controller.isSearching.value
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3D7EFF)))
              : const Icon(Icons.search, size: 22),
        ),
      ),
    );
  }
}
