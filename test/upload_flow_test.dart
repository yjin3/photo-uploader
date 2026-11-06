import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photo_uploader/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const originals = MethodChannel('photo_uploader/originals');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File photo;
  late List<String> events;
  late Completer<void> finished;
  late Completer<void> requestHandled;
  late Completer<void> deleteRequested;
  var cancelDeletion = false;
  var failCleanup = false;
  var recoveredUpload = false;
  var deleteOriginals = true;
  var httpStatus = 200;
  var sends = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('photo_uploader_test_');
    // Android stores the copy under a GUID, but multipart must use the original
    // provider display name. Equal basenames would conceal this regression.
    photo = File('${directory.path}/b531857e-1905-4680-be15-ff5c1fba02f9');
    await photo.writeAsBytes(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    ));
    events = [];
    finished = Completer<void>();
    requestHandled = Completer<void>();
    deleteRequested = Completer<void>();
    cancelDeletion = false;
    failCleanup = false;
    recoveredUpload = false;
    deleteOriginals = true;
    httpStatus = 200;
    sends = 0;
    SharedPreferences.setMockInitialValues({
      'server_address': 'http://100.101.102.103:8000',
    });
    messenger.setMockMethodCallHandler(originals, (call) async {
      events.add(call.method);
      switch (call.method) {
        case 'recover':
          return {
            'photos': [{'path': photo.path, 'name': 'photo.png'}],
            'uploaded': recoveredUpload,
            'deleteOriginals': deleteOriginals,
          };
        case 'pick':
          return {
            'photos': [{'path': photo.path, 'name': 'photo.png'}],
            'uploaded': false,
            // After native finish(), the next selection has this default.
            'deleteOriginals': true,
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
    await tester.pumpWidget(MaterialApp(home: UploadPage(createClient: () {
      return MockClient((request) async {
        sends++;
        events.add('post');
        expect(request.url.toString(), 'http://100.101.102.103:8000/upload');
        expect(request.headers['content-type'], contains('multipart/form-data'));
        final body = latin1.decode(request.bodyBytes);
        expect(body, contains('name="tag"'));
        expect(body, contains('name="files"; filename="photo.png"'));
        if (!requestHandled.isCompleted) requestHandled.complete();
        return http.Response(httpStatus == 200 ? '{}' : 'disk full', httpStatus);
      });
    })));
    await tester.pumpAndSettle();
  }

  Future<void> pressAndWait(WidgetTester tester, String label, Future<void> done) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await done.timeout(const Duration(seconds: 5));
      // Drain the channel response and the async upload continuation.
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  void expectReadyForNextUpload() {
    expect(find.text('사진 선택 (0장)'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('갤러리에서 사진을 선택하세요.'), findsOneWidget);
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
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    deleteOriginals = false;
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'finish']);
    expectReadyForNextUpload();
  });

  testWidgets('another batch uploads in the same app session and preserves checkbox choice', (tester) async {
    await open(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    deleteOriginals = false;
    await pressAndWait(tester, 'PC로 전송', finished.future);
    expectReadyForNextUpload();
    finished = Completer<void>();
    await tester.tap(find.text('사진 선택 (0장)'));
    await tester.pumpAndSettle();
    expect(find.text('사진 선택 (1장)'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, false);
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
}

FilledButton testerButton(String label) {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  return button.evaluate().single.widget as FilledButton;
}
