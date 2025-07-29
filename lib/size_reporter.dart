import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A widget that sets the ValueNotifier when the layout dimensions of its child change, and also when it's first assigned.
/// Differs from SizeChangedLayoutNotifier in that it also sets the ValueNotifier on the first frame.
/// (we use this for )
class SizeReporter extends SingleChildRenderObjectWidget {
  /// note, it's a stateless widget, so you have to dispose of the notifier
  final ValueNotifier<Size?> previousSize;
  const SizeReporter({
    super.key,
    super.child,
    required this.previousSize,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSizeChangedWithCallback(
      onLayoutChangedCallback: (Size size) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousSize.value = size;
        });
      },
    );
  }
}

class _RenderSizeChangedWithCallback extends RenderProxyBox {
  _RenderSizeChangedWithCallback({
    RenderBox? child,
    required this.onLayoutChangedCallback,
  }) : super(child);

  // There's a 1:1 relationship between the _RenderSizeChangedWithCallback and
  // the `context` that is captured by the closure created by createRenderObject
  // above to assign to onLayoutChangedCallback, and thus we know that the
  // onLayoutChangedCallback will never change nor need to change.

  final void Function(Size) onLayoutChangedCallback;

  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _oldSize) {
      onLayoutChangedCallback(size);
    }
    _oldSize = size;
  }
}

class SizeFollower extends StatelessWidget {
  final ValueListenable<Size?> sizeNotifier;
  final Widget? child;
  const SizeFollower({
    super.key,
    required this.sizeNotifier,
    this.child,
  });
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: sizeNotifier,
      builder: (context, size, child) {
        // we have to use a globalkey because the initial size given by valuelistenablebuilder on the first frame is null. I don't know why that is, a comment in the code says "Don't send the initial notification, or this will be SizeObserver all over again!" I miss SizeObserver. There's an issue where someone links a reverted version of that though.
        final s = sizeNotifier.value;
        return SizedBox(
          width: s?.width ?? 0,
          height: s?.height ?? 0,
          child: child,
        );
      },
      child: child,
    );
  }
}
