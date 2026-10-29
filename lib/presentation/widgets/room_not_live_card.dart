import 'package:flutter/material.dart';

import 'package:ym_live_stream/features/favorite_store.dart';
import 'package:ym_live_stream/features/live_common.dart';
import 'package:ym_live_stream/features/live_site_meta.dart';
import 'package:ym_live_stream/presentation/controller/home_page_control.dart';

class RoomNotLiveCard extends StatefulWidget {
  final BlockedRoomInfo data;

  /// 关闭回调（由页面负责关掉 dialog）
  final VoidCallback onClose;

  const RoomNotLiveCard({super.key, required this.data, required this.onClose});

  @override
  State<RoomNotLiveCard> createState() => _RoomNotLiveCardState();
}

class _RoomNotLiveCardState extends State<RoomNotLiveCard> {
  bool _favorited = false;
  bool _special = false;

  @override
  void initState() {
    super.initState();
    _syncState();
  }

  void _syncState() {
    final store = FavoriteStore.instance;
    final id = widget.data.roomId;
    final site = widget.data.site;
    setState(() {
      _favorited = store.contains(site, id);
      _special = _favorited && store.isSpecialFollowed(site, id);
    });
  }

  Future<void> _toggleFavorite() async {
    final store = FavoriteStore.instance;
    final id = widget.data.roomId;
    final site = widget.data.site;

    if (_favorited) {
      await store.remove(site, id);
    } else {
      await store.add(
        FavoriteRoom(
          roomId: id,
          roomName: widget.data.roomName,
          ownerName: widget.data.ownerName,
          ownerProfileUrl: widget.data.ownerProfileUrl,
          site: site,
          specialFollowed: false,
        ),
      );
    }
    _syncState();
  }

  Future<void> _toggleSpecial() async {
    final store = FavoriteStore.instance;
    final id = widget.data.roomId;
    final site = widget.data.site;

    if (!_favorited) {
      await store.add(
        FavoriteRoom(
          roomId: id,
          roomName: widget.data.roomName,
          ownerName: widget.data.ownerName,
          ownerProfileUrl: widget.data.ownerProfileUrl,
          site: site,
          specialFollowed: true,
        ),
      );
    } else {
      await store.setSpecialFollowed(site, id, !_special);
    }
    _syncState();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 330,
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildAvatar(),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.ownerName.isEmpty ? '未知主播' : data.ownerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF222222)),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildPlatformIcon(data.site, size: 12),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          LiveSites.of(data.site).displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _buildStatusBadge(),
                ],
              ),
            ),

            const SizedBox(width: 10),

            SizedBox(
              width: 100,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSmallButton(
                    icon: _favorited ? Icons.favorite : Icons.favorite_border,
                    label: _favorited ? '已关注' : '关注',
                    color: _favorited ? const Color(0xFFE53935) : const Color(0xFF666666),
                    onPressed: _toggleFavorite,
                  ),
                  const SizedBox(height: 6),
                  _buildSmallButton(
                    icon: _special ? Icons.star : Icons.star_border,
                    label: _special ? '已特别关注' : '特别关注',
                    color: _special ? const Color(0xFFFFA000) : const Color(0xFF666666),
                    onPressed: _toggleSpecial,
                  ),
                  const SizedBox(height: 6),
                  _buildSmallButton(
                    label: '关闭',
                    color: const Color(0xFF999999),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 紧凑描边按钮：定高 26，字号 12，宽度由外层 stretch 拉齐
  Widget _buildSmallButton({IconData? icon, required String label, required Color color, required VoidCallback onPressed}) {
    return SizedBox(
      height: 26,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 13), const SizedBox(width: 3)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    const size = 42.0;
    final url = widget.data.ownerProfileUrl;

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? _buildAvatarPlaceholder()
            : Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return _buildAvatarPlaceholder(child: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)));
                },
                errorBuilder: (context, error, stackTrace) => _buildAvatarPlaceholder(),
              ),
      ),
    );
  }

  Widget _buildAvatarPlaceholder({Widget? child}) {
    return ColoredBox(
      color: const Color(0xFFF0F0F0),
      child: Center(child: child ?? const Icon(Icons.person, color: Color(0xFFBBBBBB), size: 22)),
    );
  }

  Widget _buildPlatformIcon(LIVE_SITE_E site, {double size = 12}) {
    return Image.asset(
      LiveSites.of(site).iconAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => Icon(Icons.live_tv, color: Colors.blueAccent, size: size),
    );
  }

  /// 直播状态徽标：文案和配色与收藏卡一致
  Widget _buildStatusBadge() {
    final (text, color) = switch (widget.data.showStatus) {
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_LIVE => ('直播中', const Color.fromARGB(255, 20, 223, 81)),
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_OFFLINE => ('未开播', const Color(0xFF9E9E9E)),
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_BAN => ('被封禁', const Color(0xFFB00020)),
      LIVE_SHOW_STATUS_E.LIVE_SHOW_STATUS_UNKNOWN => ('状态未知', const Color(0xFFBDBDBD)),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600, height: 1.1)),
      ],
    );
  }
}
