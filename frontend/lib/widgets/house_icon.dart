import 'package:flutter/material.dart';

/// A standalone, 100% reliable vector House Icon (รูปบ้าน)
/// Drawn via Canvas path so it never depends on font asset loading,
/// font caching, or icon tree-shaking in Flutter Web.
class HouseIcon extends StatelessWidget {
  final double size;
  final Color color;
  final bool isFilled;

  const HouseIcon({
    super.key,
    this.size = 22,
    required this.color,
    this.isFilled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _HousePainter(color: color, isFilled: isFilled),
      ),
    );
  }
}

class _HousePainter extends CustomPainter {
  final Color color;
  final bool isFilled;

  _HousePainter({required this.color, required this.isFilled});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final sx = w / 24.0;
    final sy = h / 24.0;

    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    if (isFilled) {
      paint.style = PaintingStyle.fill;
      final path = Path();
      // Roof peak
      path.moveTo(12.0 * sx, 3.0 * sy);
      // Right eave
      path.lineTo(21.5 * sx, 11.0 * sy);
      path.lineTo(19.0 * sx, 11.0 * sy);
      // Right wall down
      path.lineTo(19.0 * sx, 20.5 * sy);
      // Door right bottom
      path.lineTo(14.0 * sx, 20.5 * sy);
      // Door top right
      path.lineTo(14.0 * sx, 14.0 * sy);
      // Door top left
      path.lineTo(10.0 * sx, 14.0 * sy);
      // Door left bottom
      path.lineTo(10.0 * sx, 20.5 * sy);
      // Left wall down
      path.lineTo(5.0 * sx, 20.5 * sy);
      // Left wall up
      path.lineTo(5.0 * sx, 11.0 * sy);
      // Left eave
      path.lineTo(2.5 * sx, 11.0 * sy);
      path.close();

      canvas.drawPath(path, paint);
    } else {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 1.9 * sx;
      paint.strokeCap = StrokeCap.round;
      paint.strokeJoin = StrokeJoin.round;

      // Roof
      final roof = Path();
      roof.moveTo(2.5 * sx, 11.0 * sy);
      roof.lineTo(12.0 * sx, 3.0 * sy);
      roof.lineTo(21.5 * sx, 11.0 * sy);
      canvas.drawPath(roof, paint);

      // Body walls & floor
      final body = Path();
      body.moveTo(5.0 * sx, 9.8 * sy);
      body.lineTo(5.0 * sx, 20.5 * sy);
      body.lineTo(19.0 * sx, 20.5 * sy);
      body.lineTo(19.0 * sx, 9.8 * sy);
      canvas.drawPath(body, paint);

      // Door
      final door = Path();
      door.moveTo(10.0 * sx, 20.5 * sy);
      door.lineTo(10.0 * sx, 14.0 * sy);
      door.lineTo(14.0 * sx, 14.0 * sy);
      door.lineTo(14.0 * sx, 20.5 * sy);
      canvas.drawPath(door, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HousePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.isFilled != isFilled;
  }
}
