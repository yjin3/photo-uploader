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
  late Completer<void> exited;
  late Completer<void> requestHandled;
  late Completer<void> deleteRequested;
  var cancelDeletion = false;
  var recoveredUpload = false;
  var deleteOriginals = true;
  var httpStatus = 200;
  var sends = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('photo_uploader_test_');
    photo = File('${directory.path}/photo.png');
    await photo.writeAsBytes(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    ));
    events = [];
    exited = Completer<void>();
    requestHandled = Completer<void>();
    deleteRequested = Completer<void>();
    cancelDeletion = false;
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
          return null;
        default:
          throw StateError('Unexpected native method: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') {
        events.add('exit');
        if (!exited.isCompleted) exited.complete();
      }
      return null;
    });
  });

  tearDown(() async {
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

  testWidgets('200 -> durable acknowledgement -> original deletion -> cleanup -> exit', (tester) async {
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', exited.future);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'deleteOriginals', 'finish', 'exit']);
    expect(sends, 1);
  });

  testWidgets('cancel deletion keeps app open; retry never posts the photos twice', (tester) async {
    cancelDeletion = true;
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', deleteRequested.future);
    expect(exited.isCompleted, false);
    expect(events, isNot(contains('finish')));
    expect(find.textContaining('원본 삭제가 취소되었습니다.'), findsOneWidget);
    expect(find.text('원본 삭제 / 종료 계속').hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(find.byType(SnackBar)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('원본 삭제 / 종료 계속')).dy));
    cancelDeletion = false;
    await pressAndWait(tester, '원본 삭제 / 종료 계속', exited.future);
    expect(sends, 1);
    expect(events.where((event) => event == 'deleteOriginals').length, 2);
    expect(events.last, 'exit');
  });

  testWidgets('non-200 response never acknowledges, deletes originals, or exits', (tester) async {
    httpStatus = 500;
    await open(tester);
    await pressAndWait(tester, 'PC로 전송', requestHandled.future);
    expect(events, ['recover', 'post']);
    expect(exited.isCompleted, false);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
  });

  testWidgets('restart after upload resumes original deletion without another POST', (tester) async {
    recoveredUpload = true;
    await open(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('원본 삭제 / 종료 계속').hitTestable(), findsOneWidget);
    await pressAndWait(tester, '원본 삭제 / 종료 계속', exited.future);
    expect(sends, 0);
    expect(events, ['recover', 'acknowledgeUpload', 'deleteOriginals', 'finish', 'exit']);
  });

  testWidgets('unchecked deletion preserves originals and exits after uploading', (tester) async {
    await open(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    deleteOriginals = false;
    await pressAndWait(tester, 'PC로 전송', exited.future);
    expect(events, ['recover', 'post', 'acknowledgeUpload', 'finish', 'exit']);
  });
}
