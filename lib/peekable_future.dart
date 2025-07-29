import 'dart:async';

/// The result of a computation, which may or may not be available synchronously already via `T? peek`.
/// Useful when responding synchronously would actually be nice. Example: The `PeekableFutureBuilder` widget, which is able to render straight away without a blank flash if the Future is already resolved (`FutureBuilders` can't avoid the flash).
class PeekableFuture<T> {
  T? _value;
  Future<T>? _future;

  PeekableFuture({T? initialValue, Future<T>? future})
      : _value = initialValue,
        _future = future {
    assert((initialValue != null) == (future != null),
        "Either initialValue or future must be provided");
    if (future != null) {
      future.then((value) {
        _value = value;
        _future = null;
      });
    }
  }
  factory PeekableFuture.value(T value) => PeekableFuture(initialValue: value);

  Future<T> get() async {
    if (_future == null) {
      return _value!;
    }

    return _future!;
  }

  Future<T> then(FutureOr<T> Function(T) onValue) {
    return get().then((value) {
      return onValue(value);
    });
  }

  T? get peek => _value;
}
