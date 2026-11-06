import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotoUploaderApp());
}

class PhotoUploaderApp extends StatelessWidget {
  const PhotoUploaderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Photo Uploader',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const UploadPage(),
      );
}

class UploadPage extends StatefulWidget {
  const UploadPage({super.key, this.createClient, this.thumbnailBuilder});

  final http.Client Function()? createClient;
  final Widget Function(String path)? thumbnailBuilder;

  @override
  State<UploadPage> createState() => _UploadPageState();
}

// Keep the provider's display name separate from the local copy's basename.
// XFile.name on native platforms can resolve to the local GUID path instead.
class _SelectedPhoto {
  const _SelectedPhoto({required this.path, required this.name});

  final String path;
  final String name;
}

class _UploadPageState extends State<UploadPage> {
  static const _addressKey = 'server_address';
  static const _exampleAddress = 'http://100.x.y.z:8000';
  static const _originals = MethodChannel('photo_uploader/originals');
  final _tag = TextEditingController();
  final _photos = <_SelectedPhoto>[];
  String _address = _exampleAddress;
  bool _deleteAfterUpload = true;
  bool _loading = true;
  bool _busy = false;
  bool _uploaded = false;
  bool _originalsDeleted = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _tag.dispose();
    super.dispose();
  }

  void _showMessage(Object message, {Duration duration = const Duration(seconds: 10)}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Replace messages immediately so an old exit animation cannot complete
    // after the page or ScaffoldMessenger has been disposed.
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('$message'),
        behavior: SnackBarBehavior.floating,
        duration: duration,
      ),
    );
  }

  Future<void> _initialize() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final address = preferences.getString(_addressKey) ?? _exampleAddress;
      if (mounted) setState(() => _address = address);
      final selection = await _originals.invokeMapMethod<String, dynamic>('recover');
      if (mounted && selection != null) _applySelection(selection);
    } catch (error) {
      _showMessage('초기화 실패: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySelection(Map<String, dynamic> selection) {
    setState(() {
      _photos
        ..clear()
        ..addAll((selection['photos'] as List).map((value) {
          final photo = value as Map;
          return _SelectedPhoto(
            path: photo['path'] as String,
            name: photo['name'] as String,
          );
        }));
      _uploaded = selection['uploaded'] as bool;
      // Restore the uploaded batch's choice on recovery. A new selection keeps
      // the user's current checkbox value for the next upload.
      if (_uploaded) _deleteAfterUpload = selection['deleteOriginals'] as bool;
    });
    if (_uploaded) {
      _showMessage('이전 PC 전송이 완료되었습니다. 버튼을 눌러 남은 처리를 완료하세요.');
    }
  }

  Uri _serverUri(String input) {
    final raw = input.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.host.contains('100.x.y.z') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 || uri.port > 65535) {
      throw const FormatException(
        'PC 주소를 입력하세요. 예: http://100.101.102.103:8000 (경로 제외)',
      );
    }
    return uri.replace(path: '');
  }

  Future<void> _settings() async {
    final controller = TextEditingController(text: _address);
    String? validation;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, updateDialog) => AlertDialog(
            title: const Text('PC 서버 주소'),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: _exampleAddress,
                helperText: 'Tailscale IP 또는 MagicDNS 도메인과 포트',
                errorText: validation,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final address = _serverUri(controller.text).toString();
                    final preferences = await SharedPreferences.getInstance();
                    if (!await preferences.setString(_addressKey, address)) {
                      throw StateError('주소를 저장하지 못했습니다.');
                    }
                    if (mounted) setState(() => _address = address);
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  } catch (error) {
                    if (dialogContext.mounted) {
                      updateDialog(() => validation = '$error');
                    }
                  }
                },
                child: const Text('저장'),
              ),
            ],
          ),
        ),
      );
    } finally {
      // Dialog route may still be animating out; avoid disposing its controller
      // while its TextField is mounted.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.dispose();
    }
  }

  Future<void> _pickPhotos() async {
    setState(() => _busy = true);
    try {
      final selected = await _originals.invokeMapMethod<String, dynamic>('pick');
      if (!mounted) return;
      if (selected != null) _applySelection(selected);
    } catch (error) {
      _showMessage('사진 선택 실패: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _capturePhotos() async {
    setState(() => _busy = true);
    var count = 0;
    try {
      while (mounted) {
        final selection = await _originals.invokeMapMethod<String, dynamic>('capture');
        if (!mounted || selection == null) return;
        _applySelection(selection);
        if (selection['captured'] != true) break;
        count++;
        final again = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('$count장 촬영 완료'),
            content: Text('선택 목록에 총 ${_photos.length}장이 있습니다.\n계속 촬영하시겠어요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('촬영 완료'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.camera_alt),
                label: const Text('계속 촬영'),
              ),
            ],
          ),
        );
        if (again != true) break;
      }
    } catch (error) {
      _showMessage('카메라 촬영 실패: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(_SelectedPhoto photo) => showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(title: Text(photo.name)),
            body: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 8,
                child: Image.file(File(photo.path), fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      );

  Future<void> _upload() async {
    if (_busy || _photos.isEmpty) return;
    setState(() => _busy = true);
    final client = widget.createClient?.call() ?? http.Client();
    try {
      if (!_uploaded) {
        final endpoint = _serverUri(_address).replace(path: '/upload');
        final request = http.MultipartRequest('POST', endpoint)
          ..fields['tag'] = _tag.text;
        for (final photo in _photos) {
          request.files.add(await http.MultipartFile.fromPath(
            'files', photo.path, filename: photo.name,
          ));
        }
        final response = await (() async {
          final streamed = await client.send(request);
          return http.Response.fromStream(streamed);
        })().timeout(const Duration(minutes: 10));
        if (response.statusCode != 200) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          throw HttpException(
            'HTTP ${response.statusCode}: ${body.length > 2000 ? body.substring(0, 2000) : body}',
            uri: endpoint,
          );
        }
        // A cleanup retry must never upload the same batch again.
        // Persist the acknowledgement before any original deletion, so a process
        // restart can resume deletion without sending the same batch again.
        _uploaded = true;
      }
      if (!_originalsDeleted) {
        await _originals.invokeMethod<void>('acknowledgeUpload', {
          'deleteOriginals': _deleteAfterUpload,
        });
        if (_deleteAfterUpload) {
          await _originals.invokeMethod<void>('deleteOriginals');
        }
        _originalsDeleted = true;
      }
      await _originals.invokeMethod<void>('finish');
      if (!mounted) return;
      final count = _photos.length;
      setState(() {
        _photos.clear();
        _uploaded = false;
        _originalsDeleted = false;
      });
      _showMessage(
        _deleteAfterUpload ? '$count장 전송 및 원본 삭제 완료' : '$count장 전송 완료',
        duration: const Duration(seconds: 3),
      );
    } on TimeoutException {
      _showMessage('전송 시간 초과. PC의 저장 여부를 확인한 후 재시도하세요.');
    } catch (error) {
      _showMessage(_uploaded
          ? 'PC 전송 완료. 원본 삭제 또는 완료 처리 미완료: $error'
          : '전송 실패: $error\nTailscale 연결, PC 서버와 방화벽을 확인하세요.');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _loading || _busy || _uploaded;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo Uploader'),
        actions: [
          IconButton(
            tooltip: 'PC 서버 설정',
            onPressed: locked ? null : _settings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('서버: $_address'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: locked ? null : _pickPhotos,
                      icon: const Icon(Icons.photo_library),
                      label: Text('사진 선택 (${_photos.length}장)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: locked ? null : _capturePhotos,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('카메라'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _photos.isEmpty
                        ? const Center(child: Text('갤러리에서 선택하거나 카메라로 촬영하세요.'))
                        : GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            itemCount: _photos.length,
                            itemBuilder: (context, index) => InkWell(
                              onTap: _busy || _uploaded
                                  ? null : () => _preview(_photos[index]),
                              child: widget.thumbnailBuilder?.call(_photos[index].path) ?? Image.file(
                                File(_photos[index].path),
                                fit: BoxFit.cover,
                                cacheWidth: 400,
                                errorBuilder: (_, error, stack) =>
                                    const Icon(Icons.broken_image),
                              ),
                            ),
                          ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tag,
                enabled: !locked,
                decoration: const InputDecoration(
                  labelText: '태그 (선택)', border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('전송 후 원본 삭제'),
                subtitle: const Text(
                  'PC 전송 성공 후 선택하거나 촬영한 기기 원본을 삭제합니다. '
                  '필요한 경우 삭제 확인 창이 표시됩니다.',
                ),
                value: _deleteAfterUpload,
                onChanged: locked ? null : (value) =>
                    setState(() => _deleteAfterUpload = value ?? true),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _busy || _loading || _photos.isEmpty ? null : _upload,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload),
            label: Text(_busy ? '처리 중…' : _uploaded
                ? '전송 완료 처리 계속'
                : 'PC로 전송'),
          ),
        ),
      ),
    );
  }
}
