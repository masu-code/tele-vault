/// A single chunk of a file stored as one Telegram message/document.
///
/// Files under the Telegram per-file limit have exactly one part. Larger
/// files are split into ordered parts and reassembled transparently.
class FilePart {
  /// The Telegram message id in the storage channel that holds this chunk.
  final int messageId;

  /// Zero-based order of this chunk within the file.
  final int part;

  /// Size of this chunk in bytes.
  final int size;

  const FilePart({
    required this.messageId,
    required this.part,
    required this.size,
  });

  factory FilePart.fromJson(Map<String, dynamic> json) => FilePart(
        messageId: json['message_id'] as int,
        part: json['part'] as int,
        size: json['size'] as int,
      );

  Map<String, dynamic> toJson() => {
        'message_id': messageId,
        'part': part,
        'size': size,
      };
}
