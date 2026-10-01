/// Data model representing a clipboard item synced via Supabase.
class ClipboardItem {
  final String id;
  final String userId;
  final String deviceId;
  final String content;
  final DateTime createdAt;

  const ClipboardItem({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.content,
    required this.createdAt,
  });

  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'device_id': deviceId,
      'content': content,
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Returns a JSON map suitable for inserting (no id/created_at — DB generates them).
  Map<String, dynamic> toInsertJson() {
    return {
      'user_id': userId,
      'device_id': deviceId,
      'content': content,
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
      'ClipboardItem(id: $id, deviceId: $deviceId, content: ${content.length > 30 ? '${content.substring(0, 30)}...' : content})';
}
