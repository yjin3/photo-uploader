import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_page.dart';
import 'prepared_photo.dart';
import 'photo_review.dart';

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
  const UploadPage(
      {super.key, this.createClient, this.thumbnailBuilder, this.createCamera});

  final http.Client Function()? createClient;
  final Widget Function(String path)? thumbnailBuilder;
  final PhotoCamera Function()? createCamera;

  @override
  State<UploadPage> createState() => _UploadPageState();
}

// Keep the provider's display name separate from the local copy's basename.
// XFile.name on native platforms can resolve to the local GUID path instead.
class _SelectedPhoto {
  const _SelectedPhoto(
      {required this.path, required this.name, this.cropMonitor = true});

  final String path;
  final String name;
  final bool cropMonitor;
}

class _UploadPageState extends State<UploadPage> {
  static const _addressKey = 'server_address';
  static const _exampleAddress = 'http://100.x.y.z:8000';
  static const _originals = MethodChannel('photo_uploader/originals');
  final _tag = TextEditingController();
  final _photos = <_SelectedPhoto>[];
  String _address = _exampleAddress;
  bool _deleteAfterUpload = true;
  bool _cropMonitor = true;
  bool _discardPending = false;
  final _prepared = <String, PreparedPhoto>{};
  String _preparing = '';
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

  void _showMessage(Object message,
      {Duration duration = const Duration(seconds: 10)}) {
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
      final selection =
          await _originals.invokeMapMethod<String, dynamic>('recover');
      if (mounted && selection != null) _applySelection(selection);
      if (selection?['warning'] != null) _showMessage(selection!['warning']);
      if (!_uploaded && !_discardPending) await _prepareSelection();
    } catch (error) {
      _showMessage('초기화 실패: $error');
    } finally {
      if (mounted)
        setState(() {
          _loading = false;
          _preparing = '';
        });
    }
  }

  Future<void> _prepareSelection() async {
    for (var index = 0; index < _photos.length; index++) {
      final photo = _photos[index];
      if (mounted)
        setState(() => _preparing = '전송 사진 준비 ${index + 1}/${_photos.length}');
      await _preparePhoto(photo);
    }
    if (mounted) setState(() => _preparing = '');
  }

  Future<void> _preparePhoto(_SelectedPhoto photo) async {
    final data =
        await _originals.invokeMapMethod<String, dynamic>('prepareUpload', {
      'path': photo.path,
      'optimize': _cropMonitor,
    });
    if (data == null) throw StateError('전송 사진 준비 결과가 없습니다.');
    if (!mounted) return;
    setState(() => _prepared[photo.path] = PreparedPhoto.fromMap(data));
  }

  Future<void> _changeOptimization(bool value) async {
    setState(() {
      _cropMonitor = value;
      _busy = true;
      _prepared.clear();
    });
    try {
      await _prepareSelection();
    } catch (error) {
      _showMessage('전송 사진 준비 실패: $error');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _preparing = '';
        });
    }
  }

  String get _transferSummary {
    if (_prepared.length != _photos.length || _photos.isEmpty) return '';
    final source =
        _prepared.values.fold<int>(0, (sum, item) => sum + item.sourceBytes);
    final upload =
        _prepared.values.fold<int>(0, (sum, item) => sum + item.uploadBytes);
    String size(int bytes) => bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)}KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    final saved = source == 0 ? 0 : ((source - upload) * 100 / source).round();
    return '전송 ${size(upload)} / 원본 ${size(source)} · $saved% 감소';
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
            cropMonitor: photo['cropMonitor'] != false,
          );
        }));
      _prepared.removeWhere(
          (path, _) => !_photos.any((photo) => photo.path == path));
      _uploaded = selection['uploaded'] as bool;
      _discardPending = selection['discardPending'] == true;
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
        uri.port < 1 ||
        uri.port > 65535) {
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
      final selected =
          await _originals.invokeMapMethod<String, dynamic>('pick');
      if (!mounted) return;
      if (selected != null) _applySelection(selected);
      await _prepareSelection();
    } catch (error) {
      _showMessage('사진 선택 실패: $error');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _preparing = '';
        });
    }
  }

  Future<void> _capturePhotos() async {
    setState(() => _busy = true);
    try {
      await _originals.invokeMethod<void>('prepareCamera');
      if (!mounted) return;
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      _SelectedPhoto? lastCapture;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (context) => CameraPage(
          createCamera: widget.createCamera,
          initialCrop: _cropMonitor,
          buildLastPreview: () {
            final photo = lastCapture;
            if (photo == null) return const SizedBox.shrink();
            final path = _prepared[photo.path]?.path ?? photo.path;
            return widget.thumbnailBuilder?.call(path) ??
                Image.file(File(path), fit: BoxFit.contain, cacheWidth: 160);
          },
          onReviewLast: () async {
            if (lastCapture != null) await _preview(lastCapture!);
          },
          onCaptured: (path, cropMonitor) async {
            final selection = await _originals.invokeMapMethod<String, dynamic>(
                'registerCapture', {'path': path, 'cropMonitor': cropMonitor});
            if (selection == null) throw StateError('촬영 사진의 저장 결과가 없습니다.');
            if (!mounted) return;
            _applySelection(selection);
            if (cropMonitor) setState(() => _cropMonitor = true);
            lastCapture = _photos.last;
            await _preparePhoto(lastCapture!);
          },
        ),
      ));
      if (mounted) await _prepareSelection();
    } catch (error) {
      _showMessage('카메라 촬영 실패: $error');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _preparing = '';
        });
    }
  }

  Future<void> _preview(_SelectedPhoto photo) => showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: PhotoReview(
              name: photo.name,
              sourcePath: photo.path,
              uploadPath: _prepared[photo.path]?.path ?? photo.path,
              imageBuilder: widget.thumbnailBuilder,
              status: _prepared[photo.path]?.cropped == true
                  ? '모니터 크롭 적용 · 이 사진만 전송합니다.'
                  : _prepared[photo.path]?.note.isNotEmpty == true
                      ? _prepared[photo.path]!.note
                      : !_cropMonitor || !photo.cropMonitor
                          ? '크롭 없이 전체 사진을 전송합니다.'
                          : '모니터 테두리 미검출 · 전체 사진을 전송합니다.'),
        ),
      );

  Future<void> _discardPhotos(List<_SelectedPhoto>? photos) async {
    if (_busy || _loading || _uploaded) return;
    if (photos != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('사진 ${photos.length}장 삭제'),
          content: const Text('PC로 전송하지 않고 기기 원본과 목록에서 삭제합니다. 복구할 수 없습니다.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소')),
            FilledButton(
                key: const ValueKey('confirm-discard'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('사진 삭제')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final selection = await _originals.invokeMapMethod<String, dynamic>(
          'discardPhotos',
          photos == null
              ? null
              : {'paths': photos.map((photo) => photo.path).toList()});
      if (selection == null) throw StateError('사진 삭제 결과가 없습니다.');
      if (!mounted) return;
      _applySelection(selection);
      _showMessage('사진 삭제 완료 · PC로 전송하지 않았습니다.',
          duration: const Duration(seconds: 3));
    } catch (error) {
      // A batch may be partially approved. Recover the exact remaining native
      // selection instead of displaying or uploading an already deleted copy.
      if (mounted) setState(() => _discardPending = true);
      try {
        final selection =
            await _originals.invokeMapMethod<String, dynamic>('recover');
        if (mounted && selection != null) _applySelection(selection);
      } catch (_) {/* Keep upload blocked until deletion state is recovered. */}
      _showMessage('사진 삭제 미완료: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    if (_busy || _discardPending || _photos.isEmpty) return;
    setState(() => _busy = true);
    final client = widget.createClient?.call() ?? http.Client();
    try {
      if (!_uploaded) {
        // Recreate any cache files evicted since previewing; originals remain
        // registered separately and are never added as a second multipart file.
        await _prepareSelection();
        final endpoint = _serverUri(_address).replace(path: '/upload');
        final request = http.MultipartRequest('POST', endpoint)
          ..fields['tag'] = _tag.text
          ..fields['crop_monitor'] = 'false';
        for (final photo in _photos) {
          final prepared = _prepared[photo.path]!;
          request.files.add(await http.MultipartFile.fromPath(
            'files',
            prepared.path,
            filename: prepared.name,
          ));
        }
        final response = await (() async {
          final streamed = await client.send(request);
          return http.Response.fromStream(streamed);
        })()
            .timeout(const Duration(minutes: 10));
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
        _prepared.clear();
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
      if (mounted)
        setState(() {
          _busy = false;
          _preparing = '';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _loading || _busy || _uploaded || _discardPending;
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('서버: $_address'),
          if (_transferSummary.isNotEmpty) Text(_transferSummary),
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
                        itemBuilder: (context, index) =>
                            Stack(fit: StackFit.expand, children: [
                          InkWell(
                            onTap:
                                locked ? null : () => _preview(_photos[index]),
                            child: widget.thumbnailBuilder?.call(
                                    _prepared[_photos[index].path]?.path ??
                                        _photos[index].path) ??
                                Image.file(
                                  File(_prepared[_photos[index].path]?.path ??
                                      _photos[index].path),
                                  fit: BoxFit.contain,
                                  cacheWidth: 400,
                                  errorBuilder: (_, error, stack) =>
                                      const Icon(Icons.broken_image),
                                ),
                          ),
                          Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton.filledTonal(
                                key: ValueKey('discard-photo-$index'),
                                tooltip: '이 사진 삭제',
                                onPressed: locked
                                    ? null
                                    : () => _discardPhotos([_photos[index]]),
                                icon: const Icon(Icons.delete_outline),
                              ))
                        ]),
                      ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tag,
            enabled: !locked,
            decoration: const InputDecoration(
              labelText: '태그 (선택)',
              border: OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            key: const ValueKey('crop-monitor'),
            contentPadding: EdgeInsets.zero,
            title: const Text('전송 전 모니터 자르기·압축'),
            subtitle: const Text('휴대폰에서 처리 · 최대 2560px · JPEG 90'),
            value: _cropMonitor,
            onChanged:
                locked ? null : (value) => _changeOptimization(value ?? true),
          ),
          CheckboxListTile(
            key: const ValueKey('delete-originals'),
            contentPadding: EdgeInsets.zero,
            title: const Text('전송 후 원본 삭제'),
            subtitle: const Text(
              'PC 전송 성공 후 선택하거나 촬영한 기기 원본을 삭제합니다. '
              '필요한 경우 삭제 확인 창이 표시됩니다.',
            ),
            value: _deleteAfterUpload,
            onChanged: locked
                ? null
                : (value) => setState(() => _deleteAfterUpload = value ?? true),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo Uploader'),
        actions: [
          IconButton(
            key: const ValueKey('discard-all'),
            tooltip: '전체 사진 삭제',
            onPressed: locked || _photos.isEmpty
                ? null
                : () => _discardPhotos(List.of(_photos)),
            icon: const Icon(Icons.delete_sweep),
          ),
          IconButton(
            tooltip: 'PC 서버 설정',
            onPressed: locked ? null : _settings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxHeight < 400) {
          return SingleChildScrollView(
              child: SizedBox(height: 600, child: content));
        }
        return content;
      })),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _busy || _loading || _photos.isEmpty
                ? null
                : _discardPending
                    ? () => _discardPhotos(null)
                    : _upload,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload),
            label: Text(_preparing.isNotEmpty
                ? _preparing
                : _busy
                    ? '처리 중…'
                    : _discardPending
                        ? '사진 삭제 계속'
                        : _uploaded
                            ? '전송 완료 처리 계속'
                            : 'PC로 전송'),
          ),
        ),
      ),
    );
  }
}
