import 'dart:async';
import 'dart:math' show Point;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_uploader/camera_page.dart';

// The platform keeps its UI orientation in portrait throughout these tests.
// Captures must instead use the physical direction returned by Android.
class _PortraitCameraPlatform extends CameraPlatform {
  final errors = StreamController<CameraErrorEvent>.broadcast();
  final frames = StreamController<CameraImageData>.broadcast();
  final focusModes = <FocusMode>[];
  final captured = <DeviceOrientation?>[];
  DeviceOrientation? locked;
  bool failCapture = false;
  bool failUnlock = false;
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(int cameraId,
          {CameraImageStreamOptions? options}) =>
      frames.stream;
  @override
  Future<void> setFocusMode(int cameraId, FocusMode focusMode) async {
    focusModes.add(focusMode);
  }

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {}
  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {}

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
            name: 'back',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90),
      ];
  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription,
          MediaSettings mediaSettings) async =>
      1;
  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(const CameraInitializedEvent(
          1, 4000, 3000, ExposureMode.auto, true, FocusMode.auto, true));
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
          const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp));
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}
  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 1;
  @override
  Future<double> getMinExposureOffset(int cameraId) async => 0;
  @override
  Future<double> getMaxExposureOffset(int cameraId) async => 0;
  @override
  Future<void> lockCaptureOrientation(
      int cameraId, DeviceOrientation orientation) async {
    locked = orientation;
  }

  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {
    if (failUnlock) throw CameraException('RESET_FAILED', 'reset failed');
    locked = null;
  }

  @override
  Future<XFile> takePicture(int cameraId) async {
    captured.add(locked);
    expect(frames.hasListener, isFalse,
        reason: 'Analysis must stop before full-resolution capture');
    if (failCapture)
      throw PlatformException(
          code: 'CAPTURE_FAILED', message: 'capture failed');
    return XFile('/capture_${captured.length}.jpg');
  }

  @override
  Future<void> dispose(int cameraId) async {
    errors.add(const CameraErrorEvent(1, 'disposed'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const originals = MethodChannel('photo_uploader/originals');
  const monitor = MethodChannel('photo_uploader/monitor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CameraPlatform previous;
  late _PortraitCameraPlatform platform;
  late DevicePhotoCamera camera;
  var physical = DeviceOrientation.landscapeLeft;

  setUp(() async {
    previous = CameraPlatform.instance;
    platform = _PortraitCameraPlatform();
    CameraPlatform.instance = platform;
    camera = DevicePhotoCamera();
    physical = DeviceOrientation.landscapeLeft;
    messenger.setMockMethodCallHandler(originals, (call) async {
      expect(call.method, 'captureOrientation');
      return physical.name;
    });
    await camera.initialize(ResolutionPreset.max);
  });

  tearDown(() async {
    await camera.dispose();
    await platform.errors.close();
    await platform.frames.close();
    CameraPlatform.instance = previous;
    messenger.setMockMethodCallHandler(originals, null);
    messenger.setMockMethodCallHandler(monitor, null);
  });

  test('every shot follows physical rotation with screen locked in portrait',
      () async {
    const directions = [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitDown
    ];
    for (final direction in directions) {
      physical = direction;
      await camera.takePicture();
      expect(platform.locked, isNull,
          reason: 'Restore the preview after each shot');
    }
    expect(platform.captured, directions);
  });

  test('failed capture unlocks orientation and a rotated retry succeeds',
      () async {
    platform.failCapture = true;
    await expectLater(camera.takePicture(), throwsA(isA<CameraException>()));
    expect(platform.locked, isNull);
    platform.failCapture = false;
    physical = DeviceOrientation.landscapeRight;
    expect(await camera.takePicture(), '/capture_2.jpg');
    expect(platform.captured,
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  });

  test(
      'preview reset failure preserves a captured file and next shot direction',
      () async {
    platform.failUnlock = true;
    expect(await camera.takePicture(), '/capture_1.jpg');
    physical = DeviceOrientation.portraitUp;
    platform.failUnlock = false;
    expect(await camera.takePicture(), '/capture_2.jpg');
    expect(platform.captured,
        [DeviceOrientation.landscapeLeft, DeviceOrientation.portraitUp]);
    expect(platform.locked, isNull);
  });

  test('tap focus settles then locks, and continuous autofocus can be restored',
      () async {
    await camera.focus(const Offset(0.5, 0.5));
    expect(platform.focusModes, [FocusMode.auto, FocusMode.locked]);
    await camera.setFocusLocked(false);
    expect(platform.focusModes.last, FocusMode.auto);
  });

  test('live guide respects Y plane row padding and stops during each capture',
      () async {
    final detected = Completer<void>();
    messenger.setMockMethodCallHandler(monitor, (call) async {
      expect(call.arguments['bytes'], Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      expect(call.arguments['width'], 3);
      expect(call.arguments['height'], 2);
      detected.complete();
      return [
        [0.1, 0.2],
        [0.9, 0.2],
        [0.9, 0.8],
        [0.1, 0.8]
      ];
    });
    await camera.setMonitorDetection(true);
    platform.frames.add(CameraImageData(
        format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
        width: 3,
        height: 2,
        planes: [
          CameraImagePlane(
              bytes: Uint8List.fromList([1, 2, 3, 99, 4, 5, 6]),
              bytesPerRow: 4,
              bytesPerPixel: 1)
        ]));
    await detected.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    expect(camera.monitorFrame.value.corners.first.dx, closeTo(0.8, 0.001));
    expect(camera.monitorFrame.value.corners.first.dy, closeTo(0.1, 0.001));
    await camera.takePicture();
    expect(platform.frames.hasListener, isTrue);
    await camera.setMonitorDetection(false);
    expect(platform.frames.hasListener, isFalse);
    expect(camera.monitorFrame.value.corners, isEmpty);
  });
}
