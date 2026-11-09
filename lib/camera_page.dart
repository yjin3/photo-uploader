import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'monitor_frame.dart';

/// The device is replaceable so tests exercise the capture screen's actual
/// lifecycle and registration flow without a physical camera.
abstract class PhotoCamera {
  Future<void> initialize(ResolutionPreset resolution);
  Future<String> takePicture();
  Future<void> dispose();
  Widget buildPreview();
  double get maxZoom;
  double get minExposure;
  double get maxExposure;
  Future<void> setZoom(double zoom);
  Future<void> setExposure(double exposure);
  Future<void> focus(Offset point);
  Future<void> setFocusLocked(bool locked);
  ValueListenable<MonitorFrame> get monitorFrame;
  Future<void> setMonitorDetection(bool enabled);
}

class DevicePhotoCamera implements PhotoCamera {
  static const _originals = MethodChannel('photo_uploader/originals');
  static const _monitor = MethodChannel('photo_uploader/monitor');
  @override
  final ValueNotifier<MonitorFrame> monitorFrame =
      ValueNotifier(const MonitorFrame());
  bool _detecting = false;
  bool _frameBusy = false;
  int _analysisEpoch = 0;
  DateTime _nextFrame = DateTime.fromMillisecondsSinceEpoch(0);
  CameraController? _controller;
  double _maxZoom = 1;
  double _minExposure = 0;
  double _maxExposure = 0;

  @override
  double get maxZoom => _maxZoom;
  @override
  double get minExposure => _minExposure;
  @override
  double get maxExposure => _maxExposure;

  @override
  Future<void> initialize(ResolutionPreset resolution) async {
    await dispose();
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('사용 가능한 카메라가 없습니다.');
    final back = cameras
        .where((camera) => camera.lensDirection == CameraLensDirection.back);
    final controller = CameraController(
      back.isEmpty ? cameras.first : back.first,
      resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;
    await controller.initialize();
    // No flash reflection when photographing a monitor.
    try {
      await controller.setFlashMode(FlashMode.off);
    } on CameraException {/* Fixed flash device. */}
    _maxZoom = (await controller.getMaxZoomLevel()).clamp(1, 8).toDouble();
    _minExposure = await controller.getMinExposureOffset();
    _maxExposure = await controller.getMaxExposureOffset();
  }

  @override
  Widget buildPreview() => CameraPreview(_controller!);
  @override
  Future<String> takePicture() async {
    final controller = _controller!;
    _analysisEpoch++;
    // Pause frame delivery while taking a still photo so detection work does
    // not compete with full-resolution capture and file registration.
    if (controller.value.isStreamingImages) await controller.stopImageStream();
    // CameraX otherwise takes the display rotation, which can stay portrait
    // while the phone is held sideways with screen auto-rotate disabled.
    try {
      final name = await _originals.invokeMethod<String>('captureOrientation');
      final orientation = DeviceOrientation.values.firstWhere(
        (value) => value.name == name,
        orElse: () => throw StateError('촬영 방향을 확인하지 못했습니다.'),
      );
      await controller.lockCaptureOrientation(orientation);
      try {
        return (await controller.takePicture()).path;
      } finally {
        // A preview-reset failure must not discard an already captured photo.
        try {
          await controller.unlockCaptureOrientation();
        } on CameraException {/* The next shot sets its own direction again. */}
      }
    } finally {
      await _startMonitorStream();
    }
  }

  @override
  Future<void> setMonitorDetection(bool enabled) async {
    _detecting = enabled;
    _analysisEpoch++;
    monitorFrame.value = const MonitorFrame();
    final controller = _controller;
    if (!enabled && controller?.value.isStreamingImages == true) {
      await controller!.stopImageStream();
    } else if (enabled) {
      await _startMonitorStream();
    }
  }

  Future<void> _startMonitorStream() async {
    final controller = _controller;
    if (!_detecting ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages) return;
    try {
      await controller
          .startImageStream((image) => unawaited(_analyze(image, controller)));
    } on CameraException {
      monitorFrame.value =
          const MonitorFrame(message: '이 기기는 실시간 검출을 지원하지 않습니다 · 촬영 후 검출');
    }
  }

  Future<void> _analyze(CameraImage image, CameraController controller) async {
    if (!_detecting || _frameBusy || DateTime.now().isBefore(_nextFrame))
      return;
    _frameBusy = true;
    _nextFrame = DateTime.now().add(const Duration(milliseconds: 400));
    final epoch = _analysisEpoch;
    final orientation = controller.value.deviceOrientation;
    try {
      final step = (math.max(image.width, image.height) / 640).ceil();
      final width = (image.width + step - 1) ~/ step;
      final height = (image.height + step - 1) ~/ step;
      final plane = image.planes.first;
      final bytes = Uint8List(width * height);
      final pixelStride = plane.bytesPerPixel ?? 1;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          bytes[y * width + x] = plane
              .bytes[y * step * plane.bytesPerRow + x * step * pixelStride];
        }
      }
      final points = await _monitor.invokeListMethod<dynamic>(
          'detect', {'bytes': bytes, 'width': width, 'height': height});
      // Drop results from a previous camera or screen orientation.
      if (!_detecting ||
          epoch != _analysisEpoch ||
          _controller != controller ||
          orientation != controller.value.deviceOrientation) return;
      monitorFrame.value = MonitorFrame.fromSensor(
          points ?? [],
          controller.description.sensorOrientation,
          orientation,
          controller.description.lensDirection == CameraLensDirection.front);
    } catch (_) {
      if (_detecting && epoch == _analysisEpoch) {
        monitorFrame.value =
            const MonitorFrame(message: '실시간 검출 불가 · 촬영한 사진에서 다시 검출');
      }
    } finally {
      _frameBusy = false;
    }
  }

  @override
  Future<void> setZoom(double zoom) => _controller!.setZoomLevel(zoom);
  @override
  Future<void> setExposure(double exposure) async {
    await _controller!.setExposureOffset(exposure);
  }

  @override
  Future<void> focus(Offset point) async {
    await _controller!.setFocusMode(FocusMode.auto);
    await _controller!.setFocusPoint(point);
    await _controller!.setExposurePoint(point);
    // Allow autofocus to settle, then prevent repeated refocusing on the
    // monitor's pixel pattern. Another tap can focus at a new distance.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _controller!.setFocusMode(FocusMode.locked);
  }

  @override
  Future<void> setFocusLocked(bool locked) =>
      _controller!.setFocusMode(locked ? FocusMode.locked : FocusMode.auto);

  @override
  Future<void> dispose() async {
    _detecting = false;
    _analysisEpoch++;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages)
          await controller.stopImageStream();
      } finally {
        await controller.dispose();
      }
    }
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage(
      {super.key,
      required this.onCaptured,
      this.createCamera,
      this.initialCrop = true,
      this.buildLastPreview,
      this.onReviewLast});

  final Future<void> Function(String path, bool cropMonitor) onCaptured;
  final PhotoCamera Function()? createCamera;
  final bool initialCrop;
  final Widget Function()? buildLastPreview;
  final Future<void> Function()? onReviewLast;

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late final PhotoCamera _camera;
  final _previewKey = GlobalKey();
  Future<void> _operation = Future<void>.value();
  ResolutionPreset _resolution = ResolutionPreset.max;
  bool _active = true;
  bool _ready = false;
  bool _initializing = true;
  bool _capturing = false;
  bool _leaving = false;
  bool _allowPop = false;
  bool _cropCapture = true;
  bool _unsavedCrop = true;
  bool _focusing = false;
  bool _focusLocked = false;
  String? _unsavedPath;
  String? _error;
  int _count = 0;
  double _zoom = 1;
  double _exposure = 0;

  @override
  void initState() {
    super.initState();
    _camera = widget.createCamera?.call() ?? DevicePhotoCamera();
    _cropCapture = widget.initialCrop;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_enqueue(_initialize));
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    // Keep subsequent release/recovery operations runnable even after an error.
    _operation = next.catchError((Object _) {});
    return next;
  }

  Future<void> _initialize() async {
    if (!mounted || !_active || _leaving) return;
    setState(() {
      _initializing = true;
      _ready = false;
      _error = null;
    });
    try {
      await _camera.initialize(_resolution);
      await _camera.setMonitorDetection(_cropCapture);
      if (!mounted) return;
      setState(() {
        _ready = _active;
        _zoom = 1;
        _exposure = 0;
        _focusLocked = false;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '카메라를 준비하지 못했습니다: $error');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _release() async {
    if (mounted) setState(() => _ready = false);
    try {
      await _camera.dispose();
    } catch (error) {
      if (mounted) setState(() => _error = '카메라 해제 실패: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      unawaited(_enqueue(_initialize));
    } else {
      // Serialized after an in-flight capture/save: never dispose while the
      // camera is returning the file or while that file is being registered.
      unawaited(_enqueue(_release));
    }
  }

  Future<void> _registerPending() async {
    final path = _unsavedPath;
    if (path == null) return;
    await widget.onCaptured(path, _unsavedCrop);
    _unsavedPath = null;
    _count++;
  }

  Future<void> _capture() async {
    if (!_ready || _capturing || _leaving || !_active) return;
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      await _enqueue(() async {
        if (_unsavedPath == null) {
          if (!_active || !_ready) return;
          _unsavedCrop = _cropCapture;
          _unsavedPath = await _camera.takePicture();
        }
        // Every shutter press is made durable immediately. Returning from the
        // page is not required to save or discover a captured photo.
        await _registerPending();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '촬영 또는 사진 저장 실패: $error');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _finish() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _enqueue(() async {
        await _registerPending();
        await _release();
      });
      if (!mounted) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (error) {
      if (mounted)
        setState(() {
          _leaving = false;
          _error = '사진 저장을 완료하지 못했습니다: $error';
        });
    }
  }

  Future<void> _adjust(Future<void> Function() change) async {
    if (!_ready || _capturing || _leaving) return;
    try {
      await _enqueue(change);
    } catch (error) {
      if (mounted) setState(() => _error = '이 기기에서 설정을 적용하지 못했습니다: $error');
    }
  }

  Future<void> _focus(Offset point) async {
    if (!_ready || _capturing || _leaving || _focusing) return;
    setState(() => _focusing = true);
    try {
      await _enqueue(() => _camera.focus(point));
      if (mounted) setState(() => _focusLocked = true);
    } catch (error) {
      if (mounted) setState(() => _error = '초점 설정 실패: $error');
    } finally {
      if (mounted) setState(() => _focusing = false);
    }
  }

  @override
  void dispose() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_enqueue(_release));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _ready && !_capturing && !_leaving && !_focusing;
    final preview = Center(
        child: _ready
            ? GestureDetector(
                key: _previewKey,
                onTapUp: enabled
                    ? (tap) {
                        final size = (_previewKey.currentContext!
                                .findRenderObject() as RenderBox)
                            .size;
                        _focus(Offset(
                          (tap.localPosition.dx / size.width)
                              .clamp(0, 1)
                              .toDouble(),
                          (tap.localPosition.dy / size.height)
                              .clamp(0, 1)
                              .toDouble(),
                        ));
                      }
                    : null,
                child: Stack(children: [
                  _camera.buildPreview(),
                  if (_cropCapture)
                    Positioned.fill(
                        child: IgnorePointer(
                      child: ValueListenableBuilder<MonitorFrame>(
                        valueListenable: _camera.monitorFrame,
                        builder: (context, frame, _) =>
                            CustomPaint(painter: MonitorOutline(frame.corners)),
                      ),
                    )),
                ]),
              )
            : _initializing
                ? const CircularProgressIndicator()
                : const Icon(Icons.camera_alt, size: 72));
    final controls = <Widget>[
      SwitchListTile(
        key: const ValueKey('camera-crop'),
        title: const Text('모니터 자동 크롭'),
        subtitle: Text(_cropCapture ? '초록 테두리 표시 · 촬영 사진에서 최종 검출' : '전체 사진 촬영'),
        value: _cropCapture,
        onChanged: enabled
            ? (value) async {
                setState(() => _cropCapture = value);
                await _adjust(() => _camera.setMonitorDetection(value));
              }
            : null,
      ),
      if (_cropCapture)
        ValueListenableBuilder<MonitorFrame>(
          valueListenable: _camera.monitorFrame,
          builder: (context, frame, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child:
                  Text(frame.message, key: const ValueKey('monitor-status'))),
        ),
      if (_count > 0 && widget.onReviewLast != null)
        ListTile(
          key: const ValueKey('camera-review'),
          leading: SizedBox(
              width: 56, height: 42, child: widget.buildLastPreview?.call()),
          title: const Text('최근 사진 · 전송 미리보기'),
          onTap: enabled ? widget.onReviewLast : null,
        ),
      SwitchListTile(
        key: const ValueKey('focus-lock'),
        title: Text(_focusing ? '초점 맞추는 중…' : '초점 고정'),
        subtitle: const Text('화면을 누르면 초점을 맞춘 뒤 고정'),
        value: _focusLocked,
        onChanged: enabled
            ? (value) async {
                if (value) {
                  await _focus(const Offset(0.5, 0.5));
                } else {
                  await _adjust(() => _camera.setFocusLocked(false));
                  if (mounted) setState(() => _focusLocked = false);
                }
              }
            : null,
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!, key: const ValueKey('camera-error')),
        ),
      if (!_ready && !_initializing && !_leaving)
        TextButton(
            onPressed: () => _enqueue(_initialize),
            child: const Text('카메라 다시 연결')),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Text('해상도'),
            const SizedBox(width: 12),
            DropdownButton<ResolutionPreset>(
              value: _resolution,
              items: const [
                DropdownMenuItem(
                    value: ResolutionPreset.high, child: Text('높음')),
                DropdownMenuItem(
                    value: ResolutionPreset.veryHigh, child: Text('아주 높음')),
                DropdownMenuItem(
                    value: ResolutionPreset.max, child: Text('최대')),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value == null) return;
                      setState(() => _resolution = value);
                      unawaited(_enqueue(_initialize));
                    }
                  : null,
            ),
          ])),
      if (_ready && _camera.maxZoom > 1)
        Row(children: [
          const SizedBox(width: 16),
          Text('줌 ${_zoom.toStringAsFixed(1)}×'),
          Expanded(
              child: Slider(
                  value: _zoom,
                  min: 1,
                  max: _camera.maxZoom,
                  onChanged:
                      enabled ? (value) => setState(() => _zoom = value) : null,
                  onChangeEnd: (value) =>
                      _adjust(() => _camera.setZoom(value)))),
        ]),
      if (_ready && _camera.maxExposure > _camera.minExposure)
        Row(children: [
          const SizedBox(width: 16),
          const Text('밝기'),
          Expanded(
              child: Slider(
                  value: _exposure
                      .clamp(_camera.minExposure, _camera.maxExposure)
                      .toDouble(),
                  min: _camera.minExposure,
                  max: _camera.maxExposure,
                  onChanged: enabled
                      ? (value) => setState(() => _exposure = value)
                      : null,
                  onChangeEnd: (value) =>
                      _adjust(() => _camera.setExposure(value)))),
        ]),
      const Text('모니터를 눌러 초점 고정 · 플래시 끔'),
    ];
    final shutter = Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          key: const ValueKey('camera-shutter'),
          onPressed: enabled ? _capture : null,
          icon: const Icon(Icons.camera_alt),
          label: Text(_capturing
              ? '사진 저장 중…'
              : _unsavedPath == null
                  ? '촬영'
                  : '사진 저장 재시도'),
        ));
    Widget panel(double height) => SizedBox(
        height: height,
        child: Column(children: [
          Expanded(
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min, children: controls))),
          shutter,
        ]));
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_finish());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('연속 촬영 · $_count장'),
          leading: IconButton(
              onPressed: _leaving ? null : _finish,
              icon: const Icon(Icons.arrow_back)),
          actions: [
            TextButton(
                onPressed: _leaving ? null : _finish,
                child: Text('완료 ($_count장)'))
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth > constraints.maxHeight) {
              return Row(children: [
                Expanded(child: preview),
                SizedBox(
                  width:
                      (constraints.maxWidth * 0.4).clamp(220, 320).toDouble(),
                  child: panel(constraints.maxHeight),
                ),
              ]);
            }
            return Column(children: [
              Expanded(child: preview),
              panel(constraints.maxHeight * 0.48)
            ]);
          }),
        ),
      ),
    );
  }
}
