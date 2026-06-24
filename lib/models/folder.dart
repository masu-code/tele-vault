/// Distinguishes "argument omitted" from "explicitly set to null" in copyWith.
const Object _unset = Object();

/// A virtual folder. Folders exist only in the index — Telegram itself has
/// no folder concept for stored files.
class Folder {
  final String id;
  final String name;

  /// Parent folder id, or null for a top-level folder.
  final String? parentId;

  const Folder({
    required this.id,
    required this.name,
    required this.parentId,
  });

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parent_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parent_id': parentId,
      };

  /// [parentId] accepts null to move the folder to the root; omit it to keep
  /// the current parent.
  Folder copyWith({String? name, Object? parentId = _unset}) => Folder(
        id: id,
        name: name ?? this.name,
        parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
      );
}
