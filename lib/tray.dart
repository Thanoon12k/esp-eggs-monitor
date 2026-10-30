import 'dart:math';

import 'package:flutter/material.dart';

import 'models.dart';

/// What happened to one egg.
enum EggStatus { incubating, hatched, dead, clear, broken }

/// One status per egg, scattered over the tray the same way every time (seeded by the batch id),
/// like a real tray where chicks and losses are spread around.
List<EggStatus> eggsOf(Batch b) {
  final list = [
    for (var i = 0; i < b.hatched; i++) EggStatus.hatched,
    for (var i = 0; i < b.dead; i++) EggStatus.dead,
    for (var i = 0; i < b.clear; i++) EggStatus.clear,
    for (var i = 0; i < b.broken; i++) EggStatus.broken,
  ];
  final total = max(b.eggs, list.length);
  while (list.length < total) {
    list.add(EggStatus.incubating);
  }
  list.shuffle(Random(b.id.hashCode));
  return list;
}

/// Eggs sitting in cardboard trays of [perTray] (6 across), drawn with light and shadow.
class EggTray extends StatelessWidget {
  const EggTray({super.key, required this.eggs, this.columns = 6, this.maxEggs, this.perTray = 30});

  final List<EggStatus> eggs;
  final int columns;
  final int? maxEggs; // preview: show only the first tray
  final int perTray;

  @override
  Widget build(BuildContext context) {
    final shown = maxEggs == null ? eggs : eggs.take(maxEggs!).toList();
    final trays = <List<EggStatus>>[
      for (var i = 0; i < max(1, shown.length); i += perTray)
        shown.sublist(i, min(i + perTray, shown.length)),
    ];
    final more = eggs.length - shown.length;
    return LayoutBuilder(builder: (context, c) {
      final cell = c.maxWidth / columns;
      return Column(children: [
        for (final t in trays) ...[
          SizedBox(
            width: c.maxWidth,
            height: cell * max(1, (t.length / columns).ceil()) * 1.08 + 8,
            child: CustomPaint(painter: _TrayPainter(t, columns)),
          ),
          const SizedBox(height: 8),
        ],
        if (more > 0)
          Text('+$more', style: Theme.of(context).textTheme.labelLarge),
      ]);
    });
  }
}

class _TrayPainter extends CustomPainter {
  _TrayPainter(this.eggs, this.columns);
  final List<EggStatus> eggs;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    // Cardboard tray
    final tray = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18));
    canvas.drawRRect(
      tray,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF1DDBA), Color(0xFFDDBF90)],
        ).createShader(tray.outerRect),
    );
    canvas.drawRRect(tray.deflate(1), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0x22000000));

    final cellW = size.width / columns;
    final rows = max(1, (eggs.length / columns).ceil());
    final cellH = (size.height - 8) / rows;
    for (var i = 0; i < eggs.length; i++) {
      final cx = cellW * (i % columns + 0.5);
      final cy = 4 + cellH * (i ~/ columns + 0.5);
      // Cup in the tray
      final cup = Rect.fromCenter(center: Offset(cx, cy + cellH * 0.12), width: cellW * 0.82, height: cellH * 0.62);
      canvas.drawOval(
        cup,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(0, -0.3),
            colors: [Color(0xFFC9A673), Color(0xFFE6CDA3)],
          ).createShader(cup),
      );
      drawEgg(canvas, Offset(cx, cy), cellW * 0.56, eggs[i]);
    }
  }

  @override
  bool shouldRepaint(covariant _TrayPainter old) => old.eggs != eggs || old.columns != columns;
}

/// Egg outline: rounder at the bottom, narrower at the top.
Path eggPath(Offset c, double w) {
  final h = w * 1.28;
  final top = c.dy - h / 2, bottom = c.dy + h / 2;
  final l = c.dx - w / 2, r = c.dx + w / 2;
  final mid = c.dy + h * 0.1;
  return Path()
    ..moveTo(c.dx, top)
    ..cubicTo(c.dx + w * 0.36, top, r, mid - h * 0.32, r, mid)
    ..cubicTo(r, bottom - h * 0.02, c.dx + w * 0.28, bottom, c.dx, bottom)
    ..cubicTo(c.dx - w * 0.28, bottom, l, bottom - h * 0.02, l, mid)
    ..cubicTo(l, mid - h * 0.32, c.dx - w * 0.36, top, c.dx, top)
    ..close();
}

/// One egg with its status, centred at [c], [w] wide.
void drawEgg(Canvas canvas, Offset c, double w, EggStatus s) {
  final path = eggPath(c, w);
  final bounds = path.getBounds();

  // Soft shadow
  canvas.drawPath(
      path.shift(Offset(w * 0.05, w * 0.1)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.08));

  if (s == EggStatus.hatched) {
    _drawChick(canvas, c, w);
    return;
  }

  final (light, dark) = switch (s) {
    EggStatus.dead => (const Color(0xFF8C8279), const Color(0xFF4E4640)),
    EggStatus.clear => (const Color(0xFFFFFFFF), const Color(0xFFE4E1DC)),
    _ => (const Color(0xFFFFF8EC), const Color(0xFFE2C49B)),
  };
  canvas.drawPath(
    path,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.45),
        radius: 0.95,
        colors: [light, dark],
      ).createShader(bounds),
  );
  if (s == EggStatus.clear) {
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1, w * 0.04)
      ..color = const Color(0xFFB7B2AA));
  }
  // Shine
  canvas.drawOval(
    Rect.fromCenter(center: Offset(c.dx - w * 0.16, c.dy - w * 0.3), width: w * 0.2, height: w * 0.3),
    Paint()..color = Colors.white.withValues(alpha: s == EggStatus.dead ? 0.25 : 0.7),
  );
  if (s == EggStatus.dead) {
    final p = Paint()
      ..color = const Color(0xFFE57368)
      ..strokeWidth = max(1.5, w * 0.08)
      ..strokeCap = StrokeCap.round;
    final d = w * 0.16;
    canvas.drawLine(c.translate(-d, -d + w * 0.08), c.translate(d, d + w * 0.08), p);
    canvas.drawLine(c.translate(d, -d + w * 0.08), c.translate(-d, d + w * 0.08), p);
  }
  if (s == EggStatus.broken) {
    final crack = Path()
      ..moveTo(c.dx - w * 0.42, c.dy - w * 0.02)
      ..lineTo(c.dx - w * 0.22, c.dy + w * 0.12)
      ..lineTo(c.dx - w * 0.06, c.dy - w * 0.08)
      ..lineTo(c.dx + w * 0.1, c.dy + w * 0.14)
      ..lineTo(c.dx + w * 0.26, c.dy - w * 0.04)
      ..lineTo(c.dx + w * 0.42, c.dy + w * 0.08);
    canvas.drawPath(crack, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.2, w * 0.06)
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF6D5A45));
  }
}

void _drawChick(Canvas canvas, Offset c, double w) {
  final r = w * 0.5;
  final body = Rect.fromCircle(center: c.translate(0, w * 0.08), radius: r);
  canvas.drawOval(
    body,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.3, -0.4),
        colors: [Color(0xFFFFEB8A), Color(0xFFF7B928)],
      ).createShader(body),
  );
  // tuft
  canvas.drawCircle(c.translate(0, -r * 0.9), r * 0.18, Paint()..color = const Color(0xFFF7C22E));
  final eye = Paint()..color = const Color(0xFF3B2A1E);
  canvas.drawCircle(c.translate(-r * 0.32, -r * 0.05), max(1.2, r * 0.1), eye);
  canvas.drawCircle(c.translate(r * 0.32, -r * 0.05), max(1.2, r * 0.1), eye);
  canvas.drawPath(
    Path()
      ..moveTo(c.dx - r * 0.18, c.dy + r * 0.12)
      ..lineTo(c.dx + r * 0.18, c.dy + r * 0.12)
      ..lineTo(c.dx, c.dy + r * 0.38)
      ..close(),
    Paint()..color = const Color(0xFFF07A2A),
  );
  // the shell it came out of
  final shell = Path()
    ..moveTo(c.dx - r * 1.0, c.dy + r * 0.45)
    ..lineTo(c.dx - r * 0.6, c.dy + r * 0.3)
    ..lineTo(c.dx - r * 0.3, c.dy + r * 0.55)
    ..lineTo(c.dx, c.dy + r * 0.32)
    ..lineTo(c.dx + r * 0.3, c.dy + r * 0.55)
    ..lineTo(c.dx + r * 0.6, c.dy + r * 0.3)
    ..lineTo(c.dx + r * 1.0, c.dy + r * 0.45)
    ..arcToPoint(Offset(c.dx - r * 1.0, c.dy + r * 0.45), radius: Radius.circular(r * 1.05))
    ..close();
  canvas.drawPath(shell, Paint()..color = const Color(0xFFFFF4E2));
}

/// A single egg as an icon (for legends and headers).
class EggIcon extends StatelessWidget {
  const EggIcon(this.status, {super.key, this.size = 22});
  final EggStatus status;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size * 1.3,
        child: CustomPaint(painter: _EggIconPainter(status)),
      );
}

class _EggIconPainter extends CustomPainter {
  _EggIconPainter(this.s);
  final EggStatus s;

  @override
  void paint(Canvas canvas, Size size) => drawEgg(canvas, size.center(Offset.zero), size.width * 0.86, s);

  @override
  bool shouldRepaint(covariant _EggIconPainter old) => old.s != s;
}
