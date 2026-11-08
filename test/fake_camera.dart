import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:photo_uploader/camera_page.dart';

class FakePhotoCamera implements PhotoCamera {
  FakePhotoCamera(this.pathPrefix);
  final String pathPrefix;
  int shots = 0;
  int initializations = 0;
  int releases = 0;
  bool initialized = false;
  bool failShot = false;
  Completer<void>? pendingShot;
  ResolutionPreset? resolution;
  double zoom = 1;
  double exposure = 0;
  Offset? focusPoint;

  @override
  double get maxZoom => 4;
  @override
  double get minExposure => -2;
  @override
  double get maxExposure => 2;
  @override
  Future<void> initialize(ResolutionPreset resolution) async {
    this.resolution = resolution;
    initializations++;
    initialized = true;
  }

  @override
  Future<String> takePicture() async {
    if (!initialized) throw StateError('Capture after camera disposal');
    if (failShot) throw StateError('카메라를 열 수 없습니다.');
    shots++;
    await pendingShot?.future;
    if (!initialized) throw StateError('Camera disposed during capture');
    return '${pathPrefix}_$shots.jpg';
  }

  @override
  Future<void> dispose() async {
    releases++;
    initialized = false;
  }

  @override
  Widget buildPreview() => const SizedBox(
        key: ValueKey('fake-camera-preview'),
        width: 240,
        height: 160,
        child: ColoredBox(color: Colors.black),
      );
  @override
  Future<void> focus(Offset point) async {
    focusPoint = point;
  }

  @override
  Future<void> setZoom(double zoom) async {
    this.zoom = zoom;
  }

  @override
  Future<void> setExposure(double exposure) async {
    this.exposure = exposure;
  }
}
