/*
I stopped working on this right before getting the trees to become active and render. I realized the work was making me hate myself. I did not set out to make a video game with this project. I think this video game never would have been particularly fun. Games need some immersion or dexterity challenge to be fun. The UI here is too minimalistic, even if the strategy layer is quite good, it wont immerse people. But even if it did, I don't remember why I felt this needed to be made. It's certainly not the thing I should be doing.

Just so that you know where it was at, this was the final prompt that I decided not to run.
```
Move reactive game state into a GameState mobj that's passed to the widgets that need it. Includes:

GameStateType help.
prepare a new static uuid for a single global Mobj<GameState>.

Signal<List<Signal<JWorldEntity>>> seatedEntities (for entities that haven't been interacted with since generation, or are in their default state, so need to be loaded and deloaded as the camera moves),
Mobj<List<MobjID>> unseatedEntities (for the others, which are always live)
Mobj<Coord> playerPos, which replaces the camera signal.
terrainAt should be moved into GameState
are we able to generate UUIDs from hashes?

Computed<Set<Signal<JWorldEntity>>>> liveEntityLookup, which is computed from the above two

Whenever a new tile is loaded or deloaded, (in response to camera movement)

Then make EntityPainter real.
```
 */

import 'dart:collection';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/buffered_grid_image.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/main.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:makos_timer/noise_generators.dart';
import 'package:makos_timer/terrain_tiles.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:signals/signals_flutter.dart';

// how generation works: you define a sequence of entity types, which have 'radius's, which are how far away they can affect the generation of other things, the lower it is the fewer need to be loaded at once. Each type is given all instances of the previous types, via the GenerationContext, within `radius` range of it, and it then generates its stuff using that.
// a core insight is that many generation stages are only useful during generation and aren't shown in the final output, they're used as skeletons or outlines by later stages to coordinate and allow things to avoid colliding and such.
// each generation type generates into the GenerationContext, which can have any structure.

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
class GenerationLayer<
  T,
  GC extends GenerationContext,
  GT extends GenerationThingType<GC>
> {
  final double radius;
  final HashMap<Coord, List<T>> loadedCells = HashMap();
  final GT generator;
  GenerationLayer({required this.radius, required this.generator});

  /// todo: this needs to consider the camera bounds, not the position of the player
  void moveTo(GC gc, Offset p) {
    final coord = Coord((p.dx / radius).floor(), (p.dy / radius).floor());

    overSurroundingCoords(coord, (c) {
      // Compute cellSeed as a hash function of gc.seed, generator.name, and c
      final cellSeed = Object.hash(gc.seed, generator, c);
      if (!loadedCells.containsKey(c)) {
        loadedCells[c] = generator.generate(gc, cellSeed, coord.toOffset());
      }
    });
    // deload any cell that's now further than loadingBorderSlop from p
    for (final c in loadedCells.keys) {
      if (rectPointDistance(
            Rect.fromPoints(
              c.toOffset(),
              c.toOffset() + Offset(radius, radius),
            ),
            p,
          ) >
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

// ──────────────────────────────────────────────
// Assets & loading
// ──────────────────────────────────────────────

const int atlasTileSize = 64;

const _treeAssets = [
  'assets/journey/tree p1.svg',
  'assets/journey/tree c2.svg',
  'assets/journey/tree r3.svg',
  'assets/journey/tree o4.svg',
];

late ui.Image terrainAtlas;
late ui.Image treeAtlas;

Future<void> loadJourneyAssets() async {
  terrainAtlas = buildTerrainAtlas(atlasTileSize);
  treeAtlas = await _buildTreeAtlas(atlasTileSize);
}

Future<ui.Image> _buildTreeAtlas(int tileSize) async {
  final rec = ui.PictureRecorder();
  final w = tileSize * _treeAssets.length;
  final canvas = Canvas(
    rec,
    Rect.fromLTWH(0, 0, w.toDouble(), tileSize.toDouble()),
  );

  for (var i = 0; i < _treeAssets.length; i++) {
    final loader = SvgAssetLoader(_treeAssets[i]);
    final info = await vg.loadPicture(loader, null, clipViewbox: false);
    canvas.save();
    canvas.translate(i * tileSize.toDouble(), 0);
    canvas.scale(tileSize / info.size.width, tileSize / info.size.height);
    canvas.drawPicture(info.picture);
    info.picture.dispose();
    canvas.restore();
  }

  final picture = rec.endRecording();
  final image = picture.toImageSync(w, tileSize);
  picture.dispose();
  return image;
}

Rect _treeSrcRect(int kind) {
  final ts = atlasTileSize.toDouble();
  return Rect.fromLTWH(kind * ts, 0, ts, ts);
}

// ──────────────────────────────────────────────
// Entities
// ──────────────────────────────────────────────

abstract class JWorldEntity {
  Coord? get position;
  JKind get kind;
  void paint(Canvas canvas);
}

abstract class JCarryable extends JWorldEntity {
  bool get inventoried => position == null;
  List<JKind> get liftRequirements;
  int get carriageDistance;
}

class JTree extends JCarryable {
  final int seed;
  Coord? _position;

  JTree({required this.seed, required Coord position}) : _position = position;

  @override
  Coord? get position => _position;

  set position(Coord? value) => _position = value;

  @override
  JKind get kind => JKind.tree;

  @override
  List<JKind> get liftRequirements => [];

  @override
  int get carriageDistance => 13;

  int get treeKind => hashThree(seed, 0, 0xA) % 4;

  Offset get jitter {
    final h1 = hashThree(seed, 0, 0x7A91);
    final h2 = hashThree(seed, 0, 0x7A92);
    final angle = scalarFromHashInt(h1) * 2 * pi;
    final length = scalarFromHashInt(h2);
    return angleToOffset(angle) * length;
  }

  @override
  void paint(Canvas canvas) {
    if (_position == null) return;
    final p = _position!.toOffset() + jitter * 0.2;
    canvas.drawImageRect(
      treeAtlas,
      _treeSrcRect(treeKind),
      Rect.fromLTWH(p.dx, p.dy, 1, 1),
      Paint()..filterQuality = FilterQuality.low,
    );
  }
}

class JWorldEntityType extends TypeHelp<JWorldEntity> {
  JWorldEntityType() : super('JWorldEntity');

  @override
  JWorldEntity fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      final kind = JKind.values[IntType().fromJson(json['kind'])];
      switch (kind) {
        case JKind.tree:
          return JTree(
            seed: IntType().fromJson(json['seed']),
            position: CoordType().fromJson(json['position']),
          );
      }
    }
    throw ArgumentError('Cannot convert $json to JWorldEntity');
  }

  @override
  Object? toJsonValue(JWorldEntity object) {
    final base = {
      'kind': IntType().toJson(object.kind.index),
      'position': object.position != null
          ? CoordType().toJson(object.position!)
          : null,
    };
    if (object is JTree) {
      base['seed'] = IntType().toJson(object.seed);
    }
    return base;
  }
}

List<JTree> spawnTrees(
  int cellSeed,
  Coord cellOrigin,
  int cellSize,
  TerrainKind Function(Coord) terrainAt,
) {
  final trees = <JTree>[];
  for (var dy = 0; dy < cellSize; dy++) {
    for (var dx = 0; dx < cellSize; dx++) {
      final coord = cellOrigin + Coord(dx, dy);
      final h = hashThree(coord.x, coord.y, cellSeed);
      if (terrainAt(coord) == TerrainKind.grass && h % 10 == 0) {
        trees.add(JTree(seed: h, position: coord));
      }
    }
  }
  return trees;
}

// ──────────────────────────────────────────────
// Game UI
// ──────────────────────────────────────────────

class JourneyingGameScreen extends StatefulWidget {
  const JourneyingGameScreen({super.key});

  @override
  State<JourneyingGameScreen> createState() => _JourneyingGameScreenState();
}

class _JourneyingGameScreenState extends State<JourneyingGameScreen> {
  Offset movementControlAccumulator = Offset.zero;
  late final Future<void> _assetsFuture;

  final Signal<Coord> camera = signal(Coord(0, 0));

  @override
  void initState() {
    super.initState();
    _assetsFuture = loadJourneyAssets();
  }

  void movePlayerBy(Coord coord) {
    camera.value = camera.value + coord;
  }

  @override
  Widget build(BuildContext context) {
    final thumbSpan = Thumbspan.of(context);
    final double movementControlThreshold = thumbSpan * 0.27;
    return Scaffold(
      body: FutureBuilder<void>(
        future: _assetsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading assets: ${snapshot.error}'),
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              final isWide = width > height;
              final crossSpan = isWide ? height : width;
              final mainSpan = isWide ? width : height;
              const controlsMinExtent = 150.0;
              final worldSpan = (mainSpan - controlsMinExtent).clamp(
                0.0,
                crossSpan,
              );

              final worldWidget = SizedBox(
                width: isWide ? worldSpan : worldSpan.clamp(0.0, width),
                height: isWide ? worldSpan.clamp(0.0, height) : worldSpan,
                child: WorldView(camera: camera),
              );

              final controlsWidget = Expanded(
                child: LayoutBuilder(
                  builder: (context, cc) {
                    final cw = cc.maxWidth;
                    final ch = cc.maxHeight;
                    final rightWidth = min(ch, cw - width / 5).clamp(0.0, cw);
                    final inventoryWidth = cw - rightWidth;
                    final buttonSpan = watchSignal(
                      context,
                      Mobj.getAlreadyLoaded(buttonSpanID, DoubleType()),
                    )!;
                    final itemWidth = buttonSpan * 0.8;
                    final mt = MakoThemeData.fromContext(context);

                    return Row(
                      children: [
                        SizedBox(
                          width: inventoryWidth,
                          height: ch,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      for (var i = 0; i < 10; i++)
                                        SizedBox.square(
                                          dimension: itemWidth,
                                          child: const Placeholder(),
                                        ),
                                      SizedBox(height: itemWidth),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                bottom: 0,
                                child: IconButton(
                                  constraints: BoxConstraints.loose(
                                    Size(itemWidth, itemWidth),
                                  ),
                                  icon: const Icon(Icons.settings),
                                  onPressed: () => Navigator.of(context).push(
                                    CircularRevealRoute(
                                      builder: (_) =>
                                          const JourneySettingsScreen(),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onPanUpdate: (details) {
                              movementControlAccumulator += details.delta;
                              // visualize it as a shallow v shape. The intention is to make it so that if the user has dragged to the left or right somewhat, they have to drag further to trigger. Accidental triggers are common when trying to change direction.
                              // bool exceedsArrowInDirection(Coord direction) {
                              //   double cross = dot(orthClockwise(direction.toOffset()),
                              //       movementControlAccumulator);
                              //   double main =
                              //       dot(direction.toOffset(), movementControlAccumulator);
                              //   return main >
                              //       movementControlThreshold + cross.abs() * 0.2;
                              // }

                              // for (final direction in [
                              //   Coord(1, 0),
                              //   Coord(0, 1),
                              //   Coord(-1, 0),
                              //   Coord(0, -1)
                              // ]) {
                              //   if (exceedsArrowInDirection(direction)) {
                              //     movePlayerBy(direction);
                              //     movementControlAccumulator = Offset.zero;
                              //     break;
                              //   }
                              // }

                              if (offsetMax(
                                    offsetAbs(movementControlAccumulator),
                                  ) >
                                  movementControlThreshold) {
                                movePlayerBy(
                                  toCardinalCoord(movementControlAccumulator),
                                );
                                movementControlAccumulator = Offset.zero;
                              }

                              // this one felt surprisingly bad, very prone to going forward when the user's trying to turn.
                              // if (movementControlAccumulator.distance >
                              //     movementControlThreshold) {
                              //   movePlayerBy(toCardinalCoord(movementControlAccumulator));
                              //   movementControlAccumulator = Offset.zero;
                              // }
                            },
                            onPanEnd: (details) {
                              movementControlAccumulator = Offset.zero;
                            },
                            child: SizedBox.expand(
                              child: Container(
                                color: mt.midBackColor,
                                child: Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(
                                      "MOVE",
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: mt.hintTextColor),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );

              if (isWide) {
                return Row(children: [worldWidget, controlsWidget]);
              } else {
                return Column(children: [worldWidget, controlsWidget]);
              }
            },
          );
        },
      ),
    );
  }
}

/// ordered in terms of "solidness", which just affects how inclined they are to be the diagonal rather than the antiDiagonal
enum TerrainKind { tomb, grass, swamp, bush, woods, rock, water, hole }

Color terrainColor(TerrainKind kind) {
  switch (kind) {
    case TerrainKind.hole:
      return const Color.fromARGB(255, 0, 0, 0);
    case TerrainKind.water:
      return const ui.Color.fromARGB(255, 125, 152, 209);
    case TerrainKind.rock:
      return const Color.fromARGB(255, 151, 151, 151);
    case TerrainKind.woods:
      return const Color.fromARGB(255, 66, 114, 51);
    case TerrainKind.bush:
      return const Color.fromARGB(255, 107, 136, 87);
    case TerrainKind.swamp:
      return const Color.fromARGB(255, 161, 165, 106);
    case TerrainKind.grass:
      return const Color.fromARGB(255, 151, 223, 154);
    case TerrainKind.tomb:
      return const Color.fromARGB(255, 231, 231, 231);
  }
}

class WorldView extends StatefulWidget {
  final Signal<Coord> camera;
  const WorldView({super.key, required this.camera});
  @override
  State<WorldView> createState() => _WorldViewState();
}

class _WorldViewState extends State<WorldView>
    with SingleTickerProviderStateMixin, SignalsMixin {
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 100,
    damping: 20,
  );

  late final Ticker _ticker;
  final ValueNotifier<Offset> _scrollOffset = ValueNotifier(Offset.zero);

  SpringSimulation? _simX;
  SpringSimulation? _simY;
  double _simTime = 0;
  static const int cellsInView = 46;
  Duration _tickerBase = Duration.zero;
  Duration _lastElapsed = Duration.zero;

  Coord? _lastCamera;

  late final BufferedGridImage _bgBuffer = BufferedGridImage(
    paintTile: _paintBackgroundTile,
  );

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    createEffect(() {
      _retarget(widget.camera.value.toOffset());
    });
  }

  TerrainKind terrainAt(Coord c) {
    final tombOrGrass = weightedAverage([
      (1, perlin(Offset(c.x.toDouble(), c.y.toDouble()) / 8, 0xDEADBEEF)),
      (0.2, scalarFromHashInt(hashThree(c.x, c.y, 6))),
      (0.4, perlin(Offset(c.x.toDouble(), c.y.toDouble()) / 5, 85)),
    ]);

    final waterActually = max(
      perlin(c.toOffset() / 18, 0xff),
      perlin(c.toOffset() / 18, 0x8889),
    );

    return waterActually > 0.7
        ? TerrainKind.water
        : (tombOrGrass > 0.5 ? TerrainKind.tomb : TerrainKind.grass);
  }

  /// paints to 0,0 at 1,1 span
  void _paintBackgroundTile(Canvas canvas, Coord tile) {
    final layers = tilesForPlaces(
      terrainAt(tile + Coord(1, 0)).index,
      terrainAt(tile).index,
      terrainAt(tile + Coord(0, 1)).index,
      terrainAt(tile + Coord(1, 1)).index,
    );
    final ts = atlasTileSize;
    final dst = const Rect.fromLTWH(0, 0, 1, 1);
    bool first = true;
    for (final (visual, rotation, type) in layers) {
      final paint = Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = ColorFilter.mode(
          terrainColor(TerrainKind.values[type]),
          BlendMode.modulate,
        );
      if (first) {
        // Base layer: always draw a full tile.
        first = false;
        canvas.drawImageRect(
          terrainAtlas,
          terrainTileAtlasSrcRect(TerrainCornerVisualTile.full, ts),
          dst,
          paint,
        );
        if (visual == TerrainCornerVisualTile.full) continue;
      } else {
        final src = terrainTileAtlasSrcRect(visual, ts);
        if (rotation == Cardinality.east) {
          canvas.drawImageRect(terrainAtlas, src, dst, paint);
        } else {
          canvas.save();
          canvas.translate(0.5, 0.5);
          canvas.rotate(rotation.index * pi / 2);
          canvas.translate(-0.5, -0.5);
          canvas.drawImageRect(terrainAtlas, src, dst, paint);
          canvas.restore();
        }
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scrollOffset.dispose();
    _bgBuffer.dispose();
    super.dispose();
  }

  void _retarget(Offset target) {
    final cur = _scrollOffset.value;

    _simX = SpringSimulation(
      _spring,
      cur.dx,
      target.dx,
      _simX?.dx(_simTime) ?? 0.0,
    );
    _simY = SpringSimulation(
      _spring,
      cur.dy,
      target.dy,
      _simY?.dx(_simTime) ?? 0.0,
    );
    _simTime = 0;

    if (_ticker.isActive) {
      _tickerBase = _lastElapsed;
    } else {
      _tickerBase = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    _simTime = (elapsed - _tickerBase).inMicroseconds / 1e6;
    _scrollOffset.value = Offset(_simX!.x(_simTime), _simY!.x(_simTime));
    if (_simX!.isDone(_simTime) && _simY!.isDone(_simTime)) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cam = watchSignal(context, widget.camera);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewWidth = constraints.maxWidth;
        final viewHeight = constraints.maxHeight;
        final trueItemWidth = viewWidth / cellsInView;
        final scale = trueItemWidth;
        final viewTilesW = viewWidth / scale;
        final viewTilesH = viewHeight / scale;

        final dpr = MediaQuery.devicePixelRatioOf(context);
        _bgBuffer.resize(viewTilesW, viewTilesH, (scale * dpr).ceil());

        return ClipRect(
          child: ListenableBuilder(
            listenable: _scrollOffset,
            builder: (context, _) {
              final offset = _scrollOffset.value;
              _bgBuffer.moveCamera(offset);

              return Transform.translate(
                offset: Offset(viewWidth / 2, viewHeight / 2),
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: Transform.translate(
                    offset: -offset,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // this widget is infinitely large I guess, but it's given size bounds in the resize call above, and it only draws four quads at most
                        CustomPaint(painter: _bgBuffer),
                        Positioned(
                          left: 0,
                          top: 0,
                          child: Watch((context) {
                            final liveEntities = watchSignal(
                              context,
                              widget.game.liveEntities,
                            );
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                for (final e in liveEntities)
                                  Positioned(
                                    left: e.position.x - 0.5,
                                    top: e.position.y - 0.5,
                                    width: 1,
                                    height: 1,
                                    child: CustomPaint(
                                      painter: EntityPainter(entity: e),
                                    ),
                                  ),
                              ],
                            );
                          }),
                        ),
                        Positioned(
                          left: cam.x - 0.25,
                          top: cam.y - 0.25,
                          width: 0.5,
                          height: 0.5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: grey(0.3),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class JourneySettingsScreen extends StatefulWidget {
  const JourneySettingsScreen({super.key});

  @override
  State<JourneySettingsScreen> createState() => _JourneySettingsScreenState();
}

class _JourneySettingsScreenState extends State<JourneySettingsScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(initialScrollOffset: 0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) = maybeFlippedBackgroundColors(
      theme,
      false,
    );
    final listItemPadding = const EdgeInsets.symmetric(
      horizontal: 16.0,
      vertical: 8.0,
    );

    Widget trailing(Widget child) =>
        SizedBox(width: 32.0, child: Center(child: child));

    return Scaffold(
      backgroundColor: backgroundColorA,
      resizeToAvoidBottomInset: false,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            pinned: true,
            centerTitle: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ScalingAspectRatio(
                      child: Icon(
                        Icons.settings_rounded,
                        color: theme.colorScheme.onSurface,
                        size: 10,
                      ),
                    ),
                  ),
                  SizedBox(width: 5),
                  Text(
                    'Journey settings',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: backgroundColorB,
            surfaceTintColor: backgroundColorB,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              Watch((context) {
                final isRightHandedMobj = Mobj.getAlreadyLoaded(
                  isRightHandedID,
                  BoolType(),
                );
                final isRightHanded = isRightHandedMobj.value ?? true;
                return ListTile(
                  title: Text(
                    '${isRightHanded ? 'Right' : 'Left'}-handed mode',
                    style: theme.textTheme.bodyLarge,
                  ),
                  subtitle: Text(
                    'optimize for ${isRightHanded ? 'right' : 'left'}-handed use',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: trailing(
                    TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: isRightHanded ? -1.0 : 1.0,
                        end: isRightHanded ? -1.0 : 1.0,
                      ),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      builder: (context, scaleX, child) =>
                          Transform.scale(scaleX: scaleX, child: child),
                      child: Transform.rotate(
                        angle: 45 * pi / 180,
                        child: Icon(
                          Icons.back_hand_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  onTap: () => isRightHandedMobj.value = !isRightHanded,
                  contentPadding: listItemPadding,
                );
              }),
              ListTile(
                title: Text('Quit game', style: theme.textTheme.bodyLarge),
                subtitle: Text(
                  'return to the timer screen',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: trailing(
                  Icon(
                    Icons.exit_to_app,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  final navigator = Navigator.of(context);
                  navigator.removeRouteBelow(ModalRoute.of(context)!);
                  navigator.pop();
                },
                contentPadding: listItemPadding,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

Coord toCardinalCoord(Offset offset) {
  return offset.dx.abs() > offset.dy.abs()
      ? Coord(offset.dx.sign.toInt(), 0)
      : Coord(0, offset.dy.sign.toInt());
}

double offsetMax(Offset offset) {
  return max(offset.dx.abs(), offset.dy.abs());
}

Offset offsetAbs(Offset offset) {
  return Offset(offset.dx.abs(), offset.dy.abs());
}
