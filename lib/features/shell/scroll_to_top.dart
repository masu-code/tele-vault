import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A request to scroll a given tab's list back to the top, raised when the
/// user taps the nav-bar destination they're already on.
///
/// [seq] exists so tapping the same tab repeatedly keeps firing: the provider
/// only notifies on a state *change*, and the tab index alone wouldn't change
/// between two taps on the same destination.
class ScrollToTopSignal {
  const ScrollToTopSignal(this.tabIndex, this.seq);

  final int tabIndex;
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is ScrollToTopSignal && other.tabIndex == tabIndex && other.seq == seq;

  @override
  int get hashCode => Object.hash(tabIndex, seq);
}

final scrollToTopProvider = StateProvider<ScrollToTopSignal?>((ref) => null);
