import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_uploader/monitor_frame.dart';

void main() {
  test(
      'sensor corners follow all preview rotations, independently of capture rotation',
      () {
    const expected = {
      DeviceOrientation.portraitUp: Offset(.7, .2),
      DeviceOrientation.landscapeLeft: Offset(.2, .3),
      DeviceOrientation.portraitDown: Offset(.3, .8),
      DeviceOrientation.landscapeRight: Offset(.8, .7),
    };
    for (final entry in expected.entries) {
      final point = MonitorFrame.fromSensor([
        [.2, .3]
      ], 90, entry.key, false)
          .corners
          .single;
      expect(point.dx, closeTo(entry.value.dx, .0001));
      expect(point.dy, closeTo(entry.value.dy, .0001));
    }
  });
}
