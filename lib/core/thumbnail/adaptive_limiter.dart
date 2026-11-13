import 'dart:async';
import 'dart:collection';

/// Concurrency limit that adapts to Telegram's pushback (AIMD): it starts at
/// [max], halves (down to [min]) each time a flood gate closes ([onFlood]) and
/// grows by one (up to [max]) after [successesToGrow] consecutive tasks that
/// ran without a flood. Queued tasks marked `priority` always start before the
/// others (FIFO inside each class). Pure logic, no clock: the wait itself is
/// the flood gate's job (see `TelegramService.call`).
class AdaptiveLimiter {
  AdaptiveLimiter({this.max = 4, this.min = 1, this.successesToGrow = 20})
      : assert(min >= 1 && max >= min),
        _limit = max;

  final int max;
  final int min;
  final int successesToGrow;

  int _limit;
  int _running = 0;
  int _successes = 0;

  /// Bumped by every [onFlood]; a task that saw it change was not a clean run.
  int _episodes = 0;

  final Queue<Completer<void>> _priorityQueue = Queue();
  final Queue<Completer<void>> _queue = Queue();

  /// Tasks allowed to run at once right now.
  int get limit => _limit;

  /// Tasks running right now.
  int get running => _running;

  /// Tasks waiting for a slot.
  int get waiting => _priorityQueue.length + _queue.length;

  /// A flood gate closed: halve the limit (never below [min]). Returns it.
  int onFlood() {
    _episodes++;
    _successes = 0;
    _limit = _limit ~/ 2 < min ? min : _limit ~/ 2;
    return _limit;
  }

  /// Runs [task] once a slot is free. [priority] tasks jump the queue.
  Future<T> run<T>(Future<T> Function() task, {bool priority = false}) async {
    if (_running >= _limit || waiting > 0) {
      final slot = Completer<void>();
      (priority ? _priorityQueue : _queue).add(slot);
      await slot.future;
    } else {
      _running++;
    }
    // A slot handed over by [_drain] is already counted in [_running].
    final startedAt = _episodes;
    var clean = false;
    try {
      final value = await task();
      clean = true;
      return value;
    } finally {
      _running--;
      if (clean && startedAt == _episodes) _onSuccess();
      _drain();
    }
  }

  void _onSuccess() {
    if (_limit >= max) return;
    if (++_successes >= successesToGrow) {
      _successes = 0;
      _limit++;
    }
  }

  void _drain() {
    while (_running < _limit) {
      final next = _priorityQueue.isNotEmpty
          ? _priorityQueue.removeFirst()
          : (_queue.isNotEmpty ? _queue.removeFirst() : null);
      if (next == null) return;
      _running++;
      next.complete();
    }
  }
}
