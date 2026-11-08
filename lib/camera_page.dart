import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

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
}

class DevicePhotoCamera implements PhotoCamera {
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
  Future<String> takePicture() async => (await _controller!.takePicture()).path;
  @override
  Future<void> setZoom(double zoom) => _controller!.setZoomLevel(zoom);
  @override
  Future<void> setExposure(double exposure) async {
    await _controller!.setExposureOffset(exposure);
  }

  @override
  Future<void> focus(Offset point) async {
    await _controller!.setFocusPoint(point);
    await _controller!.setExposurePoint(point);
  }

  @override
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key, required this.onCaptured, this.createCamera});

  final Future<void> Function(String path) onCaptured;
  final PhotoCamera Function()? createCamera;

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
  String? _unsavedPath;
  String? _error;
  int _count = 0;
  double _zoom = 1;
  double _exposure = 0;

  @override
  void initState() {
    super.initState();
    _camera = widget.createCamera?.call() ?? DevicePhotoCamera();
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
      if (!mounted) return;
      setState(() {
        _ready = _active;
        _zoom = 1;
        _exposure = 0;
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
    await widget.onCaptured(path);
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

  @override
  void dispose() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_enqueue(_release));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _ready && !_capturing && !_leaving;
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
            child: Column(children: [
          Expanded(
              child: Center(
                  child: _ready
                      ? GestureDetector(
                          key: _previewKey,
                          onTapUp: enabled
                              ? (tap) {
                                  final size = (_previewKey.currentContext!
                                          .findRenderObject() as RenderBox)
                                      .size;
                                  _adjust(() => _camera.focus(Offset(
                                        (tap.localPosition.dx / size.width)
                                            .clamp(0, 1)
                                            .toDouble(),
                                        (tap.localPosition.dy / size.height)
                                            .clamp(0, 1)
                                            .toDouble(),
                                      )));
                                }
                              : null,
                          child: _camera.buildPreview(),
                        )
                      : _initializing
                          ? const CircularProgressIndicator()
                          : const Icon(Icons.camera_alt, size: 72))),
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
                      onChanged: enabled
                          ? (value) => setState(() => _zoom = value)
                          : null,
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
          const Text('화면을 눌러 초점 조절 · 플래시 끔'),
          Padding(
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
              )),
        ])),
      ),
    );
  }
}
