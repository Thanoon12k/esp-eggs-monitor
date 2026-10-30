import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small line chart: one series over time, with an optional dashed target line.
class LineChart extends StatelessWidget {
  const LineChart({super.key, required this.points, required this.color, this.target, this.unit = ''});

  final List<(DateTime, double)> points;
  final Color color;
  final double? target;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall!;
    return SizedBox(
      height: 140,
      child: CustomPaint(
        painter: _ChartPainter(points, color, target, unit, style, Theme.of(context).colorScheme.outlineVariant),
        size: Size.infinite,
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.points, this.color, this.target, this.unit, this.style, this.grid);

  final List<(DateTime, double)> points;
  final Color color;
  final double? target;
  final String unit;
  final TextStyle style;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var lo = points.map((p) => p.$2).reduce(math.min);
    var hi = points.map((p) => p.$2).reduce(math.max);
    if (target != null) {
      lo = math.min(lo, target!);
      hi = math.max(hi, target!);
    }
    if (hi - lo < 1) {
      final mid = (hi + lo) / 2;
      lo = mid - 0.5;
      hi = mid + 0.5;
    }
    const labelW = 40.0;
    final w = size.width - labelW, h = size.height - 8;
    final t0 = points.first.$1.millisecondsSinceEpoch.toDouble();
    final span = math.max(1.0, points.last.$1.millisecondsSinceEpoch - t0);
    Offset at(DateTime t, double v) =>
        Offset((t.millisecondsSinceEpoch - t0) / span * w, 4 + (1 - (v - lo) / (hi - lo)) * h);

    // labels for min and max on the right
    for (final v in [hi, lo]) {
      final tp = TextPainter(
          text: TextSpan(text: '${v.toStringAsFixed(1)}$unit', style: style), textDirection: TextDirection.ltr)
        ..layout();
      final y = at(points.first.$1, v).dy;
      tp.paint(canvas, Offset(w + 6, (y - tp.height / 2).clamp(0, size.height - tp.height)));
      canvas.drawLine(Offset(0, y), Offset(w, y), Paint()..color = grid);
    }

    if (target != null) {
      final y = at(points.first.$1, target!).dy;
      final p = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1.5;
      for (var x = 0.0; x < w; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, w), y), p);
      }
    }

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = at(points[i].$1, points[i].$2);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.points != points || old.target != target;
}
