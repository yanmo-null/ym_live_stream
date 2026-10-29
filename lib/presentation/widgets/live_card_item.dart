import 'package:flutter/material.dart';

import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

class LiveCardItem extends StatelessWidget {
  final CardItemData item;
  final VoidCallback? onTap;

  const LiveCardItem({super.key, required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(10),
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 1, child: _buildAvatar()),

            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
        Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.1)),
      ],
    );
  }
}
