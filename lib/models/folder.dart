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

  Folder copyWith({String? name, String? parentId}) => Folder(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
      );
}
