/// A list wrapper whose `==` compares elements by identity, so it can be the
/// value of a Riverpod `select`: a screen watching a derived list only
/// rebuilds when an element was added, removed, or replaced — not every time
/// the whole index object is swapped for one with the same members.
///
/// Identity (not `==`) per element is deliberate: immutable model objects are
/// replaced on edit, so a changed item still triggers a rebuild, and an
/// unchanged one costs nothing to compare.
class IdentityList<T> {
  const IdentityList(this.items);

  final List<T> items;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! IdentityList<T>) return false;
    final a = items, b = other.items;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(items.length, items.isEmpty ? 0 : identityHashCode(items.first));
}
