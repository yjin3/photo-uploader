import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photo_uploader/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const originals = MethodChannel('photo_uploader/originals');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File photo;
  late List<String> events;
  late List<Map<String, String>> selectedPhotos;
  late Completer<void> finished;
  late Completer<void> requestHandled;
  late Completer<void> deleteRequested;
  var cancelDeletion = false;
  var failCleanup = false;
  var recoveredUpload = false;
  var deleteOriginals = true;
  var httpStatus = 200;
  var sends = 0;
  var cameraShots = 0;
  late FakePhotoCamera camera;
  var failRegistration = false;
  late List<Map<dynamic, dynamic>> prepareCalls;
  File? optimizedFile;
  var failPreparation = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('photo_uploader_test_');
    // Android stores the copy under a GUID, but multipart must use the original
    // provider display name. Equal basenames would conceal this regression.
    photo = File('${directory.path}/b531857e-1905-4680-be15-ff5c1fba02f9');
    await photo.writeAsBytes(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    ));
    events = [];
    selectedPhotos = [{'path': photo.path, 'name': 'photo.png'}];
    finished = Completer<void>();
    requestHandled = Completer<void>();
    deleteRequested = Completer<void>();
    cancelDeletion = false;
    failCleanup = false;
    recoveredUpload = false;
    deleteOriginals = true;
    httpStatus = 200;
    sends = 0;
    cameraShots = 0;
    camera = FakePhotoCamera(photo.path);
    failRegistration = false;
    prepareCalls = [];
    optimizedFile = null;
    failPreparation = false;
    SharedPreferences.setMockInitialValues({
      'server_address': 'http://100.101.102.103:8000',
    });
    messenger.setMockMethodCallHandler(originals, (call) async {
      if (call.method != 'prepareUpload') events.add(call.method);
      switch (call.method) {
        case 'recover':
          return {
            'photos': List.of(selectedPhotos),
            'uploaded': recoveredUpload,
            'deleteOriginals': deleteOriginals,
          };
        case 'pick':
          selectedPhotos.add({'path': '${photo.path}_gallery_${selectedPhotos.length}', 'name': 'photo.png'});
          return {
            'photos': List.of(selectedPhotos),
            'uploaded': false,
            // After native finish(), the next selection has this default.
            'deleteOriginals': true,
          };
        case 'prepareCamera':
          return null;
        case 'registerCapture':
          expect(call.arguments['path'], startsWith('${photo.path}_'));
          if (failRegistration) throw PlatformException(code: 'SAVE_FAILED', message: '사진 저장 실패');
          cameraShots++;
          selectedPhotos.add({
            'path': call.arguments['path'] as String,
            'name': '20261106_153000_${cameraShots.toString().padLeft(3, '0')}.jpg',
          });
          return {
            'photos': List.of(selectedPhotos),
            'uploaded': false,
            'deleteOriginals': true,
          };
        case 'prepareUpload':
          prepareCalls.add(Map.of(call.arguments as Map));
          if (failPreparation) throw PlatformException(code: 'PREPARE_FAILED', message: '전송 파일 준비 실패');
          final selected = selectedPhotos.firstWhere((item) => item['path'] == call.arguments['path']);
          final optimized = call.arguments['optimize'] == true ? optimizedFile : null;
          return {
            'path': optimized?.path ?? photo.path,
            'name': optimized == null ? selected['name']! : 'processed.jpg',
            'sourceBytes': photo.lengthSync(),
            'uploadBytes': (optimized ?? photo).lengthSync(),
            'cropped': optimized != null,
            'note': '',
          };
        case 'acknowledgeUpload':
          expect(call.arguments['deleteOriginals'], deleteOriginals);
          return null;
        case 'deleteOriginals':
          if (!deleteRequested.isCompleted) deleteRequested.complete();
          if (cancelDeletion) {
            throw PlatformException(code: 'CANCELLED', message: '원본 삭제가 취소되었습니다.');
          }
          return null;
        case 'finish':
          if (!finished.isCompleted) finished.complete();
          if (failCleanup) {
            throw PlatformException(code: 'CLEANUP_FAILED', message: '완료 처리 실패');
          }
          selectedPhotos.clear();
          return null;
        default:
          throw StateError('Unexpected native method: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') {
        events.add('exit');
      }
      return null;
    });
  });

  tearDown(() async {
    expect(events, isNot(contains('exit')), reason: 'Completing an upload must keep the app open.');
    messenger.setMockMethodCallHandler(originals, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: UploadPage(
      // These tests exercise selection, upload, and deletion. Keep thumbnail
      // decoding independent so Image.file cannot retain a Windows fixture handle.
      thumbnailBuilder: (_) => const SizedBox.expand(),
      createCamera: () => camera,
      createClient: () {
      return MockClient((request) async {
        sends++;
        events.add('post');
        expect(request.url.toString(), 'http://100.101.102.103:8000/upload');
        expect(request.headers['content-type'], contains('multipart/form-data'));
        final body = latin1.decode(request.bodyBytes);
        expect(body, contains('name="tag"'));
        expect(body, contains('name="crop_monitor"'));
        expect(body, contains('name="crop_monitor"\r\n\r\nfalse'));
        for (final selected in selectedPhotos) {
          final optimized = prepareCalls.last['optimize'] == true ? optimizedFile : null;
          expect(body, contains('name="files"; filename="${optimized == null ? selected['name'] : 'processed.jpg'}"'));
        }
        if (optimizedFile != null && prepareCalls.last['optimize'] == true) {
          expect(body, contains('SMALL_UPLOAD_ONLY'));
          expect(body, isNot(contains(latin1.decode(photo.readAsBytesSync()))));
        }
        expect(RegExp('name="files"; filename=').allMatches(body).length, selectedPhotos.length);
        if (!requestHandled.isCompleted) requestHandled.complete();
        return http.Response(httpStatus == 200 ? '{}' : 'disk full', httpStatus);
      });
    })));
    await tester.pumpAndSettle();
  }

  Future<void> pressAndWait(WidgetTester tester, String label, Future<void> done) async {
    var completed = false;
    done.then((_) => completed = true);
    await tester.tap(find.text(label));
    // File IO needs real event-loop time, while method-channel continuations
    // and completers created by widget tests need the fake clock to be pumped.
    // Awaiting the entire operation inside runAsync starves those continuations.
    await pumpUntil(tester, () => completed, reason: 'Upload action: $label');
    await tester.pumpAndSettle();
  }

  Future<void> waitForCameraShot(WidgetTester tester, int count) => pumpUntil(
        tester,
        () => find.text('연속 촬영 · $count장').evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byKey(const ValueKey('camera-shutter'))).onPressed != null,
        reason: 'Camera ready after shot $count',
      );

  Future<void> waitForCameraDone(WidgetTester tester) => pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isEmpty &&
            find.text('PC로 전송').evaluate().isNotEmpty &&
            testerButton('PC로 전송').onPressed != null,
        reason: 'Camera session finished',
      );

  void expectReadyForNextUpload() {
    expect(find.text('사진 선택 (0장)'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('갤러리에서 선택하거나 카메라로 촬영하세요.'), findsOneWidget);
    expect(find.text('PC로 전송'), findsOneWidget);
    expect(testerButton('PC로 전송').onPressed, isNull);
  }

  testWidgets('200 deletes originals and clears the list while keeping app open', (tester) async {
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'deleteOriginals', 'finish']);
    expect(sends, 1);
    expectReadyForNextUpload();
  });

  testWidgets('cancel deletion keeps app open; retry never posts the photos twice', (tester) async {
    cancelDeletion = true;
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', deleteRequested.future);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(events, isNot(contains('finish')));
    expect(find.textContaining('원본 삭제가 취소되었습니다.'), findsOneWidget);
    expect(find.text('전송 완료 처리 계속').hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(find.byType(SnackBar)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('전송 완료 처리 계속')).dy));
    cancelDeletion = false;
    await pressAndWait(tester, '전송 완료 처리 계속', finished.future);
    expect(sends, 1);
    expect(events.where((event) => event == 'deleteOriginals').length, 2);
    expect(events.last, 'finish');
    expectReadyForNextUpload();
  });

  testWidgets('non-200 response preserves list and never acknowledges or deletes originals', (tester) async {
    httpStatus = 500;
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', requestHandled.future);
    expect(events, ['recover', 'post']);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
  });

  testWidgets('restart after upload resumes original deletion without another POST', (tester) async {
    recoveredUpload = true;
    await open(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('전송 완료 처리 계속').hitTestable(), findsOneWidget);
    await pressAndWait(tester, '전송 완료 처리 계속', finished.future);
    expect(sends, 0);
    expect(events, ['recover', 'acknowledgeUpload', 'deleteOriginals', 'finish']);
    expectReadyForNextUpload();
  });

  testWidgets('unchecked deletion preserves originals and clears the completed list', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('delete-originals')));
    await tester.pumpAndSettle();
    deleteOriginals = false;
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'finish']);
    expectReadyForNextUpload();
  });

  testWidgets('another batch uploads in the same app session and preserves checkbox choice', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('delete-originals')));
    await tester.pumpAndSettle();
    deleteOriginals = false;
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expectReadyForNextUpload();
    finished = Completer<void>();
    await tester.tap(find.text('사진 선택 (0장)'));
    await tester.pumpAndSettle();
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('delete-originals'))).value, false);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(sends, 2);
    expect(events.where((event) => event == 'acknowledgeUpload').length, 2);
    expect(events, isNot(contains('deleteOriginals')));
    expectReadyForNextUpload();
  });

  testWidgets('cleanup failure keeps the list and retries without upload or deletion', (tester) async {
    failCleanup = true;
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(find.textContaining('완료 처리 실패'), findsOneWidget);
    failCleanup = false;
    finished = Completer<void>();
    await pressAndWait(tester, '전송 완료 처리 계속', finished.future);
    expect(sends, 1);
    expect(events.where((event) => event == 'deleteOriginals').length, 1);
    expect(events.where((event) => event == 'finish').length, 2);
    expectReadyForNextUpload();
  });

  testWidgets('five camera shots accumulate without gallery selection and upload together', (tester) async {
    selectedPhotos.clear();
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    for (var count = 1; count <= 5; count++) {
      await tester.tap(find.byKey(const ValueKey('camera-shutter')));
      await waitForCameraShot(tester, count);
      expect(find.byType(AlertDialog), findsNothing);
    }
    await tester.tap(find.text('완료 (5장)'));
    await waitForCameraDone(tester);
    expect(cameraShots, 5);
    expect(events, ['recover', 'prepareCamera', ...List.filled(5, 'registerCapture')]);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(sends, 1);
    expect(events.sublist(7), ['post', 'acknowledgeUpload', 'deleteOriginals', 'finish']);
    expectReadyForNextUpload();
  });

  testWidgets('camera shots append to existing gallery selection', (tester) async {
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await waitForCameraShot(tester, 1);
    await tester.tap(find.text('완료 (1장)'));
    await waitForCameraDone(tester);
    expect(find.text('사진 선택 (2장)'), findsOneWidget);
    expect(selectedPhotos.map((item) => item['name']),
        ['photo.png', '20261106_153000_001.jpg']);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(sends, 1);
    expectReadyForNextUpload();
  });

  testWidgets('back from the camera retains already registered shots', (tester) async {
    selectedPhotos.clear();
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await waitForCameraShot(tester, 1);
    await tester.binding.handlePopRoute();
    await waitForCameraDone(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(cameraShots, 1);
    expect(testerButton('PC로 전송').onPressed, isNotNull);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expectReadyForNextUpload();
  });

  testWidgets('camera error preserves selection and leaves gallery usable', (tester) async {
    camera.failShot = true;
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await waitForCameraShot(tester, 0);
    expect(find.textContaining('카메라를 열 수 없습니다.'), findsOneWidget);
    await tester.tap(find.text('완료 (0장)'));
    await waitForCameraDone(tester);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(sends, 0);
    await tester.tap(find.text('사진 선택 (1장)'));
    await tester.pumpAndSettle();
    expect(events.last, 'pick');
    expect(find.text('사진 선택 (2장)'), findsOneWidget);
  });

  testWidgets('registration failure retries the same shot without another capture', (tester) async {
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    failRegistration = true;
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await waitForCameraShot(tester, 0);
    expect(find.textContaining('사진 저장 실패'), findsOneWidget);
    failRegistration = false;
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await waitForCameraShot(tester, 1);
    expect(camera.shots, 1);
    expect(events.where((event) => event == 'registerCapture').length, 2);
    await tester.tap(find.text('완료 (1장)'));
    await waitForCameraDone(tester);
    expect(find.text('사진 선택 (2장)'), findsOneWidget);
  });

  testWidgets('backgrounding during a shot waits for saving before releasing camera', (tester) async {
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    camera.pendingShot = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('camera-shutter')));
    await tester.pump();
    final releases = camera.releases;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.releases, releases);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    camera.pendingShot!.complete();
    await waitForCameraShot(tester, 1);
    expect(camera.releases, greaterThan(releases));
    expect(camera.initializations, greaterThan(1));
    expect(cameraShots, 1);
    await tester.tap(find.text('완료 (1장)'));
    await waitForCameraDone(tester);
  });

  testWidgets('camera quality, zoom, brightness and tap focus apply to the device', (tester) async {
    await open(tester);
    await tester.tap(find.text('카메라'));
    await waitForCameraShot(tester, 0);
    expect(camera.resolution, ResolutionPreset.max);
    await tester.tap(find.text('최대'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('높음').last);
    await waitForCameraShot(tester, 0);
    expect(camera.resolution, ResolutionPreset.high);
    await tester.tap(find.byKey(const ValueKey('fake-camera-preview')));
    await tester.pumpAndSettle();
    expect(camera.focusPoint!.dx, closeTo(0.5, 0.1));
    expect(camera.focusPoint!.dy, closeTo(0.5, 0.1));
    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(camera.zoom, greaterThan(1));
    await tester.drag(find.byType(Slider).last, const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(camera.exposure, greaterThan(0));
    await tester.tap(find.text('완료 (0장)'));
    await waitForCameraDone(tester);
  });

  testWidgets('only the prepared file is posted and server-side cropping is disabled', (tester) async {
    optimizedFile = File('${directory.path}/prepared.jpg');
    optimizedFile!.writeAsStringSync('SMALL_UPLOAD_ONLY');
    await open(tester);
    expect(prepareCalls.last['optimize'], true);
    expect(find.textContaining('% 감소'), findsOneWidget);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(sends, 1);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'deleteOriginals', 'finish']);
    expectReadyForNextUpload();
  });

  testWidgets('turning optimization off requests the original once', (tester) async {
    optimizedFile = File('${directory.path}/prepared.jpg');
    optimizedFile!.writeAsStringSync('SMALL_UPLOAD_ONLY');
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('crop-monitor')));
    await tester.pumpAndSettle();
    expect(prepareCalls.last['optimize'], false);
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(prepareCalls.last['optimize'], false);
    expect(sends, 1);
    expectReadyForNextUpload();
  });

  testWidgets('preparation failure never posts or deletes originals', (tester) async {
    await open(tester);
    failPreparation = true;
    await tester.tap(find.text('PC로 전송'));
    await tester.pumpAndSettle();
    expect(find.textContaining('전송 파일 준비 실패'), findsOneWidget);
    expect(events, ['recover']);
    expect(sends, 0);
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
  });
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) {
      // Finish entrance/exit animations without waiting for every animation in
      // the app: the busy spinner intentionally runs behind camera dialogs.
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  fail('Condition was not reached: $reason');
}

FilledButton testerButton(String label) {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  return button.evaluate().single.widget as FilledButton;
}
