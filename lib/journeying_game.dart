import 'dart:collection';
import 'dart:ui';

import 'package:makos_timer/boring.dart';

// how generation works: you define a sequence of entity types, which have 'radius's, which are how far away they can affect the generation of other things, the lower it is the fewer need to be loaded at once. Each type is given all instances of the previous types, via the GenerationContext, within `radius` range of it, and it then generates its stuff using that.
// a core insight is that many generation stages are only useful during generation and aren't shown in the final output, they're used as skeletons or outlines by later stages to coordinate and allow things to avoid colliding and such.
// each generation type generates into the GenerationContext, which can have any structure.

class Coord {
  final int x;
  final int y;
  Coord({required this.x, required this.y});
  @override
  String toString() {
    return 'Coord(x: $x, y: $y)';
  }

  @override
  bool operator ==(Object other) {
    return other is Coord && other.x == x && other.y == y;
  }

  @override
  int get hashCode => x.hashCode ^ y.hashCode;
  Coord operator +(Coord other) {
    return Coord(x: x + other.x, y: y + other.y);
  }

  Offset toOffset() {
    return Offset(x.toDouble(), y.toDouble());
  }

  Coord operator -(Coord other) {
    return Coord(x: x - other.x, y: y - other.y);
  }

  Coord operator *(int other) {
    return Coord(x: x * other, y: y * other);
  }

  Coord operator /(int other) {
    return Coord(x: x ~/ other, y: y ~/ other);
  }

  Coord operator %(int other) {
    return Coord(x: x % other, y: y % other);
  }

  Coord operator ~/(int other) {
    return Coord(x: x ~/ other, y: y ~/ other);
  }
}

/// how far can the player pace back and forth without causing a bunch of stuff to load and unload each time. Delays layer deloading until a certain range, basically.
const double loadingBorderSlop = 2;

/// iterates over the surrounding coords, anticlockwise, starting from center right
void overSurroundingCoords(Coord coord, Function(Coord) callback) {
  callback(coord + Coord(x: 1, y: 0));
  callback(coord + Coord(x: 1, y: 1));
  callback(coord + Coord(x: 0, y: 1));
  callback(coord + Coord(x: -1, y: 1));
  callback(coord + Coord(x: -1, y: 0));
  callback(coord + Coord(x: -1, y: -1));
  callback(coord + Coord(x: 0, y: -1));
  callback(coord + Coord(x: 1, y: -1));
}

/// contains one type of thing, in a grid, where the cells of the grid correspond to the radius of effect of that type of thing.
class GenerationLayer<T, GC extends GenerationContext,
    GT extends GenerationThingType<GC>> {
  final double radius;
  final HashMap<Coord, List<T>> loadedCells = HashMap();
  final GT generator;
  GenerationLayer({required this.radius, required this.generator});

  /// todo: this needs to consider the camera bounds, not the position of the player
  void moveTo(GC gc, Offset p) {
    final coord = Coord(x: (p.dx / radius).floor(), y: (p.dy / radius).floor());

    overSurroundingCoords(coord, (c) {
      // Compute cellSeed as a hash function of gc.seed, generator.name, and c
      final cellSeed = Object.hash(
        gc.seed,
        generator,
        c,
      );
      if (!loadedCells.containsKey(c)) {
        loadedCells[c] = generator.generate(gc, cellSeed, coord.toOffset());
      }
    });
    // deload any cell that's now further than loadingBorderSlop from p
    for (final c in loadedCells.keys) {
      if (rectPointDistance(
              Rect.fromPoints(
                  c.toOffset(), c.toOffset() + Offset(radius, radius)),
              p) >
          radius + loadingBorderSlop) {
        loadedCells.remove(c);
      }
    }
  }
}

abstract class GenerationContext {
  final int seed;
  final double radius;
  final LinkedHashMap<GenerationThingType, List<Object>> things =
      LinkedHashMap();
  GenerationContext({required this.seed, required this.radius});
}

// a kind of thing that generates that has a location, which other things might react to when they generate.
// quite a foundational element of the procedural generation artform.
class GenerationThingType<GC extends GenerationContext> {
  //. should be unique, used to generate the hashCode
  final String name;
  @override
  final int hashCode;
  @override
  bool operator ==(Object other) {
    return other is GenerationThingType && other.hashCode == hashCode;
  }

  /// from how far away can this affect the generation of other things? What's its radius of impact? The larger this is, the more will be loaded at once, the less efficient the generation process will be.
  final double radius;
  final Function(GC gc, int cellSeed, Offset cellOrigin) generate;
  GenerationThingType({
    required this.name,
    required this.radius,
    required this.generate,
  }) : hashCode = name.hashCode;
}
