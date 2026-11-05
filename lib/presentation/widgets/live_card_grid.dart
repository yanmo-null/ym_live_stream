import 'package:flutter/material.dart';

import 'package:ym_live_stream/presentation/controller/home_page_control.dart';
import 'package:ym_live_stream/presentation/widgets/live_card_item.dart';

/// 名片网格。
///
/// 列数不写死 4：用 maxCrossAxisExtent 按“最小卡片宽度”自动算列数，
/// 这样初始窗口宽度下正好 4 列，窗口拉大自动增列，放不下自动换行。
/// （需求里的“横向 4 个、纵向 3 个”是初始窗口尺寸下的表现，不是固定值）
class LiveCardGrid extends StatelessWidget {
  final List<CardItemData> items;
  final void Function(CardItemData item)? onTapItem;
  final EdgeInsetsGeometry padding;
  final double spacing;

  /// 单张卡片的最小宽度，决定列数
  final double minCardWidth;

  /// 单张卡片的固定高度
  final double cardHeight;

  /// 是否按内容收缩高度、自己不滚动。
  ///
  /// 关注页是按平台分组显示的，每个平台的网格被放进外层 ListView 里；
  /// 此时 GridView 不能再自己滚动（会被父级的无限高度约束顶错），
  /// 要 shrinkWrap: true + NeverScrollableScrollPhysics，把滚动交给外层。
  final bool shrinkWrap;

  /// 空列表时显示的提示语。
  ///
  /// 主页是「还没有特别关注的直播间」、关注页是「还没有关注的直播间」，
  /// 两处语义不同，不能共用一句写死的文案。
  final String emptyText;

  const LiveCardGrid({
    super.key,
    required this.items,
    this.onTapItem,
    this.padding = const EdgeInsets.all(16),
    // 间距跟着卡片一起收一点，否则卡片小了、缝还是原来的，会显得稀
    this.spacing = 9,
    // 卡片等比缩小到原来的 3/4（260→195、96→72），在此基础上宽高各加 5：195→200、72→77
    this.minCardWidth = 200,
    this.cardHeight = 77,
    this.shrinkWrap = false,
    this.emptyText = '还没有特别关注的直播间',
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return _buildEmpty();

    // 窄屏（手机）把内边距和间距一起收小：
    // 卡片本身保持 200 宽不变，靠减少留白让手机能放下 1~2 列。
    final compact = MediaQuery.sizeOf(context).width < 600;
    final effectivePadding = compact ? const EdgeInsets.all(8) : padding;
    final effectiveSpacing = compact ? 8.0 : spacing;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - effectivePadding.horizontal;
        // 至少 1 列，避免极窄窗口算出 0 导致除零；clamp 返回 num，显式转 int
        final columns = ((available + effectiveSpacing) / (minCardWidth + effectiveSpacing)).floor().clamp(1, 12).toInt();

        return GridView.builder(
          padding: effectivePadding,
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: effectiveSpacing,
            mainAxisSpacing: effectiveSpacing,
            mainAxisExtent: cardHeight,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return LiveCardItem(
              item: item,
              onTap: onTapItem == null ? null : () => onTapItem!(item),
            );
          },
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.inbox_outlined, size: 40, color: Color(0xFFBBBBBB)),
          const SizedBox(height: 10),
          Text(emptyText, style: const TextStyle(color: Color(0xFF999999), fontSize: 13)),
        ],
      ),
    );
  }
}
