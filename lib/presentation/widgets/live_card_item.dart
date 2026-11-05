import 'package:flutter/material.dart';

import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

/// 独立的名片组件。
///
/// 结构：
///   左 1/4：头像（网络图）
///   右 3/4：上下平分
///     上：用户名 + 开播状态
///     下：房间标题
///
/// 用 flex 1:3 而不是硬编码像素，卡片缩放时比例才保持 1/4。
class LiveCardItem extends StatelessWidget {
  final CardItemData item;
  final VoidCallback? onTap;

  const LiveCardItem({super.key, required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      // 背景图是浅色，卡片用半透明白 + 阴影，保证文字可读
      color: Colors.white.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(10),
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------- 左：头像，占 1/4 ----------
            Expanded(flex: 1, child: _buildAvatar()),

            // ---------- 右：上层按内容自适应，下层占满剩余 ----------
            Expanded(
              flex: 3,
              child: Padding(
                // 卡片整体缩到 3/4 高（96→72），内边距与行间距一起收紧
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 上：用户名 + 直播状态
                    //
                    // 【不能再用 Expanded 平分】原来上下两块各 flex:1，卡片 77 高时
                    // 减掉 padding 和分隔线只剩 66，每块 33px；而这块的内容是
                    // 「12 号用户名 ≈16px + 间距 2 + 状态徽标 ≈15px」= 33px，
                    // 正好压在临界点上，字体度量稍有差异就报
                    // "bottom overflowed by 3.0 pixels"。
                    // 这块本来高度就确定，改成按内容自然高度，不参与平分。
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF222222), fontSize: 12, fontWeight: FontWeight.bold, height: 1.1),
                        ),
                        const SizedBox(height: 2),
                        _buildStatusBadge(),
                      ],
                    ),

                    const Divider(height: 1, color: Color(0x1A000000)),

                    // 下：房间标题，占满剩下的所有空间
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          item.roomTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF666666), fontSize: 11, height: 1.15),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return Image.network(
      item.avatarUrl,
      fit: BoxFit.cover,
      // 网络图必须给兜底，否则加载失败会显示刺眼的报错图标
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const ColoredBox(
          color: Color(0xFFF0F0F0),
          child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
        );
      },
      errorBuilder: (context, error, stackTrace) => const ColoredBox(
        color: Color(0xFFF0F0F0),
        child: Center(child: Icon(Icons.person, color: Color(0xFFBBBBBB), size: 22)),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final (text, color) = switch (item.status) {
      LiveStatus.live => ('直播中', const Color.fromARGB(255, 20, 223, 81)),
      LiveStatus.offline => ('未开播', const Color(0xFF9E9E9E)),
      LiveStatus.banned => ('被封禁', const Color(0xFFB00020)),
      LiveStatus.unknown => ('状态未知', const Color(0xFFBDBDBD)),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        // height 收一下行高：默认行高会按字体度量留出额外空间，
        // 卡片高度很紧，这里每省一点都能避免整块超出去
        Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.1)),
      ],
    );
  }
}
