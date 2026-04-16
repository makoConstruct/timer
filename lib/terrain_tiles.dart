import 'dart:ui' as ui;
import 'package:flutter/painting.dart';

/// Rounding parameters for terrain tile shapes.
double rounding = 0.44;
double elbowRounding = rounding;

// ──────────────────────────────────────────────
// Cardinality
// ──────────────────────────────────────────────

/// Cardinal direction used as rotation. East = no rotation, then CW.
enum Cardinality {
  east, // 0°
  south, // 90° CW
  west, // 180°
  north; // 270° CW

  Cardinality rotatedCW([int quarters = 1]) =>
      Cardinality.values[(index + quarters) & 3];
}

// ──────────────────────────────────────────────
// Coverage masks
// ──────────────────────────────────────────────
// Bit order: UR UL BL BR  (bits 3210)
// A CW quarter-turn is a 1-bit right-rotation in this encoding.

const int kUR = 1 << 3; // 8
const int kUL = 1 << 2; // 4
const int kBL = 1 << 1; // 2
const int kBR = 1 << 0; // 1

/// Rotate a 4-bit coverage mask CW by [r].
int rotateMask(int mask, Cardinality r) {
  final q = r.index;
  mask &= 0xF;
  return ((mask >> q) | (mask << (4 - q))) & 0xF;
}

/// Build a coverage mask from four terrain-type values.
/// Returns the mask of corners that equal [terrain].
int coverageMask(int ur, int ul, int bl, int br, int terrain) {
  return (ur == terrain ? kUR : 0) |
      (ul == terrain ? kUL : 0) |
      (bl == terrain ? kBL : 0) |
      (br == terrain ? kBR : 0);
}

// ──────────────────────────────────────────────
// Tile types
// ──────────────────────────────────────────────

/// Terrain tile shapes, drawn white in a 1×1 canvas.
/// All shapes are defined at rotation 0 (canonical orientation).
enum TerrainCornerVisualTile {
  /// One convex corner filling UR. Curve from mid-right to mid-top.
  corner,

  /// Top half filled (UR + UL).
  edge,

  /// Concave inner corner (elbow) at BR. Small fill with tight rounding.
  /// Used at junctions where three corners meet.
  elbow,

  /// Entirely filled.
  full,

  /// Diagonal band connecting UR and BL through squared-off TL and BR corners.
  diagonal,

  /// Square filling just the UR quadrant.
  hindCorner,

  /// Squares filling UR and BL quadrants.
  hindCornerDuo,
}

/// Lookup: coverage mask (0–15) → (tile, rotation).
/// Mask 0 is a dummy (no tile for empty coverage).
/// The base/lowest terrain always draws as [TerrainCornerVisualTile.full] first.
const List<(TerrainCornerVisualTile, Cardinality)> tileLookup = [
  (TerrainCornerVisualTile.elbow, Cardinality.east), //  0  0000  (dummy)
  (TerrainCornerVisualTile.corner, Cardinality.east), //  1  0001  BR
  (TerrainCornerVisualTile.corner, Cardinality.south), //  2  0010  BL
  (TerrainCornerVisualTile.edge, Cardinality.east), //  3  0011  BL+BR
  (TerrainCornerVisualTile.corner, Cardinality.west), //  4  0100  UL
  (TerrainCornerVisualTile.diagonal, Cardinality.east), //  5  0101  UL+BR
  (TerrainCornerVisualTile.edge, Cardinality.south), //  6  0110  UL+BL
  (TerrainCornerVisualTile.elbow, Cardinality.east), //  7  0111  UL+BL+BR
  (TerrainCornerVisualTile.corner, Cardinality.north), //  8  1000  UR
  (TerrainCornerVisualTile.edge, Cardinality.north), //  9  1001  UR+BL
  (TerrainCornerVisualTile.diagonal, Cardinality.south), // 10  1010  UR+BR
  (TerrainCornerVisualTile.elbow, Cardinality.north), // 11  1011  UR+BR+BL
  (TerrainCornerVisualTile.edge, Cardinality.west), // 12  1100  UR+UL
  (TerrainCornerVisualTile.elbow, Cardinality.west), // 13  1101  UR+UL+BR
  (TerrainCornerVisualTile.elbow, Cardinality.south), // 14  1110  UR+UL+BL
  (TerrainCornerVisualTile.full, Cardinality.east), // 15  1111  full
];

// ──────────────────────────────────────────────
// Tile paths
// ──────────────────────────────────────────────

final _white = Paint()
  ..color = const Color(0xFFFFFFFF)
  ..style = PaintingStyle.fill;

Path _tilePath(TerrainCornerVisualTile tile) {
  final r = rounding;
  final er = elbowRounding;
  final path = Path();

  const midR = Offset(1, 0.5);
  const midT = Offset(0.5, 0);
  const midB = Offset(0.5, 1);
  const midL = Offset(0, 0.5);
  const center = Offset(0.5, 0.5);

  switch (tile) {
    case TerrainCornerVisualTile.corner:
      path.moveTo(1, 0.5);
      _roundedCorner(path, midR, center, midB, r);
      path.lineTo(1, 1);
      path.close();

    case TerrainCornerVisualTile.edge:
      path.addRect(const Rect.fromLTRB(0, 0.5, 1, 1));

    case TerrainCornerVisualTile.elbow:
      path.moveTo(1, 0.5);
      _roundedCorner(path, midR, center, midT, er);
      path.lineTo(0, 0);
      path.lineTo(0, 1);
      path.lineTo(1, 1);
      path.close();

    case TerrainCornerVisualTile.full:
      path.addRect(const Rect.fromLTRB(0, 0, 1, 1));

    case TerrainCornerVisualTile.diagonal:
      path.moveTo(1, 0.5);
      _roundedCorner(path, midR, center, midT, r);
      path.lineTo(0, 0);
      path.lineTo(0, 0.5);
      _roundedCorner(path, midL, center, midB, r);
      path.lineTo(1, 1);
      path.close();

    case TerrainCornerVisualTile.hindCorner:
      path.addRect(const Rect.fromLTRB(0.5, 0, 1, 0.5));

    case TerrainCornerVisualTile.hindCornerDuo:
      path.addRect(const Rect.fromLTRB(0.5, 0, 1, 0.5));
      path.addRect(const Rect.fromLTRB(0, 0.5, 0.5, 1));
  }

  return path;
}

void _roundedCorner(Path path, Offset start, Offset c, Offset end, double r) {
  if (r <= 0) {
    path.lineTo(c.dx, c.dy);
    path.lineTo(end.dx, end.dy);
    return;
  }
  final dir1 = (start - c) / (start - c).distance;
  final dir2 = (end - c) / (end - c).distance;
  final p1 = c + dir1 * r;
  final p2 = c + dir2 * r;
  path.lineTo(p1.dx, p1.dy);
  final cross = dir1.dx * dir2.dy - dir1.dy * dir2.dx;
  path.arcToPoint(
    p2,
    radius: Radius.circular(r),
    largeArc: false,
    clockwise: cross < 0,
  );
  path.lineTo(end.dx, end.dy);
}

ui.Image buildTerrainAtlas(int tileSize) {
  final tiles = TerrainCornerVisualTile.values;
  final atlasW = tileSize * tiles.length;
  final atlasH = tileSize;

  final rec = ui.PictureRecorder();
  final canvas = Canvas(
    rec,
    Rect.fromLTWH(0, 0, atlasW.toDouble(), atlasH.toDouble()),
  );

  for (var i = 0; i < tiles.length; i++) {
    canvas.save();
    canvas.translate(i * tileSize.toDouble(), 0);
    canvas.scale(tileSize.toDouble());
    canvas.drawPath(_tilePath(tiles[i]), _white);
    canvas.restore();
  }

  final picture = rec.endRecording();
  final image = picture.toImageSync(atlasW, atlasH);
  picture.dispose();
  return image;
}

Rect terrainTileAtlasSrcRect(TerrainCornerVisualTile tile, int tileSize) {
  final i = tile.index;
  return Rect.fromLTWH(
    i * tileSize.toDouble(),
    0,
    tileSize.toDouble(),
    tileSize.toDouble(),
  );
}

/// takes the types of four land tiles adjacent to the cornertile you're assembling, and returns a layer of TerrainTiles at rotations that would paint that
List<(TerrainCornerVisualTile, Cardinality, int)> tilesForPlaces(
  int ur,
  int ul,
  int bl,
  int br,
) {
  List<(TerrainCornerVisualTile, Cardinality, int)> tiles = [];
  void consider(int type) {
    if (tiles.any((t) => t.$3 == type)) return;
    final r = coverageMask(ur, ul, bl, br, type);
    if (r == 0) return;
    final tl = tileLookup[r];
    tiles.add((tl.$1, tl.$2, type));
  }

  consider(ur);
  consider(ul);
  consider(bl);
  consider(br);
  tiles.sort((a, b) => a.$3.compareTo(b.$3));
  return tiles;
}
