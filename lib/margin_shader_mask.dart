import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class const MarginShaderMask({
  super.key,
  required final ShaderCallback shaderCallback,
  final BlendMode blendMode = BlendMode.modulate,
  final double margin = 0.0,
  super.child,
}) extends SingleChildRenderObjectWidget {
  @override
  RenderMarginShaderMask createRenderObject(BuildContext context) {
    return RenderMarginShaderMask(
      shaderCallback: shaderCallback,
      blendMode: blendMode,
      margin: margin,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarginShaderMask renderObject,
  ) {
    renderObject
      ..shaderCallback = shaderCallback
      ..blendMode = blendMode
      ..margin = margin;
  }
}

class RenderMarginShaderMask({
  RenderBox? child,
  required this._shaderCallback,
  this._blendMode = BlendMode.modulate,
  this._margin = 0.0,
}) extends RenderProxyBox {
  this : super(child);

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  ShaderCallback get shaderCallback => _shaderCallback;
  ShaderCallback _shaderCallback;
  set shaderCallback(ShaderCallback value) {
    if (_shaderCallback == value) {
      return;
    }
    _shaderCallback = value;
    markNeedsPaint();
  }

  BlendMode get blendMode => _blendMode;
  BlendMode _blendMode;
  set blendMode(BlendMode value) {
    if (_blendMode == value) {
      return;
    }
    _blendMode = value;
    markNeedsPaint();
  }

  double get margin => _margin;
  double _margin;
  set margin(double value) {
    if (_margin == value) {
      return;
    }
    _margin = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) {
      assert(needsCompositing);
      layer ??= ShaderMaskLayer();

      final expandedRect = Rect.fromLTRB(
        -_margin,
        -_margin,
        size.width + _margin,
        size.height + _margin,
      );

      final expandedMaskRect = Rect.fromLTRB(
        offset.dx - _margin,
        offset.dy - _margin,
        offset.dx + size.width + _margin,
        offset.dy + size.height + _margin,
      );

      layer!
        ..shader = _shaderCallback(expandedRect)
        ..maskRect = expandedMaskRect
        ..blendMode = _blendMode;
      context.pushLayer(layer!, super.paint, offset);
      assert(() {
        layer!.debugCreator = debugCreator;
        return true;
      }());
    } else {
      layer = null;
    }
  }
}
