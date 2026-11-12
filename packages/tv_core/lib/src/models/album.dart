/// A manual collection of media, independent of folders. Holds file ids, so a
/// file can belong to several albums without being duplicated.
class Album {
  final String id;
  final String name;
  final List<String> fileIds;
  final DateTime createdAt;

  const Album({
    required this.id,
    required this.name,
    required this.fileIds,
    required this.createdAt,
  });

  factory Album.fromJson(Map<String, dynamic> json) => Album(
        id: json['id'] as String,
        name: json['name'] as String,
        fileIds: (json['file_ids'] as List<dynamic>? ?? []).cast<String>(),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'file_ids': fileIds,
        'created_at': createdAt.toIso8601String(),
      };

  Album copyWith({String? name, List<String>? fileIds}) => Album(
        id: id,
        name: name ?? this.name,
        fileIds: fileIds ?? this.fileIds,
        createdAt: createdAt,
      );
}
