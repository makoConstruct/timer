import 'package:flutter/material.dart';

/// A transition that fades the `child` in or out before shrinking or expanding
/// to the `childs` size along the `axis`.
///
/// This can be used as a item transition in an [ImplicitlyAnimatedReorderableList].
class const RaiseAnimation({
  super.key,

  /// The animation to be used.
  required final Animation<double> animation,

  /// The curve of the animation.
  final Curve curve = Curves.easeOut,

  /// [Axis.horizontal] modifies the width,
  /// [Axis.vertical] modifies the height.
  final Axis axis = Axis.vertical,

  /// Describes how to align the child along the axis the [animation] is
  /// modifying.
  ///
  /// A value of -1.0 indicates the top when [axis] is [Axis.vertical], and the
  /// start when [axis] is [Axis.horizontal]. The start is on the left when the
  /// text direction in effect is [TextDirection.ltr] and on the right when it
  /// is [TextDirection.rtl].
  ///
  /// A value of 1.0 indicates the bottom or end, depending upon the [axis].
  ///
  /// A value of 0.0 (the default) indicates the center for either [axis] value.
  final double axisAlignment = -1.0,

  /// The child widget.
  final Widget? child,
}) extends StatefulWidget {
  @override
  State<RaiseAnimation> createState() => _RaiseAnimationState();
}

class _RaiseAnimationState extends State<RaiseAnimation> {
  @override
  void initState() {
    super.initState();
    didUpdateWidget(widget);
  }

  @override
  void didUpdateWidget(RaiseAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor:
          CurvedAnimation(parent: widget.animation, curve: widget.curve),
      axis: widget.axis,
      alignment: switch (widget.axis) {
        Axis.horizontal => AlignmentDirectional(widget.axisAlignment, -1.0),
        Axis.vertical => AlignmentDirectional(-1.0, widget.axisAlignment),
      },
      child: widget.child,
    );
  }
}
