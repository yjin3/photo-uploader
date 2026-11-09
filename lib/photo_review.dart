import 'dart:io';
import 'package:flutter/material.dart';

class PhotoReview extends StatefulWidget {
  const PhotoReview(
      {super.key,
      required this.name,
      required this.sourcePath,
      required this.uploadPath,
      required this.status,
      this.imageBuilder});
  final String name;
  final String sourcePath;
  final String uploadPath;
  final String status;
  final Widget Function(String path)? imageBuilder;
  @override
  State<PhotoReview> createState() => _PhotoReviewState();
}

class _PhotoReviewState extends State<PhotoReview> {
  bool _original = false;
  @override
  Widget build(BuildContext context) {
    final path = _original ? widget.sourcePath : widget.uploadPath;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.name),
          leading: IconButton(
              key: const ValueKey('close-review'),
              tooltip: '미리보기 닫기',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close))),
      body: SafeArea(
          child: Column(children: [
        SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('전송 사진')),
              ButtonSegment(value: true, label: Text('원본'))
            ],
            selected: {
              _original
            },
            onSelectionChanged: (values) =>
                setState(() => _original = values.single)),
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_original ? '기기에 저장된 원본' : widget.status,
                key: const ValueKey('review-status'))),
        Expanded(
            child: Center(
                child: InteractiveViewer(
          key: ValueKey(path),
          minScale: 0.5,
          maxScale: 8,
          child: widget.imageBuilder?.call(path) ??
              Image.file(File(path), fit: BoxFit.contain),
        ))),
      ])),
    );
  }
}
