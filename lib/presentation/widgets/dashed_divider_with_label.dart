import 'package:flutter/material.dart';

class DashedDividerWithLabel extends StatelessWidget {
  final String label;
  final Color color;
  final Color labelColor;
  final double dashWidth;
  final double dashSpace;
  final double strokeWidth;
  final double gap;

  /// 中间文字变成透明按钮（用于「收藏列表刷新」这类操作）
  final VoidCallback? onLabelTap;

  const DashedDividerWithLabel({
    super.key,
    required this.label,
    this.color = Colors.white24,
    this.labelColor = Colors.white70,
    this.dashWidth = 6,
    this.dashSpace = 4,
    this.strokeWidth = 1,
    this.gap = 12,
    this.onLabelTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _DashedLine(color: color, dashWidth: dashWidth, dashSpace: dashSpace, strokeWidth: strokeWidth)),
        _buildLabel(),
        Expanded(child: _DashedLine(color: color, dashWidth: dashWidth, dashSpace: dashSpace, strokeWidth: strokeWidth)),
      ],
    );
  }

  Widget _buildLabel() {
    final style = TextStyle(color: labelColor, fontSize: 14, fontWeight: FontWeight.w600);

    if (onLabelTap == null) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: gap),
        child: Text(label, style: style),
      );
    }

    return TextButton(
      onPressed: onLabelTap,
      style: TextButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: labelColor,
        padding: EdgeInsets.symmetric(horizontal: gap),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        overlayColor: labelColor.withValues(alpha: 0.12),
        shape: const StadiumBorder(),
      ),
      child: Text(label, style: style),
    );
  }
}

class _DashedLine extends StatelessWidget {
  final Color color;
  final double dashWidth;
  final double dashSpace;
  final double strokeWidth;

  const _DashedLine({
    required this.color,
    required this.dashWidth,
    required this.dashSpace,
    required this.strokeWidth,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite) return const SizedBox.shrink();
        return CustomPaint(
          size: Size(constraints.maxWidth, strokeWidth),
          painter: _DashedLinePainter(
            color: color,
            dashWidth: dashWidth,
            dashSpace: dashSpace,
            strokeWidth: strokeWidth,
          ),
        );
      },
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  final double dashWidth;
  final double dashSpace;
  final double strokeWidth;

  _DashedLinePainter({
    required this.color,
    required this.dashWidth,
    required this.dashSpace,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final y = size.height / 2;
    double x = 0;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dashWidth != dashWidth ||
      oldDelegate.dashSpace != dashSpace ||
      oldDelegate.strokeWidth != strokeWidth;
}
