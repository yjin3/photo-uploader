import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MonitorFrame {
  const MonitorFrame({this.corners = const [], this.message = '모니터 테두리를 찾는 중'});
  final List<Offset> corners;
  final String message;

  factory MonitorFrame.fromSensor(List<dynamic> points, int sensorOrientation,
      DeviceOrientation previewOrientation, bool front) {
    const rotations = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270
    };
    final rotation = (sensorOrientation +
            (front ? 1 : -1) * rotations[previewOrientation]! +
            360) %
        360;
    final corners = points.map((point) {
      final x = (point[0] as num).toDouble();
      final y = (point[1] as num).toDouble();
      final rotated = switch (rotation) {
        90 => Offset(1 - y, x),
        180 => Offset(1 - x, 1 - y),
        270 => Offset(y, 1 - x),
        _ => Offset(x, y),
      };
      return front ? Offset(1 - rotated.dx, rotated.dy) : rotated;
    }).toList();
    return MonitorFrame(
        corners: corners,
        message:
            corners.length == 4 ? '초록 테두리: 모니터 인식 영역' : '테두리 미검출 · 전체 사진으로 저장');
  }
}

class MonitorOutline extends CustomPainter {
  const MonitorOutline(this.corners);
  final List<Offset> corners;
  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final points = corners
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();
    final outline = Path()..addPolygon(points, true);
    canvas.drawPath(
        outline, Paint()..color = Colors.greenAccent.withValues(alpha: 0.12));
    canvas.drawPath(
        outline,
        Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    for (final point in points) {
      canvas.drawCircle(point, 5, Paint()..color = Colors.greenAccent);
    }
  }

  @override
  bool shouldRepaint(MonitorOutline oldDelegate) =>
      oldDelegate.corners != corners;
}
