/// Pointer to one thumbnail pack (a single Telegram document, format TVTP v1)
/// recorded in the index so every device can find and install it.
class ThumbPackRef {
  /// Pack uuid (also in the message caption and the TOC).
  final String id;

  /// Telegram message id of the pack document.
  final int messageId;

  /// Number of thumbnails in the pack.
  final int count;

  /// Document size in bytes.
  final int size;

  final DateTime createdAt;

  /// Pack format version.
  final int version;

  const ThumbPackRef({
    required this.id,
    required this.messageId,
    required this.count,
    required this.size,
    required this.createdAt,
    this.version = 1,
  });

  factory ThumbPackRef.fromJson(Map<String, dynamic> json) => ThumbPackRef(
        id: json['id'] as String,
        messageId: json['message_id'] as int,
        count: json['count'] as int,
        size: json['size'] as int,
        createdAt: DateTime.parse(json['created_at'] as String),
        version: json['v'] as int? ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'message_id': messageId,
        'count': count,
        'size': size,
        'created_at': createdAt.toUtc().toIso8601String(),
        'v': version,
      };
}
