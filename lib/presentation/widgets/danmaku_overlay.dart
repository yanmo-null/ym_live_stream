import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:ym_live_stream/features/danmaku_message.dart';

class DanmakuOverlay extends StatelessWidget {
  static const double _kTextAlpha = 0.72;

  /// 要显示的弹幕（按时间顺序，最新的在末尾）
  final List<DanmakuMessage> messages;

  /// 最多同时显示几条
  final int maxLines;

  /// 字号。自适应逻辑见 [resolveFontSize]
  final double fontSize;

  const DanmakuOverlay({super.key, required this.messages, this.maxLines = 6, required this.fontSize});

  static double resolveFontSize({
    required Size videoSize,
    double base = 13,
    double min = 13,
    double max = 26,
    double devicePixelRatio = 1,
  }) {
    final shorterSide = math.min(videoSize.width, videoSize.height);
    if (shorterSide <= 0) return base;

    final dprBoost = math.sqrt(devicePixelRatio).clamp(1.0, 1.6);

    final scale = shorterSide / 720.0;
    return (base * scale * dprBoost).clamp(min, max);
  }

  @override
  Widget build(BuildContext context) {
    final visible = messages.length <= maxLines ? messages : messages.sublist(messages.length - maxLines);

    final lineHeight = fontSize * 1.85;

    return IgnorePointer(
      child: SizedBox(
        height: maxLines * lineHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final msg in visible)
              SizedBox(
                height: lineHeight,
                child: Align(alignment: Alignment.centerLeft, child: _buildItem(msg, lineHeight)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(DanmakuMessage msg, double lineHeight) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.62, vertical: fontSize * 0.22),
      constraints: BoxConstraints(maxHeight: lineHeight),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '${msg.nickname}：',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFF7FB8FF).withValues(alpha: _kTextAlpha),
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                height: 1.25,
                shadows: [Shadow(color: Colors.black.withValues(alpha: _kTextAlpha), blurRadius: 4)],
              ),
            ),
          ),
          Flexible(
            child: Text(
              msg.content,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                color: Colors.white.withValues(alpha: _kTextAlpha),
                fontSize: fontSize,
                height: 1.25,
                shadows: [Shadow(color: Colors.black.withValues(alpha: _kTextAlpha), blurRadius: 4)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
