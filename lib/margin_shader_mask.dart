import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class MarginShaderMask extends SingleChildRenderObjectWidget {
  const MarginShaderMask({
    super.key,
    required this.shaderCallback,
    this.blendMode = BlendMode.modulate,
    this.margin = 0.0,
    super.child,
  });

  final ShaderCallback shaderCallback;
  final BlendMode blendMode;
  final double margin;

  @override
  RenderMarginShaderMask createRenderObject(BuildContext context) {
    return RenderMarginShaderMask(
      shaderCallback: shaderCallback,
      blendMode: blendMode,
      margin: margin,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderMarginShaderMask renderObject) {
    renderObject
      ..shaderCallback = shaderCallback
      ..blendMode = blendMode
      ..margin = margin;
  }
}

class RenderMarginShaderMask extends RenderProxyBox {
  RenderMarginShaderMask({
    RenderBox? child,
    required ShaderCallback shaderCallback,
    BlendMode blendMode = BlendMode.modulate,
    double margin = 0.0,
  })  : _shaderCallback = shaderCallback,
        _blendMode = blendMode,
        _margin = margin,
        super(child);

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
