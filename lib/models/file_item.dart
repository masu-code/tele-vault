import 'file_part.dart';

/// Distinguishes "argument omitted" from "explicitly set to null" in copyWith.
const Object _unset = Object();

/// A logical file as presented in the app. May span multiple Telegram
/// messages (parts) but is shown to the user as a single file.
class FileItem {
  final String id;
  final String name;

  /// Parent folder id, or null when the file lives at the root.
  final String? folderId;

  /// Total size in bytes across all parts.
  final int totalSize;

  final String mimeType;
  final DateTime createdAt;

  /// Ordered chunks. Length 1 for files under the Telegram limit.
  final List<FilePart> parts;

  const FileItem({
    required this.id,
    required this.name,
    required this.folderId,
    required this.totalSize,
    required this.mimeType,
    required this.createdAt,
    required this.parts,
  });

  /// True when the file was split into more than one Telegram message.
  bool get isMultiPart => parts.length > 1;

  factory FileItem.fromJson(Map<String, dynamic> json) => FileItem(
        id: json['id'] as String,
        name: json['name'] as String,
        folderId: json['folder_id'] as String?,
        totalSize: json['total_size'] as int,
        mimeType: json['mime_type'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        parts: (json['parts'] as List<dynamic>)
            .map((e) => FilePart.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'folder_id': folderId,
        'total_size': totalSize,
        'mime_type': mimeType,
        'created_at': createdAt.toIso8601String(),
        'parts': parts.map((p) => p.toJson()).toList(),
      };

  /// [folderId] accepts null to move the file to the root; omit it to keep
  /// the current folder.
  FileItem copyWith({String? name, Object? folderId = _unset}) => FileItem(
        id: id,
        name: name ?? this.name,
        folderId: identical(folderId, _unset)
            ? this.folderId
            : folderId as String?,
        totalSize: totalSize,
        mimeType: mimeType,
        createdAt: createdAt,
        parts: parts,
      );
}
