import 'package:flutter/material.dart';

/// Reference effects: white 25% inset highlight and black 63% drop shadow.
/// Both use offset (0, 4), blur radius 4, and zero spread.
class PopButtonEffects extends StatelessWidget {
  const PopButtonEffects({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: const [
        BoxShadow(
          color: Color.fromRGBO(0, 0, 0, .63),
          offset: Offset(0, 4),
          blurRadius: 4,
          spreadRadius: 0,
        ),
      ],
    ),
    child: CustomPaint(
      foregroundPainter: _InsetHighlight(borderRadius),
      child: child,
    ),
  );
}

class _InsetHighlight extends CustomPainter {
  const _InsetHighlight(this.borderRadius);
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = borderRadius.toRRect(Offset.zero & size);
    // Blur the outside of a shape shifted down by four pixels, clipped
    // inside the original shape. This produces a true inset top highlight.
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(32))
      ..addRRect(shape.shift(const Offset(0, 4)));
    final paint = Paint()
      ..color = const Color.fromRGBO(255, 255, 255, .25)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        const BoxShadow(blurRadius: 4).blurSigma,
      );
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawPath(outside, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _InsetHighlight oldDelegate) =>
      oldDelegate.borderRadius != borderRadius;
}
