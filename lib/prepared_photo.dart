class PreparedPhoto {
  const PreparedPhoto({
    required this.path,
    required this.name,
    required this.sourceBytes,
    required this.uploadBytes,
    required this.cropped,
    this.note = '',
  });

  factory PreparedPhoto.fromMap(Map<String, dynamic> data) => PreparedPhoto(
        path: data['path'] as String,
        name: data['name'] as String,
        sourceBytes: (data['sourceBytes'] as num).toInt(),
        uploadBytes: (data['uploadBytes'] as num).toInt(),
        cropped: data['cropped'] == true,
        note: data['note'] as String? ?? '',
      );

  final String path;
  final String name;
  final int sourceBytes;
  final int uploadBytes;
  final bool cropped;
  final String note;
}
