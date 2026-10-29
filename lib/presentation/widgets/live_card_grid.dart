import 'package:flutter/material.dart';

import 'package:ym_live_stream/presentation/controller/home_page_control.dart';
import 'package:ym_live_stream/presentation/widgets/live_card_item.dart';

class LiveCardGrid extends StatelessWidget {
  final List<CardItemData> items;
  final void Function(CardItemData item)? onTapItem;
  final EdgeInsetsGeometry padding;
  final double spacing;

  /// 单张卡片的最小宽度，决定列数
  final double minCardWidth;

  /// 单张卡片的固定高度
  final double cardHeight;

  final bool shrinkWrap;

  final String emptyText;

  const LiveCardGrid({
    super.key,
    required this.items,
    this.onTapItem,
    this.padding = const EdgeInsets.all(16),
    this.spacing = 9,
    this.minCardWidth = 200,
    this.cardHeight = 77,
    this.shrinkWrap = false,
    this.emptyText = '还没有特别关注的直播间',
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return _buildEmpty();

    final compact = MediaQuery.sizeOf(context).width < 600;
    final effectivePadding = compact ? const EdgeInsets.all(8) : padding;
    final effectiveSpacing = compact ? 8.0 : spacing;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - effectivePadding.horizontal;
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
