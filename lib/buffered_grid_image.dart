import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:makos_timer/journeying_game.dart' show Coord;

int _mod(int a, int b) => ((a % b) + b) % b;

/// A ring-buffered tile image that caches rendered tiles and composites them
/// into a single GPU-resident image. When the camera moves past a tile
/// boundary, only the newly visible tiles are painted over the existing
/// composite (using BlendMode.src to fully replace). The buffer wraps in both
/// axes, so rendering to screen requires up to 4 drawImageRect calls.
class BufferedGridImage {
  final void Function(Canvas canvas, Coord tileCoord) paintTile;

  int tilePixelSize = 0;
  int bufferW = 0;
  int bufferH = 0;
  ui.Image? composite;
  int _visMinX = 0, _visMaxX = 0, _visMinY = 0, _visMaxY = 0;

  BufferedGridImage({required this.paintTile});

  /// Call when viewport size or resolution changes.
  /// [viewWidth]/[viewHeight] in world units (tiles).
  /// [tilePixelSize] controls buffer resolution per tile.
  void resize(double viewWidth, double viewHeight, int tilePixelSize) {
    final newW = viewWidth.ceil() + 3;
    final newH = viewHeight.ceil() + 3;
    if (newW != bufferW ||
        newH != bufferH ||
        tilePixelSize != this.tilePixelSize) {
      _disposeAll();
      this.tilePixelSize = tilePixelSize;
      bufferW = newW;
      bufferH = newH;
    }
  }

  /// Update camera position (world coords). Renders new tiles and
  /// incrementally composites them (source-overwrite) synchronously.
  void moveCamera(Offset center) {
    if (bufferW == 0) return;

    final minX = (center.dx - bufferW / 2).floor();
    final minY = (center.dy - bufferH / 2).floor();
    final maxX = minX + bufferW - 1;
    final maxY = minY + bufferH - 1;

    if (minX == _visMinX && minY == _visMinY) return;

    final changed = <({int bx, int by, Coord tile})>[];

    void addTile(int wx, int wy) {
      final bx = _mod(wx, bufferW);
      final by = _mod(wy, bufferH);
      changed.add((bx: bx, by: by, tile: Coord(wx, wy)));
    }

    if (composite == null) {
      // First call — populate everything
      for (int wy = minY; wy <= maxY; wy++) {
        for (int wx = minX; wx <= maxX; wx++) {
          addTile(wx, wy);
        }
      }
    } else {
      // X strips: new columns that entered the view
      if (minX < _visMinX) {
        for (int wx = minX; wx < _visMinX; wx++) {
          for (int wy = minY; wy <= maxY; wy++) addTile(wx, wy);
        }
      } else if (maxX > _visMaxX) {
        for (int wx = _visMaxX + 1; wx <= maxX; wx++) {
          for (int wy = minY; wy <= maxY; wy++) addTile(wx, wy);
        }
      }
      // Y strips: new rows that entered the view (excluding corners already covered)
      if (minY < _visMinY) {
        final xLo = minX.clamp(_visMinX, maxX + 1);
        final xHi = maxX.clamp(minX - 1, _visMaxX);
        for (int wy = minY; wy < _visMinY; wy++) {
          for (int wx = xLo; wx <= xHi; wx++) addTile(wx, wy);
        }
      } else if (maxY > _visMaxY) {
        final xLo = minX.clamp(_visMinX, maxX + 1);
        final xHi = maxX.clamp(minX - 1, _visMaxX);
        for (int wy = _visMaxY + 1; wy <= maxY; wy++) {
          for (int wx = xLo; wx <= xHi; wx++) addTile(wx, wy);
        }
      }
    }

    _visMinX = minX;
    _visMaxX = maxX;
    _visMinY = minY;
    _visMaxY = maxY;

    if (changed.isNotEmpty) _updateComposite(changed);
  }

  /// Render the buffered image onto [canvas]. Assumes the canvas is in
  /// world-space coordinates (1 unit = 1 tile), with transforms already
  /// applied for camera centering and scaling.
  static final Paint _renderPaint = Paint()
    ..isAntiAlias = false
    ..filterQuality = FilterQuality.low;

  void render(Canvas canvas) {
    final img = composite;
    if (img == null) return;

    final px = tilePixelSize.toDouble();
    final bMinX = _mod(_visMinX, bufferW);
    final bMaxX = _mod(_visMaxX, bufferW);
    final bMinY = _mod(_visMinY, bufferH);
    final bMaxY = _mod(_visMaxY, bufferH);

    final xSpans = <(int, int, int)>[];
    if (bMinX <= bMaxX) {
      xSpans.add((bMinX, bMaxX, _visMinX));
    } else {
      xSpans.add((bMinX, bufferW - 1, _visMinX));
      xSpans.add((0, bMaxX, _visMinX + (bufferW - bMinX)));
    }

    final ySpans = <(int, int, int)>[];
    if (bMinY <= bMaxY) {
      ySpans.add((bMinY, bMaxY, _visMinY));
    } else {
      ySpans.add((bMinY, bufferH - 1, _visMinY));
      ySpans.add((0, bMaxY, _visMinY + (bufferH - bMinY)));
    }

    for (final (bx0, bx1, wx0) in xSpans) {
      for (final (by0, by1, wy0) in ySpans) {
        canvas.drawImageRect(
          img,
          Rect.fromLTRB(bx0 * px, by0 * px, (bx1 + 1) * px, (by1 + 1) * px),
          Rect.fromLTWH(
            wx0.toDouble(),
            wy0.toDouble(),
            (bx1 - bx0 + 1).toDouble(),
            (by1 - by0 + 1).toDouble(),
          ),
          _renderPaint,
        );
      }
    }
  }

  void _updateComposite(List<({int bx, int by, Coord tile})> changedSlots) {
    final px = tilePixelSize.toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    if (composite != null) {
      canvas.drawImage(composite!, Offset.zero, Paint());
    }

    for (final (:bx, :by, :tile) in changedSlots) {
      canvas.save();
      canvas.translate(bx * px, by * px);
      canvas.clipRect(Rect.fromLTWH(0, 0, px, px), doAntiAlias: false);
      canvas.scale(px);
      paintTile(canvas, tile);
      canvas.restore();
    }

    final old = composite;
    final full = rec.endRecording();
    composite = full.toImageSync(
      bufferW * tilePixelSize,
      bufferH * tilePixelSize,
    );
    full.dispose();
    old?.dispose();
  }

  void _disposeAll() {
    composite?.dispose();
    composite = null;
  }

  void dispose() => _disposeAll();
}
