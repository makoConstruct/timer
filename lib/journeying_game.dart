import 'dart:collection';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:makos_timer/boring.dart';

// how generation works: you define a sequence of entity types, which have 'radius's, which are how far away they can affect the generation of other things, the lower it is the fewer need to be loaded at once. Each type is given all instances of the previous types, via the GenerationContext, within `radius` range of it, and it then generates its stuff using that.
// a core insight is that many generation stages are only useful during generation and aren't shown in the final output, they're used as skeletons or outlines by later stages to coordinate and allow things to avoid colliding and such.
// each generation type generates into the GenerationContext, which can have any structure.

class Coord {
  final int x;
  final int y;
  Coord(this.x, this.y);
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
    return Coord(x + other.x, y + other.y);
  }

  Offset toOffset() {
    return Offset(x.toDouble(), y.toDouble());
  }

  Coord operator -(Coord other) {
    return Coord(x - other.x, y - other.y);
  }

  Coord operator *(int other) {
    return Coord(x * other, y * other);
  }

  Coord operator /(int other) {
    return Coord(x ~/ other, y ~/ other);
  }

  Coord operator %(int other) {
    return Coord(x % other, y % other);
  }

  Coord operator ~/(int other) {
    return Coord(x ~/ other, y ~/ other);
  }
}

/// how far can the player pace back and forth without causing a bunch of stuff to load and unload each time. Delays layer deloading until a certain range, basically.
const double loadingBorderSlop = 2;

/// iterates over the surrounding coords, anticlockwise, starting from center right
void overSurroundingCoords(Coord coord, Function(Coord) callback) {
  callback(coord + Coord(1, 0));
  callback(coord + Coord(1, 1));
  callback(coord + Coord(0, 1));
  callback(coord + Coord(-1, 1));
  callback(coord + Coord(-1, 0));
  callback(coord + Coord(-1, -1));
  callback(coord + Coord(0, -1));
  callback(coord + Coord(1, -1));
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
    final coord = Coord((p.dx / radius).floor(), (p.dy / radius).floor());

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

// we don't have to ensure nonrepetition but if we do the below thoughts are relevant..

//pondering nonrepeating randomization. If we want to guarantee each tile is distinct from the last, but also random, but we have a limited number of tile variants (say, 9), how can this be done.
// one way is for each tile to have a set of things it can be, and for it to look at its neighbors, and pick from the exclusion of the union of its two lower neighbors' sets.
// as a safety, though this would create a not entirely random pattern, this pattern would rarely show through; we could have the sets always include x % n_variants, and y % n_variants, and exclude x - 1 and y + 1 % n_variants.
// I think you might be wanting to use a LCG, which is something that appears random but isn't, has periodic patterns.
// where lcg(x,y) is guaranteed to differ from lcg(x+1,y) and lcg(x,y+1). It lacks full randomness, but usually wont be visible. The larger n_variants, the less visible its influence becomes.
// I'm pretty sure you can make a lcg 2d by having y = x/span, where span is prime or something, in such a way that ensures that lcg(span-1, y) != lcg(0, y), and the same for the top and bottom edges as well?... maybe not. In which case oops.
// so to conclude, base_set(x,y) = random_set(hash(x,y), floor(n_variants*0.45)) + lcg(x,y) - lcg(x+1,y) - lcg(x,y+1)
// we then choose our final tile variant as choose(base_set(x,y) - base_set(x-1,y) - base_set(x,y-1))
// able to guarantee that this will at least contain lcg(x,y).

class JourneyingGameScreen extends StatefulWidget {
  const JourneyingGameScreen({super.key});

  @override
  State<JourneyingGameScreen> createState() => _JourneyingGameScreenState();
}

class _JourneyingGameScreenState extends State<JourneyingGameScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final isWide = width > height;
        final crossSpan = isWide ? height : width;
        final mainSpan = isWide ? width : height;
        const controlsMinExtent = 150.0;
        final worldSpan = (mainSpan - controlsMinExtent).clamp(0.0, crossSpan);

        final worldWidget = SizedBox(
          width: isWide ? worldSpan : worldSpan.clamp(0.0, width),
          height: isWide ? worldSpan.clamp(0.0, height) : worldSpan,
          child: Container(
            color: Colors.black12,
          ),
        );

        final controlsWidget = Expanded(
          child: Container(
            constraints: const BoxConstraints(minWidth: 150, minHeight: 150),
            padding: const EdgeInsets.all(16),
            child: const Placeholder(),
          ),
        );

        if (isWide) {
          return Row(children: [worldWidget, controlsWidget]);
        } else {
          return Column(children: [worldWidget, controlsWidget]);
        }
      }),
    );
  }
}
