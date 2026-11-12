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

  /// Hidden from Gallery and Albums without being deleted — see
  /// [FileIndex.mediaFiles]/[FileIndex.archivedMediaFiles]. Defaults to false
  /// for every index written before this field existed.
  final bool archived;

  /// Optional tiny placeholder (`th1:<base64 ThumbHash>`) shown while the real
  /// thumbnail loads. Omitted from the JSON when null.
  final String? preview;

  /// JSON keys this version does not know about, preserved verbatim so a
  /// read-modify-write by an older app never drops data written by a newer one.
  /// Written after the known keys; known keys win on read.
  final Map<String, dynamic> extra;

  const FileItem({
    required this.id,
    required this.name,
    required this.folderId,
    required this.totalSize,
    required this.mimeType,
    required this.createdAt,
    required this.parts,
    this.archived = false,
    this.preview,
    this.extra = const {},
  });

  static const Set<String> _knownKeys = {
    'id',
    'name',
    'folder_id',
    'total_size',
    'mime_type',
    'created_at',
    'parts',
    'archived',
    'preview',
  };

  /// True when the file was split into more than one Telegram message.
  bool get isMultiPart => parts.length > 1;

  factory FileItem.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? extra;
    for (final e in json.entries) {
      if (!_knownKeys.contains(e.key)) (extra ??= {})[e.key] = e.value;
    }
    return FileItem(
      id: json['id'] as String,
      name: json['name'] as String,
      folderId: json['folder_id'] as String?,
      totalSize: json['total_size'] as int,
      mimeType: json['mime_type'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      parts: (json['parts'] as List<dynamic>)
          .map((e) => FilePart.fromJson(e as Map<String, dynamic>))
          .toList(),
      archived: json['archived'] as bool? ?? false,
      preview: json['preview'] as String?,
      extra: extra ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'name': name,
      'folder_id': folderId,
      'total_size': totalSize,
      'mime_type': mimeType,
      'created_at': createdAt.toIso8601String(),
      'parts': parts.map((p) => p.toJson()).toList(),
      'archived': archived,
    };
    if (preview != null) m['preview'] = preview;
    for (final e in extra.entries) {
      m.putIfAbsent(e.key, () => e.value);
    }
    return m;
  }

  /// [folderId] accepts null to move the file to the root; omit it to keep
  /// the current folder. [preview] likewise accepts null to clear it.
  /// [extra] replaces the preserved unknown keys as a whole; omit it to keep
  /// them (see [withExtra] to set a single key).
  FileItem copyWith({
    String? name,
    Object? folderId = _unset,
    bool? archived,
    Object? preview = _unset,
    Map<String, dynamic>? extra,
  }) =>
      FileItem(
        id: id,
        name: name ?? this.name,
        folderId: identical(folderId, _unset)
            ? this.folderId
            : folderId as String?,
        totalSize: totalSize,
        mimeType: mimeType,
        createdAt: createdAt,
        parts: parts,
        archived: archived ?? this.archived,
        preview: identical(preview, _unset) ? this.preview : preview as String?,
        extra: extra ?? this.extra,
      );

  /// A copy with the extra JSON key [key] set to [value], every other field
  /// and extra key unchanged. [key] must not be one of the known keys (they
  /// win on write, so the value would be lost).
  FileItem withExtra(String key, Object value) {
    assert(!_knownKeys.contains(key), 'withExtra: "$key" is a known key');
    return copyWith(extra: {...extra, key: value});
  }
}
