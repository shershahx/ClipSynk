/// What kind of data a clipboard item holds.
enum ClipKind {
  text,
  image,
  file;

  static ClipKind parse(String? value) {
    switch (value) {
      case 'image':
        return ClipKind.image;
      case 'file':
        return ClipKind.file;
      default:
        return ClipKind.text;
    }
  }
}

/// Data model representing a clipboard item synced via Supabase.
///
/// For [ClipKind.text] items, [content] is the text. For image/file items,
/// [content] is the file name (kept non-empty for the NOT NULL column) and the
/// bytes live in Supabase Storage at [storagePath].
class ClipboardItem {
  final String id;
  final String userId;
  final String deviceId;
  final String content;
  final DateTime createdAt;
  final ClipKind kind;
  final String? fileName;
  final String? mimeType;
  final int? sizeBytes;
  final String? storagePath;

  const ClipboardItem({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.content,
    required this.createdAt,
    this.kind = ClipKind.text,
    this.fileName,
    this.mimeType,
    this.sizeBytes,
    this.storagePath,
  });

  bool get isMedia => kind != ClipKind.text;
  bool get isImage => kind == ClipKind.image;

  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      content: (json['content'] as String?) ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
      kind: ClipKind.parse(json['kind'] as String?),
      fileName: json['file_name'] as String?,
      mimeType: json['mime_type'] as String?,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      storagePath: json['storage_path'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'device_id': deviceId,
      'content': content,
      'created_at': createdAt.toIso8601String(),
      'kind': kind.name,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'storage_path': storagePath,
    };
  }

  /// Returns a JSON map suitable for inserting (no id/created_at — DB generates them).
  ///
  /// Media columns are only included for media items, so plain text keeps
  /// working against a database that hasn't been migrated yet.
  Map<String, dynamic> toInsertJson() {
    return {
      'user_id': userId,
      'device_id': deviceId,
      'content': content,
      if (isMedia) ...{
        'kind': kind.name,
        'file_name': fileName,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'storage_path': storagePath,
      },
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipboardItem &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ClipboardItem(id: $id, kind: ${kind.name}, deviceId: $deviceId, content: ${content.length > 30 ? '${content.substring(0, 30)}...' : content})';
}
