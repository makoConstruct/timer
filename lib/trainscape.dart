// Trainscape: Thrival — a game about time. See trainscape_thrival.txt for the
// design doc; this file is its implementation and stays in sync with it. The
// boilerplate half of the implementation is in trainscape_boring.dart, which
// is a part of this library.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data' show Float64List;
import 'dart:ui' as ui show Gradient, Picture, PictureRecorder;

import 'package:animove/animove.dart'
    show Animove, AnimoveFrame, TimelyParabolicSimulation;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart' show savedTrainscapeLevelID;
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart' show Coord, CoordType;
import 'package:signals/signals_flutter.dart';

/// the sampling utilities, the number formatting and the save format — the
/// parts with no design in them
part 'trainscape_boring.dart';

const String trainscapeName = "Trainscape";

// ────────────────────────────── constants ──────────────────────────────

/// yellow-orange, cyan, red-magenta, very dark grey, white. Sage was in here
/// too and came out again: against the others it was too indistinct to tell an
/// item by. The light one is white rather than the pale grey it had to be back
/// when items were laid on white — everything an item sits on is a shade of
/// grey now, so it can go all the way and be the brightest thing in the row.
const defaultItemColors = [
  Color(0xFFF0ca40), // yellow-orange
  Color(0xff39B6E3), // cyan
  Color(0xfff05979), // red-magenta
  Color(0xFF434343), // very dark grey
  Color(0xFFFFFFFF), // white
];
const sage = Color(0xFF9CAF88); // the progress-pie color
const bloodRed = Color(0xFF7A0C0C); // eudaimonia's heart
const playerNames = ['Rudy', 'Noel', 'Geno', 'Lenny', 'Carter'];

const edgeGrey = Color(0xFFebebeb);

/// The scheme the whole UI draws itself in. Night was once the day scheme run
/// through an inverting colour matrix — one filter over the whole tree, no
/// per-colour decisions to make — but there was nowhere to put the tuning the
/// two halves of the day each want. An inverted dark UI has its surfaces
/// exactly as far from the ground as the light one did, when what a dark UI
/// needs is surfaces lifted clear of the ground and contrast pulled *in*, not
/// mirrored. So day and night are two independently written schemes, and
/// [palette] says which is in force.
///
/// Item colours are deliberately not in here: an item is known by its colour,
/// and a thing that changes colour at dusk isn't recognisable.
class Palette {
  /// what the world is drawn on; everything that has to recede is mixed
  /// towards this rather than made transparent
  final Color ground;

  /// chips, slots and name plates — the things that sit on the ground holding
  /// a mark without belonging to a node. The ones that do belong to a node
  /// (its facilities' lozenges, and the tooltip they raise) are filled from
  /// that node's colour instead; see [lozengeFill].
  final Color surface;

  /// the controls strip those surfaces sit on
  final Color panel;

  /// the drag pad's face, which reads as recessed rather than raised
  final Color pad;

  /// The two colours an ordinary node comes in — [NodeTone.plain] and
  /// [NodeTone.deeper] — and so the two colours an ordinary wire can be, since
  /// a wire is a gradient between the nodes at its ends. Written out by hand
  /// rather than derived from one another: they sit close enough together that
  /// any arithmetic producing the second from the first was going to be a
  /// fudge factor standing in for a colour someone had picked by eye anyway.
  ///
  /// "Darker" is the light scheme's word for it. In the dark scheme the deeper
  /// tone steps up rather than down, since that's where the room is.
  final Color node, nodeDarker;

  /// the same pair for a train's node, the graph's colour warmed. A train's
  /// rails take it too: a train and its line are the same thing seen twice.
  final Color trainNode, trainNodeDarker;

  /// A node standing in the way of something that can hurt you — a blight. The
  /// one colour on the map that isn't a shade of the graph, and the one that
  /// overrides a node's tone rather than being drawn alongside it: where a
  /// blight will strike is the thing a player has to be able to read across
  /// the whole map without tapping anything, so it can't be left to a roll.
  final Color hazardNode;

  /// slot, chip and pad borders
  final Color outline;

  /// the tooltip's border, which has to hold its own over the map
  final Color outlineStrong;

  /// text and icons
  final Color ink;

  /// the marks that want the most contrast they can get: numerals sitting on
  /// item icons, cooldown pies
  final Color inkStrong;

  /// corner hints and the drag pad's arrow
  final Color inkFaint;

  final Color shadow;

  /// How far a blight's red is washed out towards [ground]. Its territory is a
  /// region rather than a mark, so it sits barely off the ground and behind
  /// everything. Night washes it less: the same fraction against a dark ground
  /// takes the red past "faint" and into "gone".
  final double blightWash;

  /// what the world is veiled with once the game is over
  final Color scrim;

  /// The lozenge a node's facilities render into carries that node's colour,
  /// but as a wash rather than at strength: the node's saturation scaled by
  /// [lozengeSaturation], then the whole colour carried [lozengeTintp] of the
  /// way towards [lozengeTint].
  ///
  /// A dark grey to aim at rather than a distance to travel from the ground:
  /// one grey pulls both schemes off their own ground without either needing
  /// to know which way that is. Against a white ground it darkens the lozenge,
  /// against a near-black one it lifts it, and the two schemes stay tunable
  /// apart. It desaturates a little on the way, which a lozenge wants anyway.
  final Color lozengeTint;
  final double lozengeTintp;
  final double lozengeSaturation;

  const Palette({
    required this.ground,
    required this.surface,
    required this.panel,
    required this.pad,
    required this.node,
    required this.nodeDarker,
    required this.trainNode,
    required this.trainNodeDarker,
    required this.hazardNode,
    required this.outline,
    required this.outlineStrong,
    required this.ink,
    required this.inkStrong,
    required this.inkFaint,
    required this.shadow,
    required this.blightWash,
    required this.scrim,
    required this.lozengeTint,
    required this.lozengeTintp,
    required this.lozengeSaturation,
  });
}

const dayPalette = Palette(
  ground: Colors.white,
  // off white, like the lozenges: a white item icon has to have something to
  // be seen against, and slots and chips are full of item icons
  surface: Color(0xFFF2F2F2),
  panel: Color(0xFFF7F7F7),
  pad: Color(0xFFE9E9E9),
  node: Color(0xFFEBEBEB),
  nodeDarker: Color(0xFFE0E0E0),
  trainNode: Color(0xFFEDEAE3),
  trainNodeDarker: Color(0xFFE6E2D6),
  hazardNode: Color(0xFFFFB6AE),
  outline: Color(0xFFC6C6C6),
  outlineStrong: Color(0xFF999999),
  ink: Colors.black87,
  inkStrong: Colors.black,
  inkFaint: Colors.black38,
  shadow: Colors.black12,
  blightWash: 0.88,
  scrim: Color(0xD9FFFFFF),
  lozengeTint: Color(0xFFFFFFFF),
  lozengeTintp: 0.3,
  lozengeSaturation: 0.8,
);

/// Night is not day inverted. The ground doesn't go all the way to black —
/// pure black would make every surface on it glare — and the surfaces sit a
/// clear step above it, since by day they're told apart from the ground by
/// their outline alone and that trick doesn't survive the dark. Ink stops
/// short of white for the same reason black87 stops short of black by day.
const nightPalette = Palette(
  ground: Color(0xFF15181B),
  surface: Color(0xFF262B30),
  panel: Color(0xFF1C2024),
  pad: Color(0xFF2B3136),
  node: Color(0xFF262626),
  nodeDarker: Color(0xFF2E2E2E),
  trainNode: Color(0xFF24221E),
  trainNodeDarker: Color(0xFF2A2722),
  hazardNode: Color(0xFF670000),
  outline: Color(0xFF4A5259),
  outlineStrong: Color(0xFF6B747C),
  ink: Color(0xFFE2E6E9),
  inkStrong: Color(0xFFF7F9FA),
  inkFaint: Color(0xFF808A92),
  shadow: Color(0x66000000),
  blightWash: 0.72,
  scrim: Color(0xD915181B),
  lozengeTint: Color(0xFF4D4D4D),
  lozengeTintp: 0.3,
  lozengeSaturation: 0.26,
);

/// The scheme in force. The screen sets it as the day turns and rebuilds
/// everything beneath it, so read it during build — nothing should hold onto
/// what it returned.
Palette palette = dayPalette;

/// the fixed logical-pixel basis for node-widget icons; nothing in the
/// unscaled overlay zooms with the map.
const double nodeIconSize = 22.0;

/// a node's disc on the map, in world units — wider than the edges that meet
/// it, so a node reads as a node and not as a kink in a wire
const double nodeRadius = 0.5;

/// how wide the graph's wires are drawn, in world units
const double edgeWidth = 0.4;

/// The radius of the arc that fills the notch where an edge runs into a node's
/// disc. Without it the two meet at a sharp concave corner on either flank,
/// which reads as a wire laid across a dot rather than one growing out of it.
/// Kept well under [nodeRadius] — a fillet bigger than the thing it fillets
/// swallows the disc.
const double edgeFilletRadius = 0.3;

/// how far clear of a node's disc an edge's gradient waits before it starts
/// moving towards the other node's colour
const double edgeGradientMargin = 0.0;

const double overGraphMaxOpacity = 1.0;
// what proportion of the logarithm'd way along from the default zoom to
// [Game.zoomMin] — furthest out the view goes — does the overgraph start to
// show. It's fully opaque by the time you're all the way out.
const double overGraphFadeOverp = 0.5;

/// How long the camera takes to settle on whatever it's seeking. It eases in
/// and out over that whole span — the motion is what tells the player the view
/// moved rather than cut, so it's leisurely.
const double camSeekSeconds = 0.55;

/// The comfortable span of an item icon. Composite icons get visually complex,
/// so an icon may grow past the size it was asked for to keep its smallest
/// leaf above [minLeafItemScale] of this — but only up to [maxIconGrowth],
/// past which deep icons became enormous and swamped the badges they sat in.
/// Beyond that they simply render small.
const double defaultItemSpan = 16.0;
const double minLeafItemScale = 0.26;
const double maxIconGrowth = 1.6;

/// how long an announcement (NIGHT HAS FALLEN, MUGGED, BLIGHTSTRUCK…) stays up
const double announcementTime = 3;

/// a red flash is three pulses over this many seconds
const double redFlashTime = 1.2;
const int redFlashPulses = 3;

enum FacilityKind { trader, tree, mugger, storage, station, blight }

/// Some facilities only operate in one half of the day. Day-only ones carry a
/// small day icon before their badge (top-aligned) and fade at night;
/// night-only ones carry a night icon (bottom-aligned) and fade in the day.
enum ActivePhase { always, dayOnly, nightOnly }

/// c: takes the item without requiring it (nonthreatening);
/// r: requires the item to pass, without taking it;
/// rc: requires and confiscates the same item.
enum MuggerKind { c, r, rc }

/// how a node widget displays, decided by the world view + player presence
enum NodeZoomLevel {
  selected, // a player is in this node: item icons at full size
  normal, // icons shrunk to a standard width
  small, // badges collapse to their leading icon, item icons hidden
}

enum TrainSpeed { s, r, f, i }

enum TrainScheduleKind { never, oneWay, cycle }

enum StationControl {
  none, // render: 's' + small Icons.train
  remote, // + Icons.swipe_right_alt — can move the train from here anytime
  localOnly, // + 'L' Icons.swipe_right_alt — only when the train is docked here
}

enum GamePhase { playing, won, lost }

// ────────────────────────────── intervals ──────────────────────────────

/// Repetition comes in two flavours. An [ArbitraryInterval] is just a span of
/// time, counted from whenever it was last started — it has no relationship to
/// the day. A [ClockInterval] is locked to the day: its period is a whole
/// multiple of the day or a whole fraction of it, so it always fires at the
/// same time(s) of day, and it can be displayed as a clock time.
sealed class Interval {
  double get period;

  /// seconds from game time [t] until the next firing
  double remainingAt(double t);
}

class ArbitraryInterval extends Interval {
  @override
  final double period;

  /// game time the current span began; whatever triggers it calls [start]
  double startedAt = -1e9;
  ArbitraryInterval(this.period);

  @override
  double remainingAt(double t) => max(0.0, startedAt + period - t);
  void start(double t) => startedAt = t;
  bool elapsedAt(double t) => startedAt > -1e8 && t >= startedAt + period;
}

class ClockInterval extends Interval {
  final double dayLength;

  /// exactly one of these is > 1: the period is a whole multiple of the day,
  /// or a whole fraction of it
  final int multiple, division;

  /// where in the period it fires, in seconds
  final double offset;
  ClockInterval({
    required this.dayLength,
    this.multiple = 1,
    this.division = 1,
    required this.offset,
  });

  @override
  double get period => dayLength * multiple / division;

  @override
  double remainingAt(double t) {
    final r = (offset - t) % period;
    return r == 0 ? period : r;
  }

  /// which repetition [t] falls in; a firing is a change in this number
  int cycleAt(double t) => ((t - offset) / period).floor();

  /// whether the period is a whole multiple of a day (rather than a fraction),
  /// which is what makes a single time of day meaningful
  bool get isDaily => division == 1;

  /// the time of day it fires at, in seconds into the day
  double get timeOfDay => offset % dayLength;
}

/// picks a clock interval firing [division] times a day at a random phase
ClockInterval _divisionInterval(GameRng rng, double dayLength, int division) =>
    ClockInterval(
      dayLength: dayLength,
      division: division,
      offset: rng.nextDouble() * dayLength / division,
    );

/// A three-pulse red flash, driven off the game clock. It clears itself once
/// spent so that nothing stays subscribed to the clock while idle.
class RedFlash {
  final Signal<double> startedAt = signal(-1e9);
  bool get active => startedAt.peek() > -1e8;
  void trigger(double t) => startedAt.value = t;

  /// 0..1 redness at game time [t]; reading this subscribes to the clock, so
  /// only call it when [active]
  double rednessAt(double t) {
    final e = t - startedAt.value;
    if (e < 0 || e > redFlashTime) return 0;
    return sin(e / redFlashTime * redFlashPulses * pi).abs();
  }

  void expire(double t) {
    if (active && t - startedAt.peek() > redFlashTime) {
      startedAt.value = -1e9;
    }
  }
}

// ────────────────────────────── parameters ──────────────────────────────

/// Every "may or may not"/"some" choice from the design doc. One instance per
/// level, and nothing here has a default: a level is a whole set of these
/// answers written down together, not a couple of edits to an implied one. The
/// levels themselves are the static methods at the bottom — [levelOne] is the
/// one being played and tuned, [urLevel] the one it started as.
class Parameters {
  final int seed;

  // goal
  final double globalTime;
  final int eudaimoniaGoal;

  // day/night: the first half of each day is day, the second half night
  final double dayLength;
  final double facilityDayOnlyp;
  final double muggerNightOnlyp;

  // players
  final int nPlayers;
  final int inventoryCap;
  final double playerSpeed; // units/second
  final bool playersHaveMoveAction;

  // grid & graph (levelgen section of the doc)
  final int gridSizeN;
  final double gridSpacing;
  final double gridSizeDistortionCountStartp;
  final double gridSizeDistortionCountVariancep;
  final double gridSizeDistortionp;
  final double lineRemovalProb; // doc: acts when rng > prob
  final double pointRemovalProb; // ditto
  final double middleNodeProb; // ditto
  final double splitNodeMinDistance;

  // items
  final List<Color> itemColors;
  final List<int> tierCount; // length = number of item tiers
  final List<TraderGeneratorsForTier> traderGeneratorsPerTier;
  final double iconNestingp; // chance a host icon absorbs each later part
  /// chance a nesting squircle is willing to take a 2x2 footprint, so that its
  /// inner grid gets full-size cells; it falls back to 1x1 where that won't fit
  final double squircleTryEmbeddingLargep;

  /// when an icon has both a big and a small footprint available, the chance
  /// the big one is the one tried first
  final double iconGridPlacementBigp;

  // rendering: node widgets drop to NodeZoomLevel.small when zoomed out
  // beyond this multiple of the default zoom
  final double farZoomThreshold;

  // facility strewing: one bucket per node (incl. train nodes); sizes follow
  // bucketSizeWeights closely (apportioned, not sampled); all generated
  // traders are placed first, remaining slots filled by nonTraderWeights.
  // Every parameter that divides something up is a set of weights with an
  // arbitrary total, never proportions that have to sum to one — weights are
  // what a human can actually sit down and tweak.
  final List<double> bucketSizeWeights; // index = bucket size, starting at 0
  final Map<FacilityKind, double> nonTraderWeights;

  /// how often each of the three node colourings comes up. See [NodeTone].
  final List<(double, NodeTone)> nodeToneWeights;

  // trees
  final double treeRegenTime; // arbitrary-interval trees
  final double treeClockIntervalp; // else the regen is a daily clock interval
  final double treeSecondItemProb; // "an item or two"
  final double treeTier1Prob; // else tier 0 ("first or second tier")

  // traders
  final double traderInstantProb;
  final (double, double) tradeDurationRange;
  final double traderCooldownProb;
  final (double, double) traderCooldownRange;

  // muggers
  final double muggerIncapTime;
  final List<(double, MuggerKind)> muggerKindWeights;

  // storage
  final (int, int) storageCapacityRange; // log-distributed
  final double storageSecurep; // secured storages are safe from blight

  // blights
  /// The sizes a blight comes in, drawn from uniformly. Discrete rather than a
  /// range: a blight's radius is something the player has to judge by eye from
  /// across the map, and a handful of recognisable sizes can be learned where
  /// a continuum of them can only be guessed at.
  final List<double> blightRadii;
  final double blightMitigablep;
  final double blightHungryp; // of the mitigable ones
  final (int, int) blightDaysRange; // its clock interval, in whole days

  // trains
  final int nTrains;
  final int stationsPerTrain;

  final Map<TrainSpeed, double> trainSpeedUnitsPerSec;
  final List<(double, TrainSpeed)> trainSpeedWeights;
  final double trainActivationProb; // requires a held Quantity to move
  final double trainActivationConsumedProb; // of those: an actual cost
  final double trainActivationTwoProb; // quantity 2 instead of 1
  final List<(double, TrainScheduleKind)> scheduleDistribution;
  final List<int> trainCycleDivisions; // shuttles this many times a day
  final double movableFromInsideProb; // of manually movable trains
  final List<(double, StationControl)> stationControlWeights;
  final double trainTerminusDistance;
  final double oneWayReturnDelay;

  Parameters({
    required this.seed,
    required this.globalTime,
    required this.eudaimoniaGoal,
    required this.dayLength,
    required this.facilityDayOnlyp,
    required this.muggerNightOnlyp,
    required this.nPlayers,
    required this.inventoryCap,
    required this.playerSpeed,
    required this.playersHaveMoveAction,
    required this.gridSizeN,
    required this.gridSpacing,
    required this.gridSizeDistortionCountStartp,
    required this.gridSizeDistortionCountVariancep,
    required this.gridSizeDistortionp,
    required this.lineRemovalProb,
    required this.pointRemovalProb,
    required this.middleNodeProb,
    required this.splitNodeMinDistance,
    required this.itemColors,
    required this.tierCount,
    required this.traderGeneratorsPerTier,
    required this.iconNestingp,
    required this.squircleTryEmbeddingLargep,
    required this.iconGridPlacementBigp,
    required this.farZoomThreshold,
    required this.bucketSizeWeights,
    required this.nonTraderWeights,
    required this.nodeToneWeights,
    required this.treeRegenTime,
    required this.treeClockIntervalp,
    required this.treeSecondItemProb,
    required this.treeTier1Prob,
    required this.traderInstantProb,
    required this.tradeDurationRange,
    required this.traderCooldownProb,
    required this.traderCooldownRange,
    required this.muggerIncapTime,
    required this.muggerKindWeights,
    required this.storageCapacityRange,
    required this.storageSecurep,
    required this.blightRadii,
    required this.blightMitigablep,
    required this.blightHungryp,
    required this.blightDaysRange,
    required this.nTrains,
    required this.stationsPerTrain,
    required this.trainSpeedUnitsPerSec,
    required this.trainSpeedWeights,
    required this.trainActivationProb,
    required this.trainActivationConsumedProb,
    required this.trainActivationTwoProb,
    required this.scheduleDistribution,
    required this.trainCycleDivisions,
    required this.movableFromInsideProb,
    required this.stationControlWeights,
    required this.trainTerminusDistance,
    required this.oneWayReturnDelay,
  });

  /// The level being played and tuned. Started as a straight copy of
  /// [urLevel] — which is the point of urLevel: this one is free to move.
  /// Unlike urLevel it's allowed to name live things ([defaultItemColors],
  /// [levelOneTraders]), since it isn't holding anything still.
  static Parameters levelOne(int seed) {
    const tierCount = [13, 10, 4];
    return Parameters(
      seed: seed,
      globalTime: 240 * 4,
      eudaimoniaGoal: 4,
      dayLength: 240,
      facilityDayOnlyp: 0.34,
      muggerNightOnlyp: 0.45,
      nPlayers: 2,
      inventoryCap: 4,
      playerSpeed: 1.75,
      playersHaveMoveAction: true,
      gridSizeN: 7,
      gridSpacing: 3.5,
      gridSizeDistortionCountStartp: 0.3,
      gridSizeDistortionCountVariancep: 0.4,
      gridSizeDistortionp: 1.0,
      lineRemovalProb: 0.2,
      pointRemovalProb: 0.14,
      middleNodeProb: 0.11,
      splitNodeMinDistance: 1.2,
      itemColors: defaultItemColors,
      tierCount: tierCount,
      traderGeneratorsPerTier: levelOneTraders(tierCount.length),
      iconNestingp: 0.6,
      squircleTryEmbeddingLargep: 0.4,
      iconGridPlacementBigp: 0.7,
      farZoomThreshold: 2.5,
      bucketSizeWeights: const [1, 8, 4, 2, 0.8],
      nonTraderWeights: const {
        FacilityKind.tree: 10,
        FacilityKind.storage: 5,
        FacilityKind.mugger: 3,
        FacilityKind.blight: 0.12,
      },
      nodeToneWeights: const [
        (1, NodeTone.plain),
        (0, NodeTone.deeper),
        (1, NodeTone.tinted),
      ],
      treeRegenTime: 25,
      treeClockIntervalp: 0.6,
      treeSecondItemProb: 0.3,
      treeTier1Prob: 0.3,
      traderInstantProb: 0.5,
      tradeDurationRange: (4, 15),
      traderCooldownProb: 0.3,
      traderCooldownRange: (5, 25),
      muggerIncapTime: 20,
      muggerKindWeights: const [
        (3, MuggerKind.c),
        (3, MuggerKind.r),
        (2.3, MuggerKind.rc),
      ],
      storageCapacityRange: (2, 12),
      storageSecurep: 0.12,
      blightRadii: const [5, 7, 14],
      blightMitigablep: 0.8,
      blightHungryp: 0.15,
      blightDaysRange: (1, 3),
      nTrains: 3,
      stationsPerTrain: 2,
      trainSpeedUnitsPerSec: const {
        TrainSpeed.s: 1.6,
        TrainSpeed.r: 3.4,
        TrainSpeed.f: 6,
        TrainSpeed.i: 16,
      },
      trainSpeedWeights: const [
        (1.3, TrainSpeed.s),
        (4, TrainSpeed.r),
        (2, TrainSpeed.f),
        (1, TrainSpeed.i),
      ],
      trainActivationProb: 0.35,
      trainActivationConsumedProb: 0.25,
      trainActivationTwoProb: 0.25,
      scheduleDistribution: const [
        (2, TrainScheduleKind.never),
        (1, TrainScheduleKind.oneWay),
        (1, TrainScheduleKind.cycle),
      ],
      trainCycleDivisions: const [8, 10, 12, 15, 16, 20, 24, 30],
      movableFromInsideProb: 0.8,
      stationControlWeights: const [
        (3, StationControl.none),
        (4, StationControl.remote),
        (3, StationControl.localOnly),
      ],
      trainTerminusDistance: 1.5,
      oneWayReturnDelay: 2.0,
    );
  }

  /// The level as it stood the first time the game was played end to end —
  /// every default the constructor had on 2026-07-27, written out longhand so
  /// that it survives [levelOne] being tuned away from it.
  /// trainscape_first_ever_level.json is `urLevel(1)`, saved mid-play out of a
  /// real session.
  ///
  /// Nothing in here reads a live list ([defaultItemColors],
  /// [levelOneTraders]): a snapshot that follows the things it's a snapshot of
  /// isn't one, so the colours are written out and the generators have their
  /// own frozen copy in [urTraders].
  static Parameters urLevel(int seed) {
    const tierCount = [5, 16, 8, 6, 4];
    return Parameters(
      seed: seed,
      globalTime: 240 * 10,
      eudaimoniaGoal: 3,
      dayLength: 240,
      facilityDayOnlyp: 0.34,
      muggerNightOnlyp: 0.45,
      nPlayers: 2,
      inventoryCap: 5,
      playerSpeed: 1.75,
      playersHaveMoveAction: true,
      gridSizeN: 13,
      gridSpacing: 3.5,
      gridSizeDistortionCountStartp: 0.3,
      gridSizeDistortionCountVariancep: 0.4,
      gridSizeDistortionp: 1.0,
      lineRemovalProb: 0.17,
      pointRemovalProb: 0.6,
      middleNodeProb: 0.11,
      splitNodeMinDistance: 1.2,
      itemColors: const [
        Color(0xFFF0ca40), // yellow-orange
        Color(0xff39B6E3), // cyan
        Color(0xfff05979), // red-magenta
        Color(0xFF434343), // very dark grey
        Color(0xFFFFFFFF), // white
      ],
      tierCount: tierCount,
      traderGeneratorsPerTier: urTraders(tierCount.length),
      iconNestingp: 0.6,
      squircleTryEmbeddingLargep: 0.4,
      iconGridPlacementBigp: 0.7,
      farZoomThreshold: 2.5,
      bucketSizeWeights: const [1, 8, 4, 2, 0.8],
      nonTraderWeights: const {
        FacilityKind.tree: 10,
        FacilityKind.storage: 5,
        FacilityKind.mugger: 3,
        FacilityKind.blight: 0.12,
      },
      nodeToneWeights: const [
        (1, NodeTone.plain),
        (1, NodeTone.deeper),
        (1, NodeTone.tinted),
      ],
      treeRegenTime: 25,
      treeClockIntervalp: 0.6,
      treeSecondItemProb: 0.3,
      treeTier1Prob: 0.3,
      traderInstantProb: 0.5,
      tradeDurationRange: (4, 15),
      traderCooldownProb: 0.3,
      traderCooldownRange: (5, 25),
      muggerIncapTime: 20,
      muggerKindWeights: const [
        (3, MuggerKind.c),
        (3, MuggerKind.r),
        (4, MuggerKind.rc),
      ],
      storageCapacityRange: (2, 12),
      storageSecurep: 0.12,
      blightRadii: const [5, 7, 14],
      blightMitigablep: 0.8,
      blightHungryp: 0.15,
      blightDaysRange: (1, 3),
      nTrains: 3,
      stationsPerTrain: 2,
      trainSpeedUnitsPerSec: const {
        TrainSpeed.s: 1.6,
        TrainSpeed.r: 3.4,
        TrainSpeed.f: 6,
        TrainSpeed.i: 16,
      },
      trainSpeedWeights: const [
        (1.3, TrainSpeed.s),
        (4, TrainSpeed.r),
        (2, TrainSpeed.f),
        (1, TrainSpeed.i),
      ],
      trainActivationProb: 0.35,
      trainActivationConsumedProb: 0.25,
      trainActivationTwoProb: 0.25,
      scheduleDistribution: const [
        (2, TrainScheduleKind.never),
        (1, TrainScheduleKind.oneWay),
        (1, TrainScheduleKind.cycle),
      ],
      trainCycleDivisions: const [8, 10, 12, 15, 16, 20, 24, 30],
      movableFromInsideProb: 0.8,
      stationControlWeights: const [
        (3, StationControl.none),
        (4, StationControl.remote),
        (3, StationControl.localOnly),
      ],
      trainTerminusDistance: 1.5,
      oneWayReturnDelay: 2.0,
    );
  }
}

// ────────────────────────────── items & icons ──────────────────────────────

enum BasicShape { circle, pill /*vertical rod*/, diamond, squircle }

/// The visual language of items. Purely visual mnemonics; an Item's identity
/// is its (tier, index) slot, not its icon. Composite icons are grids of
/// parts, possibly nested inside basic shapes — see 'item catalogue
/// generation' in the design doc. Structural equality matters here: icon
/// composition counts how often the same subcomponent recurs across the
/// inputs of an item's producers.
sealed class ItemIcon {
  const ItemIcon();
}

class BasicIcon extends ItemIcon {
  final BasicShape shape;
  final Color color;
  const BasicIcon(this.shape, this.color);
  @override
  bool operator ==(Object other) =>
      other is BasicIcon && other.shape == shape && other.color == color;
  @override
  int get hashCode => Object.hash(shape, color);
}

class HeartIcon extends ItemIcon {
  const HeartIcon();
  @override
  bool operator ==(Object other) => other is HeartIcon;
  @override
  int get hashCode => 0x48454152;
}

class IconPlacement {
  final Coord pos; // top-left cell of the footprint in the containing grid

  /// how many cells it took, untilted. Size is settled per placement, not per
  /// icon: a rod is 1x2 or 1x1, a squircle 2x2 or 1x1, whichever fit.
  final Coord footprint;
  final bool tilted; // irregular footprints may rotate 90°
  final ItemIcon icon;
  const IconPlacement(this.pos, this.footprint, this.tilted, this.icon);
  @override
  bool operator ==(Object other) =>
      other is IconPlacement &&
      other.pos == pos &&
      other.footprint == footprint &&
      other.tilted == tilted &&
      other.icon == icon;
  @override
  int get hashCode => Object.hash(pos, footprint, tilted, icon);
}

const _placementsEq = ListEquality<IconPlacement>();

/// parts nested into a basic shape's inner grid
class NestingIcon extends ItemIcon {
  final BasicIcon container;
  final Coord dims;

  /// Whether this squircle is willing to take a 2x2 footprint in the grid it
  /// sits in, so that its own 2x2 inner grid gets full-size cells rather than
  /// quarter-size ones. Only an eligibility — whether it actually gets one is
  /// settled where it's placed — and not part of the icon's identity, which is
  /// why [==] ignores it.
  final bool mayEmbedLarge;
  final List<IconPlacement> children;
  const NestingIcon(
    this.container,
    this.dims,
    this.children, {
    this.mayEmbedLarge = false,
  });

  @override
  bool operator ==(Object other) =>
      other is NestingIcon &&
      other.container == container &&
      other.dims == dims &&
      _placementsEq.equals(other.children, children);
  @override
  int get hashCode =>
      Object.hash(container, dims, _placementsEq.hash(children));
}

/// The outer grid; only ever occurs at the root of an icon. Were one ever
/// placed inside a nesting it would be gutted through (its children spilled
/// out and used directly).
class RootGridIcon extends ItemIcon {
  final Coord dims;
  final List<IconPlacement> children;
  const RootGridIcon(this.dims, this.children);
  @override
  bool operator ==(Object other) =>
      other is RootGridIcon &&
      other.dims == dims &&
      _placementsEq.equals(other.children, children);
  @override
  int get hashCode => Object.hash(dims, _placementsEq.hash(children));
}

/// nesting depth: a basic shape is 1, a shape with parts nested in it is 2...
/// Depth 3 parts only sit directly in the root grid — nesting one inside
/// another nesting is four levels deep and stops being legible.
int iconDepth(ItemIcon i) => switch (i) {
  NestingIcon n =>
    n.children.isEmpty
        ? 1
        : 1 + n.children.map((c) => iconDepth(c.icon)).reduce(max),
  RootGridIcon r =>
    r.children.isEmpty
        ? 1
        : r.children.map((c) => iconDepth(c.icon)).reduce(max),
  _ => 1,
};

/// Footprint in grid cells (untilted): rods are 1x2, everything else 1x1.
/// This is the footprint everywhere, root grid included — nothing is ever
/// scaled up. A rod in the root grid is always its normal size, and one
/// nested inside something is smaller simply because the cells are.
/// The footprints an icon can occupy, big first. A rod is 1x2 or 1x1; a
/// squircle that rolled for embedding large is 2x2 or 1x1; everything else is
/// only ever 1x1.
List<Coord> _footprintsFor(ItemIcon i) {
  final shape = switch (i) {
    BasicIcon b => b.shape,
    NestingIcon n => n.container.shape,
    _ => null,
  };
  if (shape == BasicShape.pill) return const [Coord(1, 2), Coord(1, 1)];
  if (shape == BasicShape.squircle && i is NestingIcon && i.mayEmbedLarge) {
    return const [Coord(2, 2), Coord(1, 1)];
  }
  return const [Coord(1, 1)];
}

/// The ways an icon can be put into a grid, in the order they should be tried
/// — each falls over to the next when there's no room for it. Size and tilt
/// are both alternatives of this kind: [Parameters.iconGridPlacementBigp]
/// decides whether the big size is tried first, and the tilt order is random
/// so that a rod which fits either way isn't always upright. An icon holding a
/// nesting of its own is too full to shrink, so it's only offered its big size
/// and simply fails to place if that doesn't fit.
List<(Coord footprint, List<bool> tilts)> iconPlacementOptions(
  GameRng rng,
  Parameters p,
  ItemIcon icon,
) {
  var sizes = _footprintsFor(icon);
  if (sizes.length > 1) {
    if (iconDepth(icon) > 2) {
      sizes = [sizes.first];
    } else if (!rng.chance(p.iconGridPlacementBigp)) {
      sizes = sizes.reversed.toList();
    }
  }
  final tiltFirst = rng.chance(0.5);
  return [
    for (final f in sizes)
      (
        f,
        f.x == f.y
            ? const [false]
            : (tiltFirst ? const [true, false] : const [false, true]),
      ),
  ];
}

Color iconDominantColor(ItemIcon i) => switch (i) {
  BasicIcon b => b.color,
  NestingIcon n => n.container.color,
  RootGridIcon r =>
    r.children.isEmpty ? edgeGrey : iconDominantColor(r.children.first.icon),
  HeartIcon _ => bloodRed,
};

/// If an item is nested inside an item of the same color, the inner one is
/// painted with an outline; the outline contrasts against the shared color.
Color contrastOutlineColor(Color c) =>
    HSLuvColor.fromColor(c).lightness > 60 ? Colors.black87 : Colors.white;

/// The natural aspect (width / height) of the mark an icon actually paints.
/// Everything is square except rods, which are half as wide as they are tall,
/// and root grids, which take the aspect of their grid.
double iconAspect(ItemIcon i) => switch (i) {
  BasicIcon b => b.shape == BasicShape.pill ? 0.5 : 1,
  NestingIcon n => n.container.shape == BasicShape.pill ? 0.5 : 1,
  RootGridIcon r => r.dims.x / r.dims.y,
  HeartIcon _ => 1,
};

/// The box an icon should be given, from the side of the square it would
/// otherwise have taken: the square with its empty margins cropped off, so a
/// tall thin icon doesn't carry square padding around into whatever row it's
/// laid out in. The mark itself is drawn at exactly the size it was before.
Size iconBox(ItemIcon i, double side) {
  final a = iconAspect(i);
  return a >= 1 ? Size(side, side / a) : Size(side * a, side);
}

/// The span of the smallest leaf shape relative to the icon's own box.
/// Used to grow complex icons so no leaf drops below [minLeafItemScale] of
/// [defaultItemSpan].
double leafScale(ItemIcon i) => switch (i) {
  NestingIcon n =>
    n.children.isEmpty
        ? 1
        : n.children.map((c) => leafScale(c.icon)).reduce(min) *
              0.62 /
              max(n.dims.x, n.dims.y),
  RootGridIcon r =>
    r.children.isEmpty
        ? 1
        : r.children.map((c) => leafScale(c.icon)).reduce(min) /
              max(r.dims.x, r.dims.y),
  _ => 1,
};

// ── tooltip spans: english for the structure, but items display as their
// icons at full size, never described in words ──

InlineSpan tipText(String s) => TextSpan(text: s);

InlineSpan itemSpan(Item it) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 1.5),
    child: ItemWidget(it, size: defaultItemSpan),
  ),
);

List<InlineSpan> quantitySpans(Quantity q) => [
  itemSpan(q.item),
  if (q.n > 1) tipText('×${q.n}'),
];

List<InlineSpan> quantitiesSpans(List<Quantity> qs) => [
  for (var i = 0; i < qs.length; i++) ...[
    if (i > 0) tipText(' and '),
    ...quantitySpans(qs[i]),
  ],
];

void paintItemIcon(
  Canvas canvas,
  ItemIcon i,
  Rect rect, {
  bool outlineOn = false,
}) {
  switch (i) {
    case BasicIcon b:
      _paintBasicShape(canvas, b.shape, b.color, rect, outlineOn);
    case NestingIcon n:
      _paintBasicShape(
        canvas,
        n.container.shape,
        n.container.color,
        rect,
        outlineOn,
      );
      _paintPlacements(
        canvas,
        _innerGrid(n.container.shape, rect, n.dims),
        n.dims,
        n.children,
        containerColor: n.container.color,
      );
    case RootGridIcon r:
      // letterbox an aspect-correct grid into the (square) icon box
      final aspect = r.dims.x / r.dims.y;
      final boxAspect = rect.width / rect.height;
      final grid = aspect > boxAspect
          ? Rect.fromCenter(
              center: rect.center,
              width: rect.width,
              height: rect.width / aspect,
            )
          : Rect.fromCenter(
              center: rect.center,
              width: rect.height * aspect,
              height: rect.height,
            );
      _paintPlacements(canvas, grid, r.dims, r.children);
    case HeartIcon _:
      _paintHeart(canvas, rect);
  }
}

Rect _inscribedSquare(Rect r) {
  final side = min(r.width, r.height);
  return Rect.fromCenter(center: r.center, width: side, height: side);
}

/// where a shape's inner nesting grid sits
/// A rod's own geometry. Its natural aspect is one cell wide by two tall, and
/// its thickness is the radius of a circle drawn in one of those cells — so a
/// rod beside a circle reads as the same weight of mark. Handed a box of some
/// other aspect (a lone item in a square slot, say) it keeps that 1:2
/// proportion and centers itself.
({double thickness, double length}) _pillMetrics(Rect rect) {
  final cell = min(rect.width, rect.height / 2);
  return (thickness: cell * 0.94, length: cell * 2 - cell * (1.0 - 0.94) * 2);
}

/// the area inside a shape that nested parts get to use
Rect _innerArea(BasicShape shape, Rect rect) {
  if (shape == BasicShape.pill) {
    final m = _pillMetrics(rect);
    return Rect.fromCenter(
      center: rect.center,
      width: m.thickness * 0.9,
      height: m.length * 0.94,
    );
  }
  final side =
      _inscribedSquare(rect).width *
      switch (shape) {
        BasicShape.squircle => 0.84,
        BasicShape.circle => 0.7,
        _ => 0.54, // a diamond only fits a small square
      };
  return Rect.fromCenter(center: rect.center, width: side, height: side);
}

/// Where a shape's inner nesting grid sits. Its cells are always square — the
/// grid shrinks to whichever dimension binds — so nested parts are never
/// distorted. Inside a rod that means the inner grid and everything on it ends
/// up small and well short of flush with the rod's ends; that's the price of
/// sizing that's automatic and right.
Rect _innerGrid(BasicShape shape, Rect rect, Coord dims) {
  final area = _innerArea(shape, rect);
  final cell = min(area.width / dims.x, area.height / dims.y);
  return Rect.fromCenter(
    center: area.center,
    width: cell * dims.x,
    height: cell * dims.y,
  );
}

void _paintPlacements(
  Canvas canvas,
  Rect grid,
  Coord dims,
  List<IconPlacement> children, {
  Color? containerColor,
}) {
  final cw = grid.width / dims.x, ch = grid.height / dims.y;
  for (final pl in children) {
    var f = pl.footprint;
    if (pl.tilted) f = Coord(f.y, f.x);
    final r = Rect.fromLTWH(
      grid.left + pl.pos.x * cw,
      grid.top + pl.pos.y * ch,
      f.x * cw,
      f.y * ch,
    ).deflate(min(cw, ch) * 0.024);
    final outline =
        containerColor != null && iconDominantColor(pl.icon) == containerColor;
    if (pl.tilted) {
      canvas.save();
      canvas.translate(r.center.dx, r.center.dy);
      canvas.rotate(pi / 2);
      canvas.translate(-r.center.dx, -r.center.dy);
      paintItemIcon(
        canvas,
        pl.icon,
        Rect.fromCenter(center: r.center, width: r.height, height: r.width),
        outlineOn: outline,
      );
      canvas.restore();
    } else {
      paintItemIcon(canvas, pl.icon, r, outlineOn: outline);
    }
  }
}

void _paintBasicShape(
  Canvas canvas,
  BasicShape shape,
  Color color,
  Rect rect,
  bool outlineOn,
) {
  final r = _inscribedSquare(rect);
  final fill = Paint()..color = color;
  final Path path;
  switch (shape) {
    case BasicShape.circle:
      path = Path()
        ..addOval(Rect.fromCircle(center: r.center, radius: r.width * 0.46));
    case BasicShape.pill:
      // a true capsule: the corner radius is always half the thickness, so the
      // ends are semicircles however long or short the rod is
      final m = _pillMetrics(rect);
      path = Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: rect.center,
              width: m.thickness,
              height: m.length,
            ),
            Radius.circular(m.thickness / 2),
          ),
        );
    case BasicShape.diamond:
      path = Path()
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.center.dx, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case BasicShape.squircle:
      path = Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            r.deflate(r.width * 0.04),
            Radius.circular(r.width * 0.28),
          ),
        );
  }
  canvas.drawPath(path, fill);
  if (outlineOn) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.0, r.width * 0.09)
        ..color = contrastOutlineColor(color),
    );
  }
}

void _paintHeart(Canvas canvas, Rect rect) {
  final r = _inscribedSquare(rect);
  final w = r.width, h = r.height;
  double x(double f) => r.left + f * w;
  double y(double f) => r.top + f * h;
  final path = Path()
    ..moveTo(x(0.5), y(0.35))
    ..cubicTo(x(0.5), y(0.25), x(0.4), y(0.13), x(0.28), y(0.13))
    ..cubicTo(x(0.12), y(0.13), x(0.05), y(0.28), x(0.05), y(0.4))
    ..cubicTo(x(0.05), y(0.6), x(0.25), y(0.75), x(0.5), y(0.93))
    ..cubicTo(x(0.75), y(0.75), x(0.95), y(0.6), x(0.95), y(0.4))
    ..cubicTo(x(0.95), y(0.28), x(0.88), y(0.13), x(0.72), y(0.13))
    ..cubicTo(x(0.6), y(0.13), x(0.5), y(0.25), x(0.5), y(0.35))
    ..close();
  canvas.drawPath(path, Paint()..color = bloodRed);
}

/// Items are canonical per level — interned in the ItemCatalog, so equality
/// is identity. Never construct an Item outside catalog generation.
class Item {
  final int tier; // 0 = basic; eudaimonia sits above the final tier
  final int iInTier;
  final bool isEudaimonia;
  late final ItemIcon icon; // basics at construction, composites late-assigned
  Item(this.tier, this.iInTier, {this.isEudaimonia = false});
}

class Quantity {
  final Item item;
  final int n;
  const Quantity(this.item, this.n);
}

/// sums duplicate items into single quantities, preserving first-seen order
List<Quantity> mergeQuantities(List<Quantity> qs) {
  final order = <Item>[];
  final counts = <Item, int>{};
  for (final q in qs) {
    if (!counts.containsKey(q.item)) order.add(q.item);
    counts[q.item] = (counts[q.item] ?? 0) + q.n;
  }
  return [for (final it in order) Quantity(it, counts[it]!)];
}

class ItemCatalog {
  final List<List<Item>> tiers; // tiers[tier][i]; lengths = params.tierCount
  final Item eudaimonia;
  ItemCatalog(this.tiers, this.eudaimonia);
  List<Item> get finalTier => tiers.last;

  static ItemCatalog generate(GameRng rng, Parameters p) {
    final tiers = [
      for (var t = 0; t < p.tierCount.length; t++)
        [for (var i = 0; i < p.tierCount[t]; i++) Item(t, i)],
    ];
    // basics: distinct (shape, color) combos drawn from the full space
    // Drawing from the cross product left whole shapes unused — with only a
    // handful of basics, squircles often never appeared at all. Shapes and
    // colors are drawn from their own bags instead, so every shape and every
    // color turns up once before any of them turns up twice.
    final shapes = _Bag(rng, BasicShape.values);
    final colors = _Bag(rng, p.itemColors);
    final taken = <BasicIcon>{};
    for (var i = 0; i < tiers[0].length; i++) {
      var icon = BasicIcon(shapes.draw(), colors.draw());
      for (var t = 0; t < 8 && taken.contains(icon); t++) {
        icon = BasicIcon(icon.shape, colors.draw());
      }
      taken.add(icon);
      tiers[0][i].icon = icon;
    }
    final eudaimonia = Item(p.tierCount.length, 0, isEudaimonia: true)
      ..icon = const HeartIcon();
    return ItemCatalog(tiers, eudaimonia);
  }
}

/// Composite items get their icons late, composed from the visual
/// subcomponents of the inputs of the traders that produce them — see 'item
/// catalogue generation' in the design doc.
void assignCompositeIcons(
  GameRng rng,
  Parameters p,
  ItemCatalog catalog,
  List<Trader> traders,
) {
  // An icon is the *only* handle the player has on an item's identity, so two
  // distinct items must never compose to the same one — otherwise a mugger
  // holding out for one of them looks like it's ignoring the one you're
  // carrying.
  final used = <ItemIcon>{
    for (final it in catalog.tiers[0]) it.icon,
    const HeartIcon(),
  };
  for (var tier = 1; tier < catalog.tiers.length; tier++) {
    for (final item in catalog.tiers[tier]) {
      // only producers from lower items — their icons already exist
      final producers = traders
          .where(
            (t) =>
                t.gives.any((q) => identical(q.item, item)) &&
                t.takes.every((q) => q.item.tier < tier),
          )
          .toList();
      var parts = producers.isEmpty
          ? const <ItemIcon>[]
          : _pickIconParts(rng, producers);
      if (parts.isEmpty) {
        // shouldn't happen — generation drains every tier's required list —
        // but an empty part list would compose into a heart, so fall back to
        // borrowing a couple of lower items rather than minting a fake
        // eudaimonia icon.
        final lower = catalog.tiers[tier - 1];
        parts = [
          lower[rng.nextInt(lower.length)].icon,
          lower[rng.nextInt(lower.length)].icon,
        ];
      }
      // composition is random, so a plain retry usually breaks a collision;
      // past a few tries, throw an extra part in to force the issue
      var icon = _composeIcon(rng, p, parts);
      for (var tries = 0; used.contains(icon) && tries < 16; tries++) {
        final lower = catalog.tiers[rng.nextInt(tier)];
        icon = _composeIcon(rng, p, [
          ...parts,
          if (tries > 6) lower[rng.nextInt(lower.length)].icon,
        ]);
      }
      used.add(icon);
      item.icon = icon;
    }
  }
}

/// The parts an icon offers up to be built into another icon. A root grid is
/// not a shape — it's only the arrangement of the shapes standing side by side
/// at the top level of one item, and it can't be drawn nested inside anything
/// or stood next to anything as a mark of its own. So destructuring it away is
/// the first step of every hunt for parts, and what comes back is always
/// icons that can stand alone.
List<ItemIcon> iconParts(ItemIcon i) => i is RootGridIcon
    ? [for (final c in i.children) ...iconParts(c.icon)]
    : [i];

/// walks an icon listing its visual subcomponents (with multiplicity).
/// RootGridIcons are gutted through: never included themselves.
void _collectSubcomponents(ItemIcon i, List<ItemIcon> out) {
  switch (i) {
    case RootGridIcon r:
      for (final c in r.children) {
        _collectSubcomponents(c.icon, out);
      }
    case NestingIcon n:
      out.add(n);
      for (final c in n.children) {
        _collectSubcomponents(c.icon, out);
      }
    case BasicIcon _:
      out.add(i);
    case HeartIcon _:
      break;
  }
}

double _depthBonus(ItemIcon i) => switch (iconDepth(i)) {
  1 => 1,
  2 => 5, // more iconic parts get advantaged
  _ => 8,
};

/// One component picked per producing trader: from that trader's inputs'
/// subcomponents, minus already-picked ones, top 30% by global weight,
/// weighted draw.
List<ItemIcon> _pickIconParts(GameRng rng, List<Trader> producers) {
  // global weights: occurrences across all producers' inputs × depth bonus
  final weights = <ItemIcon, double>{};
  for (final tr in producers) {
    for (final q in tr.takes) {
      final comps = <ItemIcon>[];
      _collectSubcomponents(q.item.icon, comps);
      for (final c in comps) {
        weights[c] = (weights[c] ?? 0) + q.n.toDouble();
      }
    }
  }
  for (final c in weights.keys.toList()) {
    weights[c] = weights[c]! * _depthBonus(c);
  }

  final picked = <ItemIcon>[];
  for (final tr in producers) {
    final own = <ItemIcon>[];
    for (final q in tr.takes) {
      _collectSubcomponents(q.item.icon, own);
    }
    final candidates = <ItemIcon>[];
    for (final c in own) {
      if (!picked.contains(c) && !candidates.contains(c)) candidates.add(c);
    }
    if (candidates.isEmpty) continue;
    candidates.sort((a, b) => weights[b]!.compareTo(weights[a]!));
    final top = candidates.take((candidates.length * 0.3).ceil()).toList();
    picked.add(weightedPick(rng, [for (final c in top) (weights[c]!, c)]));
  }
  return picked;
}

int _nestingCapacity(BasicShape shape) => switch (shape) {
  BasicShape.squircle => 4,
  BasicShape.pill => 2,
  _ => 1,
};

/// how empty a part is, as a nesting host: free capacity, with a bonus to
/// squircles (3x) and rods (2x)
double _emptiness(ItemIcon i) => switch (i) {
  BasicIcon b =>
    _nestingCapacity(b.shape) *
        (b.shape == BasicShape.squircle
            ? 3.0
            : b.shape == BasicShape.pill
            ? 2.0
            : 1.0),
  NestingIcon n =>
    (n.dims.x * n.dims.y -
                n.children.fold(0, (a, c) => a + c.footprint.x * c.footprint.y))
            .toDouble() *
        (n.container.shape == BasicShape.squircle
            ? 3.0
            : n.container.shape == BasicShape.pill
            ? 2.0
            : 1.0),
  _ => 0,
};

ItemIcon _composeIcon(GameRng rng, Parameters p, List<ItemIcon> parts) {
  if (parts.isEmpty) return const HeartIcon(); // unreachable
  // Whole item icons reach this by way of the borrowed-item fallbacks in
  // assignCompositeIcons, and one of those may be a root grid, which is not a
  // thing that can be a part — it's destructured into the shapes it arranged.
  parts = [for (final part in parts) ...iconParts(part)];
  shuffleInPlace(rng, parts);
  // sort by emptiness (hosts first); the shuffle above breaks ties randomly
  final scored = [for (final part in parts) (_emptiness(part), part)];
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  final ordered = [for (final s in scored) s.$2];

  final spliceN = (ordered.length * 0.3).ceil();
  final absorbed = List<bool>.filled(ordered.length, false);
  for (var hi = 0; hi < spliceN; hi++) {
    if (absorbed[hi]) continue;
    var host = ordered[hi];
    // consider nesting each later part into it, starting from the least
    // empty end of the list
    for (var j = ordered.length - 1; j > hi; j--) {
      if (absorbed[j]) continue;
      if (!rng.chance(p.iconNestingp)) continue;
      final grown = _tryNest(rng, p, host, ordered[j]);
      if (grown != null) {
        host = grown;
        absorbed[j] = true;
      }
    }
    ordered[hi] = host;
  }

  final remaining = [
    for (var i = 0; i < ordered.length; i++)
      if (!absorbed[i]) ordered[i],
  ];
  if (remaining.length == 1) return remaining.first;
  return _packRootGrid(rng, p, remaining);
}

/// tries to nest [part] into [host], returning the grown host, or null if it
/// doesn't fit (or nesting limits forbid it)
NestingIcon? _tryNest(GameRng rng, Parameters p, ItemIcon host, ItemIcon part) {
  // depth limit: the grown host may reach depth 3 (root grid only), no deeper
  if (iconDepth(part) > 2) return null;
  final BasicIcon container;
  final Coord dims;
  final bool mayEmbedLarge;
  final List<IconPlacement> children;
  switch (host) {
    case BasicIcon b:
      container = b;
      dims = switch (b.shape) {
        BasicShape.squircle => const Coord(2, 2),
        BasicShape.pill =>
          rng.chance(0.5) ? const Coord(1, 2) : const Coord(1, 1),
        _ => const Coord(1, 1),
      };
      // a squircle may claim a 2x2 footprint so its inner grid gets full-size
      // cells; whether it actually gets one is decided where it's placed
      mayEmbedLarge =
          b.shape == BasicShape.squircle &&
          rng.chance(p.squircleTryEmbeddingLargep);
      children = const [];
    case NestingIcon n:
      container = n.container;
      dims = n.dims;
      mayEmbedLarge = n.mayEmbedLarge;
      children = n.children;
    default:
      return null;
  }

  final occupied = <Coord>{};
  for (final c in children) {
    var f = c.footprint;
    if (c.tilted) f = Coord(f.y, f.x);
    for (var dx = 0; dx < f.x; dx++) {
      for (var dy = 0; dy < f.y; dy++) {
        occupied.add(Coord(c.pos.x + dx, c.pos.y + dy));
      }
    }
  }

  bool fits(Coord pos, Coord fp) {
    if (pos.x + fp.x > dims.x || pos.y + fp.y > dims.y) return false;
    for (var dx = 0; dx < fp.x; dx++) {
      for (var dy = 0; dy < fp.y; dy++) {
        if (occupied.contains(Coord(pos.x + dx, pos.y + dy))) return false;
      }
    }
    return true;
  }

  // pick a starting cell randomly, iterate outward in both directions
  // alternatingly, trying both tilts for irregular footprints
  final cells = [
    for (var y = 0; y < dims.y; y++)
      for (var x = 0; x < dims.x; x++) Coord(x, y),
  ];
  final start = rng.nextInt(cells.length);
  // sizes and tilts alike fall over to the next option when there's no room
  for (final (f, tilts) in iconPlacementOptions(rng, p, part)) {
    for (var step = 0; step < cells.length; step++) {
      final off = (step + 1) ~/ 2 * ((step % 2 == 0) ? 1 : -1);
      final pos = cells[(start + off) % cells.length];
      for (final tilted in tilts) {
        if (fits(pos, tilted ? Coord(f.y, f.x) : f)) {
          return NestingIcon(container, dims, [
            ...children,
            IconPlacement(pos, f, tilted, part),
          ], mayEmbedLarge: mayEmbedLarge);
        }
      }
    }
  }
  return null;
}

/// Greedy packing of parts into a root grid: each part in turn takes a free
/// spot against the cluster that keeps the cluster's larger dimension as small
/// as it can, ties drawn at random. Not an optimal packing — intended to
/// produce more visually interesting results than that would.
RootGridIcon _packRootGrid(GameRng rng, Parameters p, List<ItemIcon> parts) {
  parts = List.of(parts);
  shuffleInPlace(rng, parts);

  // pos and the untilted footprint the part was placed at
  final placed = <(Coord pos, Coord base, bool tilted, ItemIcon icon)>[];
  final occupied = <Coord>{};
  var minX = 0, minY = 0, maxX = 0, maxY = 0;

  void occupy(Coord pos, Coord fp) {
    for (var dx = 0; dx < fp.x; dx++) {
      for (var dy = 0; dy < fp.y; dy++) {
        occupied.add(Coord(pos.x + dx, pos.y + dy));
      }
    }
    minX = min(minX, pos.x);
    minY = min(minY, pos.y);
    maxX = max(maxX, pos.x + fp.x - 1);
    maxY = max(maxY, pos.y + fp.y - 1);
  }

  bool free(Coord pos, Coord fp) {
    for (var dx = 0; dx < fp.x; dx++) {
      for (var dy = 0; dy < fp.y; dy++) {
        if (occupied.contains(Coord(pos.x + dx, pos.y + dy))) return false;
      }
    }
    return true;
  }

  /// orthogonally adjacent to a cell that's already taken, so that the cluster
  /// stays one connected piece and nothing hangs off it by a corner
  bool touches(Coord pos, Coord fp) {
    for (var dx = 0; dx < fp.x; dx++) {
      for (var dy = 0; dy < fp.y; dy++) {
        final x = pos.x + dx, y = pos.y + dy;
        if (occupied.contains(Coord(x + 1, y)) ||
            occupied.contains(Coord(x - 1, y)) ||
            occupied.contains(Coord(x, y + 1)) ||
            occupied.contains(Coord(x, y - 1))) {
          return true;
        }
      }
    }
    return false;
  }

  {
    final (base, tilts) = iconPlacementOptions(rng, p, parts.first).first;
    final tilted = tilts.first;
    final f = tilted ? Coord(base.y, base.x) : base;
    placed.add((const Coord(0, 0), base, tilted, parts.first));
    occupy(const Coord(0, 0), f);
  }

  for (final part in parts.skip(1)) {
    // The root grid always has room, so a part never has to fall back to
    // another size here — only its preferred one is laid out. Its tilts do
    // still compete with each other, scored below.
    final (base, tilts) = iconPlacementOptions(rng, p, part).first;
    final candidates = <(Coord, Coord, bool)>[]; // pos, tilted fp, tilted
    for (final tilted in tilts) {
      final f = tilted ? Coord(base.y, base.x) : base;
      // Every free placement touching the cluster: its bounding box grown by
      // one footprint on each side covers all of them. The gaps *inside* the
      // cluster count — sweeping only the four outer edges meant a part could
      // never drop into a hole, so a fourth unit shape had to go outside a
      // 2x2 that was three quarters full and the grid came out 3x2 with a gap
      // in it. That's the minimize-the-max-dimension rule being broken by a
      // placement that was never offered, rather than by the scoring.
      for (var y = minY - f.y; y <= maxY + 1; y++) {
        for (var x = minX - f.x; x <= maxX + 1; x++) {
          final pos = Coord(x, y);
          if (free(pos, f) && touches(pos, f)) {
            candidates.add((pos, f, tilted));
          }
        }
      }
    }
    // Score by the resulting cluster's max dimension, and retain *every*
    // placement that ties the leader across all four sides and both tilts, so
    // that tilted candidates get a fair share of the draw.
    var best = 1 << 30;
    final scored = <(Coord, Coord, bool, int)>[];
    for (final (pos, f, tilted) in candidates) {
      // min/max are split into their own int-typed locals: minX and friends
      // are closure-captured, which spoils the analyzer's inference when
      // they're used inline in a larger arithmetic expression
      final int right = max(maxX, pos.x + f.x - 1);
      final int left = min(minX, pos.x);
      final int bottom = max(maxY, pos.y + f.y - 1);
      final int top = min(minY, pos.y);
      final maxDim = max(right - left + 1, bottom - top + 1);
      best = min(best, maxDim);
      scored.add((pos, f, tilted, maxDim));
    }
    final retained = [
      for (final s in scored)
        if (s.$4 == best) s,
    ];
    final (pos, f, tilted, _) = retained[rng.nextInt(retained.length)];
    placed.add((pos, base, tilted, part));
    occupy(pos, f);
  }

  return RootGridIcon(Coord(maxX - minX + 1, maxY - minY + 1), [
    for (final (pos, base, tilted, icon) in placed)
      IconPlacement(Coord(pos.x - minX, pos.y - minY), base, tilted, icon),
  ]);
}

class ItemWidget extends StatelessWidget {
  final Item item;
  final double size;
  final bool outlineOn;
  const ItemWidget(
    this.item, {
    super.key,
    this.size = 13,
    this.outlineOn = false,
  });
  @override
  Widget build(BuildContext context) {
    // grow past the requested size, up to maxIconGrowth, so that leaf shapes
    // stay legible without deep icons ballooning
    final rendered = max(
      size,
      min(
        size * maxIconGrowth,
        minLeafItemScale * defaultItemSpan / max(leafScale(item.icon), 0.001),
      ),
    );
    return CustomPaint(
      size: iconBox(item.icon, rendered),
      painter: ItemIconPainter(item.icon, outlineOn),
    );
  }
}

class ItemIconPainter extends CustomPainter {
  final ItemIcon icon;
  final bool outlineOn;
  ItemIconPainter(this.icon, [this.outlineOn = false]);
  @override
  void paint(Canvas canvas, Size size) =>
      paintItemIcon(canvas, icon, Offset.zero & size, outlineOn: outlineOn);
  @override
  bool shouldRepaint(ItemIconPainter old) =>
      old.icon != icon || old.outlineOn != outlineOn;
}

// ────────────────────────────── trader generation ──────────────────────────────

typedef RequiredTraderGen =
    Trader? Function(
      GameRng rng,
      ItemCatalog cat,
      int iItem,
      List<Item> thisTierRequired,
      int iTier,
      List<Item>? nextTierRequired,
    );
typedef SupplementalTraderGen =
    Trader? Function(GameRng rng, ItemCatalog cat, int iTier);

class TraderGeneratorsForTier {
  final List<(double, RequiredTraderGen)> requiredGenerators;
  final int supplementalRuns;
  final List<(double, SupplementalTraderGen)> supplementalGenerators;
  const TraderGeneratorsForTier({
    required this.requiredGenerators,
    required this.supplementalRuns,
    required this.supplementalGenerators,
  });
}

int otherItemIndex(GameRng rng, int iItem, int tierLength) {
  while (true) {
    final other = rng.nextInt(tierLength);
    if (other != iItem) return other;
  }
}

Item _pick(GameRng rng, List<Item> tier) => tier[rng.nextInt(tier.length)];

/// A trader may never give an item it also takes, so a side output drawn from
/// a tier the trader also consumes from is drawn excluding its own inputs.
/// Returns null when the tier has nothing left over, in which case the caller
/// drops the side output rather than failing — failing would strand whatever
/// the generator has already popped off the required list.
Item? _pickExcluding(GameRng rng, List<Item> tier, List<Quantity> takes) {
  final free = [
    for (final it in tier)
      if (!takes.any((q) => identical(q.item, it))) it,
  ];
  return free.isEmpty ? null : free[rng.nextInt(free.length)];
}

/// Traders are directed hyperedges over the item tiers. Per tier the
/// generation loop keeps a shuffled "required" clone of this tier (everything
/// must be consumable) and of the next tier (everything must be producible),
/// and runs generators until both are drained. See the design doc.
///
/// This is [Parameters.levelOne]'s table — the live one, the one the doc
/// describes. [urTraders] is the copy it started as.
List<TraderGeneratorsForTier> levelOneTraders(int nItemTiers) {
  return List.generate(nItemTiers, (_) {
    return TraderGeneratorsForTier(
      requiredGenerators: [
        // links two items to the next tier
        (
          15,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            final b = cur[otherItemIndex(rng, iItem, cur.length)];
            return Trader(mergeQuantities([Quantity(a, 1), Quantity(b, 1)]), [
              Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
            ]);
          },
        ),
        // links one item to an item in the same tier
        (
          3,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            final cur = cat.tiers[iTier];
            final a = thisReq.popOrNull() ?? cur[iItem];
            final give = cur[otherItemIndex(rng, a.iInTier, cur.length)];
            return Trader([Quantity(a, 1)], [Quantity(give, 1)]);
          },
        ),
        // links two items to an item from the same tier
        (
          1,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            final cur = cat.tiers[iTier];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            final b = cur[otherItemIndex(rng, a.iInTier, cur.length)];
            Item give;
            do {
              give = _pick(rng, cur);
            } while (identical(give, a) || identical(give, b));
            return Trader(mergeQuantities([Quantity(a, 1), Quantity(b, 1)]), [
              Quantity(give, 1),
            ]);
          },
        ),
        // links four items of the same type to one item in the next tier
        (
          5,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            return Trader(
              [Quantity(a, 4)],
              [Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1)],
            );
          },
        ),
        // links three items to the next tier and produces one side item from
        // the current tier
        (
          6,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            final side = _pickExcluding(rng, cur, takes);
            return Trader(
              takes,
              mergeQuantities([
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
                if (side != null) Quantity(side, 1),
              ]),
            );
          },
        ),
        // links four items to the next tier and produces one side item from
        // the current tier and one from the prior tier
        (
          2,
          (rng, cat, iItem, thisReq, iTier, nextReq) =>
              _levelOneFourToNextWithSides(rng, cat, thisReq, iTier, nextReq),
        ),
        // (the doc lists this generator twice; kept as written)
        (
          2,
          (rng, cat, iItem, thisReq, iTier, nextReq) =>
              _levelOneFourToNextWithSides(rng, cat, thisReq, iTier, nextReq),
        ),
        // from four items of the current tier to two items of the next tier
        (
          4,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            return Trader(
              takes,
              mergeQuantities([
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
              ]),
            );
          },
        ),
        // links three items to the next tier
        (
          8,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            return Trader(takes, [
              Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
            ]);
          },
        ),
      ],
      supplementalRuns: 3,
      supplementalGenerators: [
        // takes an item and produces two (iTier - 1) items
        (
          10,
          (rng, cat, iTier) {
            if (iTier == 0) return null;
            final prior = cat.tiers[iTier - 1];
            return Trader(
              [Quantity(_pick(rng, cat.tiers[iTier]), 1)],
              mergeQuantities([
                Quantity(_pick(rng, prior), 1),
                Quantity(_pick(rng, prior), 1),
              ]),
            );
          },
        ),
        // takes two items and produces one from (iTier - 1) and 2 from (iTier - 2)
        (
          5,
          (rng, cat, iTier) {
            if (iTier < 2) return null;
            final cur = cat.tiers[iTier];
            return Trader(
              mergeQuantities([
                Quantity(_pick(rng, cur), 1),
                Quantity(_pick(rng, cur), 1),
              ]),
              mergeQuantities([
                Quantity(_pick(rng, cat.tiers[iTier - 1]), 1),
                Quantity(_pick(rng, cat.tiers[iTier - 2]), 1),
                Quantity(_pick(rng, cat.tiers[iTier - 2]), 1),
              ]),
            );
          },
        ),
      ],
    );
  });
}

Trader? _levelOneFourToNextWithSides(
  GameRng rng,
  ItemCatalog cat,
  List<Item> thisReq,
  int iTier,
  List<Item>? nextReq,
) {
  if (nextReq == null || iTier == 0) return null;
  final cur = cat.tiers[iTier];
  final next = cat.tiers[iTier + 1];
  final takes = mergeQuantities([
    Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
  ]);
  final side = _pickExcluding(rng, cur, takes);
  return Trader(
    takes,
    mergeQuantities([
      Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
      if (side != null) Quantity(side, 1),
      Quantity(_pick(rng, cat.tiers[iTier - 1]), 1),
    ]),
  );
}

/// [levelOneTraders] as it stood on 2026-07-27, frozen for
/// [Parameters.urLevel]. A copy rather than a reference, down to its own copy
/// of the four-to-next generator: the whole point of it is to stop following
/// the table it was copied from. The doc's account of these generators is the
/// live table's, not this one's.
List<TraderGeneratorsForTier> urTraders(int nItemTiers) {
  return List.generate(nItemTiers, (_) {
    return TraderGeneratorsForTier(
      requiredGenerators: [
        // links two items to the next tier
        (
          15,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            final b = cur[otherItemIndex(rng, iItem, cur.length)];
            return Trader(mergeQuantities([Quantity(a, 1), Quantity(b, 1)]), [
              Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
            ]);
          },
        ),
        // links one item to an item in the same tier
        (
          3,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            final cur = cat.tiers[iTier];
            final a = thisReq.popOrNull() ?? cur[iItem];
            final give = cur[otherItemIndex(rng, a.iInTier, cur.length)];
            return Trader([Quantity(a, 1)], [Quantity(give, 1)]);
          },
        ),
        // links two items to an item from the same tier
        (
          1,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            final cur = cat.tiers[iTier];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            final b = cur[otherItemIndex(rng, a.iInTier, cur.length)];
            Item give;
            do {
              give = _pick(rng, cur);
            } while (identical(give, a) || identical(give, b));
            return Trader(mergeQuantities([Quantity(a, 1), Quantity(b, 1)]), [
              Quantity(give, 1),
            ]);
          },
        ),
        // links four items of the same type to one item in the next tier
        (
          5,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final a = thisReq.popOrNull() ?? _pick(rng, cur);
            return Trader(
              [Quantity(a, 4)],
              [Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1)],
            );
          },
        ),
        // links three items to the next tier and produces one side item from
        // the current tier
        (
          6,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            final side = _pickExcluding(rng, cur, takes);
            return Trader(
              takes,
              mergeQuantities([
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
                if (side != null) Quantity(side, 1),
              ]),
            );
          },
        ),
        // links four items to the next tier and produces one side item from
        // the current tier and one from the prior tier
        (
          2,
          (rng, cat, iItem, thisReq, iTier, nextReq) =>
              _urFourToNextWithSides(rng, cat, thisReq, iTier, nextReq),
        ),
        // (the doc lists this generator twice; kept as written)
        (
          2,
          (rng, cat, iItem, thisReq, iTier, nextReq) =>
              _urFourToNextWithSides(rng, cat, thisReq, iTier, nextReq),
        ),
        // from four items of the current tier to two items of the next tier
        (
          4,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            return Trader(
              takes,
              mergeQuantities([
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
                Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
              ]),
            );
          },
        ),
        // links three items to the next tier
        (
          8,
          (rng, cat, iItem, thisReq, iTier, nextReq) {
            if (nextReq == null) return null;
            final cur = cat.tiers[iTier];
            final next = cat.tiers[iTier + 1];
            final takes = mergeQuantities([
              Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
              Quantity(_pick(rng, cur), 1),
            ]);
            return Trader(takes, [
              Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
            ]);
          },
        ),
      ],
      supplementalRuns: 3,
      supplementalGenerators: [
        // takes an item and produces two (iTier - 1) items
        (
          10,
          (rng, cat, iTier) {
            if (iTier == 0) return null;
            final prior = cat.tiers[iTier - 1];
            return Trader(
              [Quantity(_pick(rng, cat.tiers[iTier]), 1)],
              mergeQuantities([
                Quantity(_pick(rng, prior), 1),
                Quantity(_pick(rng, prior), 1),
              ]),
            );
          },
        ),
        // takes two items and produces one from (iTier - 1) and 2 from (iTier - 2)
        (
          5,
          (rng, cat, iTier) {
            if (iTier < 2) return null;
            final cur = cat.tiers[iTier];
            return Trader(
              mergeQuantities([
                Quantity(_pick(rng, cur), 1),
                Quantity(_pick(rng, cur), 1),
              ]),
              mergeQuantities([
                Quantity(_pick(rng, cat.tiers[iTier - 1]), 1),
                Quantity(_pick(rng, cat.tiers[iTier - 2]), 1),
                Quantity(_pick(rng, cat.tiers[iTier - 2]), 1),
              ]),
            );
          },
        ),
      ],
    );
  });
}

Trader? _urFourToNextWithSides(
  GameRng rng,
  ItemCatalog cat,
  List<Item> thisReq,
  int iTier,
  List<Item>? nextReq,
) {
  if (nextReq == null || iTier == 0) return null;
  final cur = cat.tiers[iTier];
  final next = cat.tiers[iTier + 1];
  final takes = mergeQuantities([
    Quantity(thisReq.popOrNull() ?? _pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
    Quantity(_pick(rng, cur), 1),
  ]);
  final side = _pickExcluding(rng, cur, takes);
  return Trader(
    takes,
    mergeQuantities([
      Quantity(nextReq.popOrNull() ?? _pick(rng, next), 1),
      if (side != null) Quantity(side, 1),
      Quantity(_pick(rng, cat.tiers[iTier - 1]), 1),
    ]),
  );
}

List<Trader> generateTraders(GameRng rng, Parameters p, ItemCatalog cat) {
  final out = <Trader>[];
  for (var iTier = 0; iTier < cat.tiers.length; iTier++) {
    final gens = p.traderGeneratorsPerTier[iTier];
    final thisReq = shuffledClone(rng, cat.tiers[iTier]);
    final nextReq = iTier + 1 < cat.tiers.length
        ? shuffledClone(rng, cat.tiers[iTier + 1])
        : null;
    while (thisReq.isNotEmpty || (nextReq?.isNotEmpty ?? false)) {
      for (var iItem = 0; iItem < cat.tiers[iTier].length; iItem++) {
        Trader? t;
        var guard = 0;
        while (t == null && guard++ < 1000) {
          t = weightedPick(rng, gens.requiredGenerators)(
            rng,
            cat,
            iItem,
            thisReq,
            iTier,
            nextReq,
          );
        }
        if (t != null) out.add(t);
      }
    }
    for (var k = 0; k < gens.supplementalRuns; k++) {
      final t = weightedPick(rng, gens.supplementalGenerators)(rng, cat, iTier);
      if (t != null) out.add(t);
    }
  }
  assert(
    out.every(
      (t) => !t.gives.any((g) => t.takes.any((k) => identical(k.item, g.item))),
    ),
    'a trader gives an item it also takes',
  );
  // a eudaimonia trader for each final tier item
  for (final it in cat.finalTier) {
    out.add(Trader([Quantity(it, 1)], [Quantity(cat.eudaimonia, 1)]));
  }
  // roll timing (eudaimonia redemptions stay instant)
  for (final t in out) {
    if (t.gives.any((q) => q.item.isEudaimonia)) continue;
    if (!rng.chance(p.traderInstantProb)) {
      t.duration = roundToSecond(
        rangeIn(rng, p.tradeDurationRange.$1, p.tradeDurationRange.$2),
      );
    }
    if (rng.chance(p.traderCooldownProb)) {
      t.cooldown = roundToSecond(
        rangeIn(rng, p.traderCooldownRange.$1, p.traderCooldownRange.$2),
      );
    }
  }
  return out;
}

// ────────────────────────────── world graph ──────────────────────────────

class Node {
  Offset pos; // world units
  final List<Edge> edges = [];
  final List<Facility> facilities = [];
  final Signal<List<Player>> playersPresent = signal(const []);

  /// paint order among the node overlays: higher goes on top, and 0 means the
  /// node has never been raised, so it sits in generation order down in the
  /// pile. See [Game.raiseNode].
  int stackRank = 0;

  /// Which of the three colourings this node drew, and the item colour it
  /// stains itself with. Level state, the pair of them — enough to write down
  /// and read back, which a resolved colour wouldn't be: the base a tone
  /// departs from belongs to whichever palette is up, so the colour itself can
  /// only be worked out at paint time. See [nodeColor].
  ///
  /// [tint] is only consulted for [NodeTone.tinted]; the other two tones don't
  /// stain, and a node with nothing to stain itself with picks one of them
  /// rather than carrying a tint it hasn't got.
  NodeTone tone = NodeTone.plain;
  Color tint = edgeGrey;

  // grid bookkeeping, only meaningful during levelgen
  int gridRow = -1, gridCol = -1;
  Node(this.pos);

  /// what a player has to be carrying to get anything out of this node — what
  /// its facilities demand, not what they hand out. [NodeTone.tinted] draws
  /// its tint from these, so a node ends up wearing the colour of the thing it
  /// wants.
  List<Item> get requiredItems => [
    for (final f in facilities) ...f.requiredItems,
  ];

  /// whether there's a blight here to be caught in. Colours the node; see
  /// [nodeColor]. A mugger is deliberately not one of these: it's a toll
  /// rather than a wave, and it's already legible from its own badge.
  bool get isHazard => facilities.any((f) => f.isHazard);
}

/// The three colourings a node draws from. All three stay within a hair of the
/// graph's own colour, because a node is first of all part of the graph and
/// only then itself. Which pair of colours the first two mean depends on
/// whether the node is a train; see [nodeColor].
enum NodeTone {
  /// the graph's colour
  plain,

  /// its other standard colour, a step further off the ground
  deeper,

  /// the plain colour, stained with an item colour from the node's own
  /// facilities
  tinted,
}

/// how much of the item colour [NodeTone.tinted] stains its node with. Barely
/// any — enough that two nodes side by side are told apart, not enough that a
/// node reads as belonging to a colour. These are three nodes of one graph,
/// not three kinds of node.
const double nodeTintAmount = 0.13;

/// A node's own colour: its dot on the map, the wires running out of it, and
/// the lozenges its facilities render into. Reads [palette], so it changes with
/// the half of the day. A tinted node is the plain colour stained; the other
/// two tones are colours in their own right, written out in the scheme. A node
/// that bites is the hazard colour whatever it rolled.
Color nodeColor(Node n) {
  if (n.isHazard) return palette.hazardNode;
  final train = n is TrainNode;
  final plain = train ? palette.trainNode : palette.node;
  return switch (n.tone) {
    NodeTone.plain => plain,
    NodeTone.deeper => train ? palette.trainNodeDarker : palette.nodeDarker,
    NodeTone.tinted => Color.lerp(plain, n.tint, nodeTintAmount)!,
  };
}

/// The fill of a lozenge sitting on a node of colour [tone]: that colour at a
/// fraction of its saturation, carried part of the way to the scheme's lozenge
/// grey. It stays the node's colour throughout — a node further off the ground
/// keeps a lozenge further off the ground — it just gets there having been
/// pulled towards something neutral and dark.
Color lozengeFill(Color tone) {
  final c = HSLuvColor.fromColor(tone);
  final washed = HSLuvColor.fromHSL(
    c.hue,
    c.saturation * palette.lozengeSaturation,
    c.lightness,
  ).toColor();
  return Color.lerp(washed, palette.lozengeTint, palette.lozengeTintp)!;
}

/// whether a colour has enough of a hue to stain anything with. The item
/// palette carries two greys, and a node tinted with one of those has drawn
/// [NodeTone.tinted] and come out looking like it drew [NodeTone.plain].
bool hasHue(Color c) => HSLuvColor.fromColor(c).saturation > 20;

class Edge {
  final Node a, b;

  /// non-null for the temporary station↔train edge that exists while [dockTrain]
  /// is docked; players walk it to board
  final TrainNode? dockTrain;
  Edge(this.a, this.b, {this.dockTrain});
  double get length => (a.pos - b.pos).distance;
  Node other(Node n) => identical(n, a) ? b : a;
  double angleFromNode(Node n) => offsetAngle(other(n).pos - n.pos);
}

/// Base class for entities that have positions in the graph and can have move
/// paths scheduled (for now only players move along move paths).
abstract class Thing {
  final Signal<Node?> at = signal(null); // null while traversing an edge
  void update(Game g, double dt);
}

class MovePath {
  final List<Node> nodes = [];
  final List<double> departureTimes = []; // game-time; "not before" semantics
  void clear() {
    nodes.clear();
    departureTimes.clear();
  }
}

class Player extends Thing {
  final String name;
  final Color color;
  final Signal<List<Item>> inventory = signal(const []);
  final Signal<double> incapacitatedFor = signal(0.0); // > 0 blocks everything
  /// flashes their inventory red — muggings and blights
  final RedFlash flash = RedFlash();
  final MovePath plan = MovePath();
  Edge? traversing;
  Node? traversalTarget;
  double traversalProgress = 0;
  Player(this.name, this.color);

  Offset worldPos() {
    if (traversing != null) {
      final from = traversing!.other(traversalTarget!);
      return Offset.lerp(
        from.pos,
        traversalTarget!.pos,
        clampUnit(traversalProgress),
      )!;
    }
    return at.value?.pos ?? Offset.zero;
  }

  @override
  void update(Game g, double dt) {
    flash.expire(g.gameTime);
    if (incapacitatedFor.value > 0) {
      incapacitatedFor.value = max(0.0, incapacitatedFor.value - dt);
      return;
    }
    if (traversing != null) {
      final len = max(traversing!.length, 0.001);
      traversalProgress += dt * g.params.playerSpeed / len;
      if (traversalProgress >= 1) _arrive(g);
    } else if (plan.nodes.isNotEmpty &&
        g.gameTime >= plan.departureTimes.first) {
      _depart(g);
    }
  }

  void _depart(Game g) {
    final from = at.value;
    if (from == null) return;
    final target = plan.nodes.first;
    final edge = from.edges.firstWhereOrNull(
      (e) => identical(e.other(from), target),
    );
    if (edge == null) {
      // the wire no longer exists (its train left) — abandon the plan
      plan.clear();
      return;
    }
    plan.nodes.removeAt(0);
    plan.departureTimes.removeAt(0);
    traversing = edge;
    traversalTarget = target;
    traversalProgress = 0;
    at.value = null;
    from.playersPresent.value = from.playersPresent.value
        .where((p) => !identical(p, this))
        .toList();
  }

  void _arrive(Game g) {
    final node = traversalTarget!;
    traversing = null;
    traversalTarget = null;
    traversalProgress = 0;
    at.value = node;
    node.playersPresent.value = [...node.playersPresent.value, this];
    g.raiseNode(node);
    for (final f in List.of(node.facilities)) {
      f.onPlayerEntered(g, this);
    }
  }
}

// ────────────────────────────── trains ──────────────────────────────

sealed class TrainSchedule {
  const TrainSchedule();
}

/// only moves when a player moves it
class NeverSchedule extends TrainSchedule {
  const NeverSchedule();
}

/// manually moved out; auto-returns to its initial station after arrival ('sc(o)')
class OneWaySchedule extends TrainSchedule {
  const OneWaySchedule();
}

/// shuttles on its own, on a division clock interval — so many departures a
/// day, always at the same times ('sc(12.5)'); can't be controlled
class CycleSchedule extends TrainSchedule {
  final ClockInterval interval;
  const CycleSchedule(this.interval);
  double get seconds => interval.period;
}

/// Trains ARE nodes: they hold facilities and players like any other node.
/// They dock at terminus points held just off their station nodes; while
/// docked a temporary walkable edge to the station exists, and the permanent
/// shortcut between termini is theirs alone. A train takes its colour from the
/// scheme like every other node — see [Palette.trainNode] — and its rails take
/// it from the train.
class TrainNode extends Node {
  final TrainSpeed speed;
  final Quantity? activation; // must be held by the mover
  final bool activationConsumed; // true (an actual cost) less often
  final bool movableFromInside;
  final TrainSchedule schedule;
  final List<Node> stationNodes;
  final Map<Node, Offset> terminusFor;
  final Signal<Node?> dockedAt = signal(null);
  final Signal<double> transitRemaining = signal(0.0);
  double _transitTotal = 0;
  Offset _fromPos = Offset.zero, _toPos = Offset.zero;
  Node? _toStation;
  Edge? _dockEdge;

  /// countdown to an automatic departure while docked; -1 = none
  final Signal<double> waitRemaining = signal(-1.0);

  TrainNode({
    required Offset pos,
    required this.speed,
    required this.activation,
    required this.activationConsumed,
    required this.movableFromInside,
    required this.schedule,
    required this.stationNodes,
    required this.terminusFor,
  }) : super(pos);

  Node get homeStation => stationNodes.first;

  /// a train's activation item is a demand the train itself makes, on top of
  /// whatever its facilities want
  @override
  List<Item> get requiredItems => [
    ...super.requiredItems,
    if (activation != null) activation!.item,
  ];

  double unitsPerSec(Parameters p) => p.trainSpeedUnitsPerSec[speed]!;

  double travelTimeBetween(Node s1, Node s2, Parameters p) =>
      (terminusFor[s1]! - terminusFor[s2]!).distance / unitsPerSec(p);

  bool get manualAllowed => switch (schedule) {
    NeverSchedule _ => true,
    OneWaySchedule _ => identical(dockedAt.value, homeStation),
    CycleSchedule _ => false,
  };

  bool dockEdgeBusy(Game g) =>
      _dockEdge != null &&
      g.players.any((p) => identical(p.traversing, _dockEdge));

  void dock(Game g, Node station) {
    pos = terminusFor[station]!;
    dockedAt.value = station;
    _dockEdge = Edge(station, this, dockTrain: this);
    station.edges.add(_dockEdge!);
    edges.add(_dockEdge!);
    g.edges.add(_dockEdge!);
    waitRemaining.value = switch (schedule) {
      OneWaySchedule _ when !identical(station, homeStation) =>
        g.params.oneWayReturnDelay,
      // cycle trains leave at their clock times, not a fixed wait after docking
      CycleSchedule c => c.interval.remainingAt(g.gameTime),
      _ => -1,
    };
  }

  void departTo(Game g, Node station) {
    final from = dockedAt.value;
    if (from == null || identical(from, station)) return;
    if (_dockEdge != null) {
      from.edges.remove(_dockEdge);
      edges.remove(_dockEdge);
      g.edges.remove(_dockEdge);
      _dockEdge = null;
    }
    dockedAt.value = null;
    _fromPos = pos;
    _toPos = terminusFor[station]!;
    _toStation = station;
    _transitTotal = max(0.001, travelTimeBetween(from, station, g.params));
    transitRemaining.value = _transitTotal;
    waitRemaining.value = -1;
  }

  Node? _nextAutoStation() {
    final here = dockedAt.value;
    if (here == null) return null;
    return switch (schedule) {
      OneWaySchedule _ => identical(here, homeStation) ? null : homeStation,
      CycleSchedule _ => stationNodes.firstWhereOrNull(
        (s) => !identical(s, here),
      ),
      NeverSchedule _ => null,
    };
  }

  void updateTrain(Game g, double dt) {
    if (dockedAt.value == null && _toStation != null) {
      transitRemaining.value = max(0.0, transitRemaining.value - dt);
      final t = 1 - transitRemaining.value / _transitTotal;
      pos = Offset.lerp(_fromPos, _toPos, clampUnit(t))!;
      if (transitRemaining.value <= 0) {
        final st = _toStation!;
        _toStation = null;
        dock(g, st);
      }
    } else if (waitRemaining.value >= 0) {
      waitRemaining.value -= dt;
      if (waitRemaining.value <= 0) {
        final next = _nextAutoStation();
        if (next == null) {
          waitRemaining.value = -1;
        } else if (dockEdgeBusy(g)) {
          waitRemaining.value = 0.1; // someone's boarding; try again shortly
        } else {
          departTo(g, next);
        }
      }
    }
  }
}

// ────────────────────────────── facilities ──────────────────────────────

abstract class Facility {
  late Node node; // assigned at placement

  /// which half of the day this facility operates in; set at generation
  ActivePhase activePhase = ActivePhase.always;

  bool activeNow(Game g) => switch (activePhase) {
    ActivePhase.always => true,
    ActivePhase.dayOnly => !g.isNight.value,
    ActivePhase.nightOnly => g.isNight.value,
  };

  /// non-null if this facility runs on a clock interval, in which case its
  /// badge shows the clock time beside its countdown pie
  ClockInterval? get clockSchedule => null;

  /// the compact render inside the node widget (the doc's `render:` lines)
  Widget badge(Game g, NodeZoomLevel level);

  /// What this facility demands of a player — what it takes, never what it
  /// gives. See [Node.requiredItems].
  List<Item> get requiredItems => const [];

  /// whether this is one of the things on the map that a player has to see
  /// coming from across it; see [Node.isHazard]
  bool get isHazard => false;

  /// Facilities build their badge lozenge through this rather than calling
  /// [badgeRow] directly: it slots the day or night marker into the row at
  /// full strength — it's part of the icon flow, not an annotation hung off
  /// the side — and dims only the contents when the facility is out of hours.
  /// The marker stays visible when zoomed out.
  Widget phaseBadgeRow(Game g, List<Widget> children) {
    final tone = nodeColor(node);
    if (activePhase == ActivePhase.always) {
      return badgeRow(children, tone: tone);
    }
    final dayOnly = activePhase == ActivePhase.dayOnly;
    return SignalBuilder(builder: (context) {
      return badgeRow(
        children,
        tone: tone,
        dim: !activeNow(g),
        leading: Align(
          alignment: dayOnly ? Alignment.topCenter : Alignment.bottomCenter,
          // smaller than the material icons had to be: these shapes hold up
          child: phaseIcon(!dayOnly, size: 7, color: palette.ink),
        ),
      );
    });
  }

  /// the tooltip shown when the badge is tapped: paraphrases the icon
  /// sequence in english, except items, which display as their icons at
  /// full size
  List<InlineSpan> describe(Game g);

  /// action widgets surfaced in the selected player's control panel when
  /// they're at this facility's node
  List<Widget> actionsFor(Game g, Player p) => const [];

  void update(Game g, double dt) {}

  void onPlayerEntered(Game g, Player p) {}

  /// The hours clause every [describe] gets for free. The badge's day or night
  /// marker says the same thing, but that mark is seven pixels of silhouette —
  /// the tooltip is where a player goes to find out what it meant.
  List<InlineSpan> get _hoursNote => switch (activePhase) {
    ActivePhase.always => const [],
    ActivePhase.dayOnly => [tipText('; only active during the day')],
    ActivePhase.nightOnly => [tipText('; only active at night')],
  };

  /// wraps a badge so tapping it shows the explanation tooltip (and tapping it
  /// again closes it)
  Widget explainTap(Game g, Widget child) => GestureDetector(
    onTap: () =>
        g.toggleTooltip(this, node, () => [...describe(g), ..._hoursNote]),
    child: child,
  );
}

/// item icon size for a badge at the given zoom level
double itemSizeFor(NodeZoomLevel level) => switch (level) {
  NodeZoomLevel.selected => defaultItemSpan, // full size, legible
  _ => 11, // the standard shrunk width
};

class Station extends Facility {
  final TrainNode train;
  final StationControl control;
  Station(this.train, this.control);

  @override
  Widget badge(Game g, NodeZoomLevel level) => explainTap(
    g,
    phaseBadgeRow(g, [
      badgeText('s'),
      badgeIcon(Icons.train),
      if (level != NodeZoomLevel.small) ...[
        if (control == StationControl.remote) badgeIcon(Icons.swipe_right_alt),
        if (control == StationControl.localOnly) ...[
          badgeText('L'),
          badgeIcon(Icons.swipe_right_alt),
        ],
      ],
    ]),
  );

  @override
  List<InlineSpan> describe(Game g) {
    final speedName = switch (train.speed) {
      TrainSpeed.s => 'slow',
      TrainSpeed.r => 'regular',
      TrainSpeed.f => 'fast',
      TrainSpeed.i => 'very fast',
    };
    final controlDesc = switch (control) {
      StationControl.none => "this station can't move the train",
      StationControl.remote => 'this station can control the train',
      StationControl.localOnly =>
        'this station can move the train only while it waits here',
    };
    return [tipText('a station of a $speedName train; $controlDesc')];
  }

  @override
  List<Widget> actionsFor(Game g, Player p) {
    if (control == StationControl.none) return const [];
    return [
      SignalBuilder(builder: (context) {
        final docked = train.dockedAt.value;
        final target = train.stationNodes.firstWhereOrNull(
          (s) => !identical(s, node),
        );
        final controlSatisfied =
            docked != null &&
            (control == StationControl.remote || identical(docked, node));
        final enabled =
            controlSatisfied &&
            train.manualAllowed &&
            !train.dockEdgeBusy(g) &&
            (train.activation == null || g.playerHas(p, [train.activation!]));
        final time = docked != null && target != null
            ? train.travelTimeBetween(docked, target, g.params)
            : null;
        return DragDirectionPad(
          dimension: 64,
          enabled: enabled,
          onAngle: (a) => g.manualTrainMove(train, p, a),
          label: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  badgeIcon(Icons.train),
                  badgeIcon(Icons.swipe_right_alt),
                ],
              ),
              if (time != null) badgeText('${fmtSec(time)}s'),
              if (train.activation != null) quantityWidget(train.activation!),
            ],
          ),
        );
      }),
    ];
  }
}

class Tree extends Facility {
  final List<Quantity> produces; // one or two tier-0/1 items

  /// Either kind of interval: an arbitrary one regrows that many seconds after
  /// it's picked, a clock one regrows at its times of day however long ago it
  /// was picked.
  final Interval regen;
  final Signal<bool> picked = signal(false);

  /// for clock regen: which repetition it was picked in — it's back once the
  /// interval has come round again
  int _pickedInCycle = 0;
  Tree(this.produces, this.regen);

  bool get ready => !picked.value;

  @override
  ClockInterval? get clockSchedule =>
      regen is ClockInterval ? regen as ClockInterval : null;

  /// what the pie counts down: seconds until the fruit is back
  final Signal<double> regenRemaining = signal(0.0);
  double get regenTotal => regen.period;

  @override
  void update(Game g, double dt) {
    if (!picked.value) return;
    switch (regen) {
      case ArbitraryInterval a:
        regenRemaining.value = a.remainingAt(g.gameTime);
        if (a.elapsedAt(g.gameTime)) picked.value = false;
      case ClockInterval c:
        if (c.cycleAt(g.gameTime) > _pickedInCycle) {
          picked.value = false;
        } else {
          regenRemaining.value = c.remainingAt(g.gameTime);
        }
    }
    if (!picked.value) regenRemaining.value = 0;
  }

  void harvest(Game g, Player p) {
    if (!ready || !identical(p.at.value, node)) return;
    if (!g.roomFor(p, produces)) return;
    g.giveItems(p, produces);
    picked.value = true;
    switch (regen) {
      case ArbitraryInterval a:
        a.start(g.gameTime);
        regenRemaining.value = a.period;
      case ClockInterval c:
        _pickedInCycle = c.cycleAt(g.gameTime);
        regenRemaining.value = c.remainingAt(g.gameTime);
    }
  }

  @override
  // tapping a plant on the map only explains it — harvesting is the control
  // panel's job
  Widget badge(Game g, NodeZoomLevel level) => explainTap(
    g,
    SignalBuilder(builder: (context) {
      return withPie(
        phaseBadgeRow(g, [
          badgeIcon(Icons.local_florist),
          if (level != NodeZoomLevel.small)
            for (final q in produces)
              quantityWidget(q, size: itemSizeFor(level)),
        ]),
        pie: CountdownPie(
          remaining: regenRemaining,
          total: regenTotal,
          isCooldown: true,
          clock: clockSchedule,
        ),
      );
    }),
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('a plant producing '),
    ...quantitiesSpans(produces),
    tipText(switch (regen) {
      ArbitraryInterval a => '; regrows ${fmtSec(a.period)}s after harvest',
      ClockInterval c => '; regrows ${describeClock(c)}',
    }),
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) => [
    SignalBuilder(builder: (context) {
      final enabled = ready && g.roomFor(p, produces);
      // subscribe to inventory so room updates re-enable the chip
      p.inventory.value;
      return actionChip(
        enabled: enabled,
        onTap: () => harvest(g, p),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: badgeGap,
          children: [
            badgeIcon(Icons.local_florist),
            badgeText('take'),
            for (final q in produces) quantityWidget(q),
          ],
        ),
      );
    }),
  ];
}

class Trader extends Facility {
  final List<Quantity> takes, gives;

  @override
  List<Item> get requiredItems => [for (final q in takes) q.item];

  double duration = 0; // 0 = instant
  double cooldown = 0; // 0 = none
  final Signal<double> workRemaining = signal(0.0);
  final Signal<double> cooldownRemaining = signal(0.0);
  final Signal<List<Quantity>> pendingOutput = signal(const []);
  Player? _worker;
  Trader(this.takes, this.gives);

  bool get busy => workRemaining.value > 0;
  bool get cooling => cooldownRemaining.value > 0;

  bool canTrade(Game g, Player p) =>
      !busy &&
      !cooling &&
      pendingOutput.value.isEmpty &&
      identical(p.at.value, node) &&
      g.playerHas(p, takes) &&
      (duration > 0 || _roomForInstant(g, p));

  bool _roomForInstant(Game g, Player p) {
    final takesN = takes.fold(0, (a, q) => a + q.n);
    final givesN = gives
        .where((q) => !q.item.isEudaimonia)
        .fold(0, (a, q) => a + q.n);
    return p.inventory.value.length - takesN + givesN <= g.params.inventoryCap;
  }

  void startTrade(Game g, Player p) {
    if (!canTrade(g, p)) return;
    g.takeItems(p, takes);
    if (duration <= 0) {
      _deliver(g, p);
    } else {
      workRemaining.value = duration;
      _worker = p;
    }
  }

  void _deliver(Game g, Player? p) {
    var leftovers = gives;
    if (p != null && identical(p.at.value, node)) {
      leftovers = g.giveItems(p, gives);
    }
    if (leftovers.isNotEmpty) {
      pendingOutput.value = [...pendingOutput.value, ...leftovers];
    }
    if (cooldown > 0) cooldownRemaining.value = cooldown;
  }

  void collect(Game g, Player p) {
    if (!identical(p.at.value, node)) return;
    pendingOutput.value = g.giveItems(p, pendingOutput.value);
  }

  @override
  void update(Game g, double dt) {
    if (workRemaining.value > 0) {
      workRemaining.value = max(0.0, workRemaining.value - dt);
      if (workRemaining.value <= 0) {
        final w = _worker;
        _worker = null;
        _deliver(g, w);
      }
    } else if (cooldownRemaining.value > 0) {
      cooldownRemaining.value = max(0.0, cooldownRemaining.value - dt);
    }
  }

  Widget _exchangeRow({double itemSize = 13}) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: badgeGap,
    children: [
      badgeIcon(Icons.swap_vert_circle, size: 12),
      for (final q in takes) quantityWidget(q, size: itemSize),
      badgeIcon(Icons.navigate_next, size: 12),
      for (final q in gives) quantityWidget(q, size: itemSize),
      if (duration > 0) badgeText('${fmtSec(duration)}s'),
    ],
  );

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(builder: (context) {
    final hasPending = pendingOutput.value.isNotEmpty;
    final working = workRemaining.value > 0;
    return explainTap(
      g,
      withPie(
        phaseBadgeRow(g, [
          if (level == NodeZoomLevel.small)
            badgeIcon(Icons.swap_vert_circle, size: 12)
          else
            _exchangeRow(itemSize: itemSizeFor(level)),
          if (hasPending) badgeIcon(Icons.outbox, size: 12),
        ]),
        pie: working
            ? CountdownPie(
                remaining: workRemaining,
                total: duration,
                isCooldown: false,
              )
            : CountdownPie(
                remaining: cooldownRemaining,
                total: cooldown,
                isCooldown: true,
              ),
      ),
    );
  });

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('trades '),
    ...quantitiesSpans(takes),
    tipText(' for '),
    ...quantitiesSpans(gives),
    if (duration > 0) tipText('; takes ${fmtSec(duration)}s'),
    if (cooldown > 0) tipText('; then rests ${fmtSec(cooldown)}s'),
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) => [
    SignalBuilder(builder: (context) {
      // subscriptions
      p.inventory.value;
      workRemaining.value;
      cooldownRemaining.value;
      final pending = pendingOutput.value;
      if (pending.isNotEmpty) {
        return actionChip(
          enabled: true,
          onTap: () => collect(g, p),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: badgeGap,
            children: [
              badgeIcon(Icons.outbox, size: 12),
              badgeText('collect'),
              for (final q in pending) quantityWidget(q),
            ],
          ),
        );
      }
      final chip = actionChip(
        enabled: canTrade(g, p),
        onTap: () => startTrade(g, p),
        child: _exchangeRow(),
      );
      // A chip that's gone dim doesn't say whether the trader is working, or
      // resting, or waiting on something the player hasn't got — and the pies
      // that do say it are out on the map badge, which isn't where a player
      // who has just tapped this is looking. So the chip carries the same pie
      // the badge does: sage while the trade runs, black and counting while
      // the trader rests afterwards. It sits outside the chip's dimming, since
      // its whole job is to be the part that's still alive.
      if (busy) {
        return withPie(
          chip,
          pie: CountdownPie(
            remaining: workRemaining,
            total: duration,
            isCooldown: false,
          ),
        );
      }
      if (cooling) {
        return withPie(
          chip,
          pie: CountdownPie(
            remaining: cooldownRemaining,
            total: cooldown,
            isCooldown: true,
          ),
        );
      }
      return chip;
    }),
  ];
}

class Mugger extends Facility {
  final Item item;
  final MuggerKind kind;

  /// flashes red when it strikes; subscribing to the clock only while it's
  /// flashing keeps idle muggers from rebuilding every frame
  final RedFlash flash = RedFlash();
  Mugger(this.item, this.kind);

  bool get _requires => kind != MuggerKind.c;
  bool get _takes => kind != MuggerKind.r;

  @override
  List<Item> get requiredItems => [item];

  @override
  void update(Game g, double dt) => flash.expire(g.gameTime);

  @override
  void onPlayerEntered(Game g, Player p) {
    if (!activeNow(g)) return;
    // muggers no longer freeze anyone: they clean you out
    if (_requires && !g.playerHas(p, [Quantity(item, 1)])) {
      flash.trigger(g.gameTime);
      if (p.inventory.peek().isNotEmpty) {
        p.inventory.value = const [];
        p.flash.trigger(g.gameTime);
      }
      g.announce('MUGGED');
      return;
    }
    // The toll: taken from anyone who has it, including the ones who were
    // never at risk of the robbery. It flashes like the robbery does — an item
    // leaving the inventory with no red anywhere is indistinguishable from a
    // bug, and this is the only way a player loses something without being
    // told about it.
    if (_takes && g.playerHas(p, [Quantity(item, 1)])) {
      g.takeItems(p, [Quantity(item, 1)]);
      flash.trigger(g.gameTime);
      p.flash.trigger(g.gameTime);
    }
  }

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(builder: (context) {
    var color = palette.ink;
    if (flash.active) {
      color = Color.lerp(
        palette.ink,
        Colors.red,
        flash.rednessAt(g.clock.value),
      )!;
    }
    return explainTap(
      g,
      phaseBadgeRow(g, [
        badgeIcon(Icons.savings, color: color),
        if (level != NodeZoomLevel.small) ...[
          badgeText(kind.name),
          ItemWidget(item, size: itemSizeFor(level)),
        ],
      ]),
    );
  });

  @override
  List<InlineSpan> describe(Game g) => switch (kind) {
    MuggerKind.c => [
      tipText('takes a '),
      itemSpan(item),
      tipText(' from passers-by who have one (harmless)'),
    ],
    MuggerKind.r => [
      tipText('demands to see a '),
      itemSpan(item),
      tipText(
        ' — anyone entering without one is robbed of everything they '
        'carry (it takes nothing from those who have one)',
      ),
    ],
    MuggerKind.rc => [
      tipText('demands and takes a '),
      itemSpan(item),
      tipText(
        ' — anyone entering without one is robbed of everything they carry',
      ),
    ],
  };
}

class Storage extends Facility {
  final int capacity; // 2..12, log-distributed
  /// secured storages are out of the blight's reach
  final bool secured;
  final Signal<List<Item>> contents = signal(const []);
  Storage(this.capacity, {this.secured = false});

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(builder: (context) {
    final c = contents.value;
    return explainTap(
      g,
      phaseBadgeRow(g, [
        badgeIcon(Icons.inventory_2),
        if (secured) badgeIcon(Icons.lock, size: 11),
        if (level == NodeZoomLevel.small || c.length > 3)
          badgeText('${c.length}/$capacity')
        else
          for (final it in c) ItemWidget(it, size: itemSizeFor(level)),
      ]),
    );
  });

  @override
  List<InlineSpan> describe(Game g) => [
    tipText(
      secured
          ? 'secured storage with $capacity slots; the blight cannot reach in'
          : 'storage with $capacity slots',
    ),
  ];

  /// The storage's control renders as its slots, like an inventory. It's
  /// loaded by clicking items in the inventory; clicking a stored item moves
  /// it on to the next storage here, or back to the inventory.
  @override
  List<Widget> actionsFor(Game g, Player p) => [
    SignalBuilder(builder: (context) {
      final stored = contents.value;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          badgeIcon(Icons.inventory_2),
          const SizedBox(width: 3),
          Flexible(
            child: Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [
                for (var i = 0; i < capacity; i++)
                  slotBox(
                    item: i < stored.length ? stored[i] : null,
                    onTap: i < stored.length
                        ? () => g.rotateItemOnward(p, this, stored[i])
                        : null,
                  ),
              ],
            ),
          ),
        ],
      );
    }),
  ];
}

/// A wide nocturnal wave that strips everything loose inside its radius —
/// items carried by players and anything sitting in unsecured storage. Plants
/// keep their fruit. Most blights can be bought off with a particular item;
/// hungry ones ('R') want another one every cycle.
class Blight extends Facility {
  final double radius;
  final ClockInterval interval; // one to three days, firing at night
  final Item? mitigator; // null when nothing placates it
  final bool hungry; // wants feeding again after every wave
  final Signal<bool> satiated = signal(false);

  @override
  List<Item> get requiredItems => [if (mitigator != null) mitigator!];

  @override
  bool get isHazard => true;

  final RedFlash flash = RedFlash();
  int _lastCycle = -1 << 30;
  Blight({
    required this.radius,
    required this.interval,
    required this.mitigator,
    required this.hungry,
  });

  @override
  ClockInterval? get clockSchedule => interval;

  /// once a non-hungry blight has been fed it's done, so it stops counting
  bool get dormant => satiated.value && !hungry;

  final Signal<double> remaining = signal(0.0);

  @override
  void update(Game g, double dt) {
    flash.expire(g.gameTime);
    final cycle = interval.cycleAt(g.gameTime);
    if (_lastCycle == -1 << 30) _lastCycle = cycle;
    if (cycle > _lastCycle) {
      _lastCycle = cycle;
      _fire(g);
    }
    remaining.value = dormant ? 0 : interval.remainingAt(g.gameTime);
  }

  void _fire(Game g) {
    if (satiated.value) {
      // a hungry blight is only bought off for the one cycle
      if (hungry) satiated.value = false;
      return;
    }
    flash.trigger(g.gameTime);
    bool within(Offset o) => (o - node.pos).distance <= radius;
    var struck = false;
    for (final p in g.players) {
      if (!within(p.worldPos())) continue;
      p.inventory.value = const [];
      p.flash.trigger(g.gameTime);
      struck = true;
    }
    for (final n in g.nodes) {
      if (!within(n.pos)) continue;
      for (final s in n.facilities.whereType<Storage>()) {
        if (!s.secured) s.contents.value = const [];
      }
    }
    if (struck) g.announce('BLIGHTSTRUCK');
  }

  bool canFeed(Game g, Player p) =>
      mitigator != null &&
      !satiated.value &&
      g.playerHas(p, [Quantity(mitigator!, 1)]);

  void feed(Game g, Player p) {
    if (!canFeed(g, p)) return;
    g.takeItems(p, [Quantity(mitigator!, 1)]);
    satiated.value = true;
  }

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(builder: (context) {
    var color = palette.ink;
    if (flash.active) {
      color = Color.lerp(
        palette.ink,
        Colors.red,
        flash.rednessAt(g.clock.value),
      )!;
    }
    final fed = satiated.value;
    return explainTap(
      g,
      withPie(
        phaseBadgeRow(g, [
          badgeIcon(Icons.dangerous, color: color),
          if (level != NodeZoomLevel.small) ...[
            if (hungry) badgeText('R'),
            if (mitigator != null)
              Opacity(
                opacity: fed ? 0.4 : 1,
                child: ItemWidget(mitigator!, size: itemSizeFor(level)),
              ),
          ],
        ]),
        // a placated blight that wants nothing more stops counting down
        pie: dormant
            ? const SizedBox.shrink()
            : CountdownPie(
                remaining: remaining,
                total: interval.period,
                isCooldown: true,
                clock: interval,
              ),
      ),
    );
  });

  @override
  List<InlineSpan> describe(Game g) => [
    tipText(
      'a blight — ${describeClock(interval)} it strips every loose item '
      'within ${fmt1(radius)} units, from players and unsecured storage '
      'alike',
    ),
    if (mitigator != null) ...[
      tipText('; give it '),
      itemSpan(mitigator!),
      tipText(hungry ? ' each cycle to hold it off' : ' to end it for good'),
    ],
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) {
    if (mitigator == null) return const [];
    return [
      SignalBuilder(builder: (context) {
        p.inventory.value;
        final fed = satiated.value;
        return actionChip(
          enabled: !fed && canFeed(g, p),
          onTap: () => feed(g, p),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: badgeGap,
            children: [
              badgeIcon(Icons.dangerous, size: 12),
              badgeText(fed ? 'sated' : 'appease'),
              ItemWidget(mitigator!, size: 13),
            ],
          ),
        );
      }),
    ];
  }
}

// ────────────────────────────── game ──────────────────────────────

class Game {
  final Parameters params;
  final ItemCatalog catalog;
  final List<Node> nodes; // includes TrainNodes
  final List<Edge> edges;
  final List<Player> players;
  final List<TrainNode> trains;

  double gameTime = 0; // the pausable clock; ALL timers tick on this
  /// gameTime mirrored as a signal, for the few things that animate off it
  /// reactively (the mugger pulse); most rendering rides the frame notifier
  final Signal<double> clock = signal(0.0);
  final Signal<double> timeLeft;
  final Signal<int> eudaimonia = signal(0);
  final Signal<bool> paused = signal(false);
  late final Signal<Player> selectedPlayer;
  final Signal<GamePhase> phase = signal(GamePhase.playing);

  /// Day occupies the first half of each day, night the second — night turns
  /// to day halfway through. Everything that renders reads this.
  final Signal<bool> isNight = signal(false);

  /// How far the view is allowed to zoom, in logical pixels per world unit.
  /// They depend on the viewport, so the map view writes them every layout;
  /// they live here rather than there because the zoom range is what the
  /// overgraph fade is measured against, and that's read from elsewhere too.
  /// Placeholders until the first layout.
  double zoomMin = 1, zoomMax = 1;

  /// the big transient caps message: NIGHT HAS FALLEN, MUGGED, BLIGHTSTRUCK…
  final Signal<(String text, double at)?> announcement = signal(null);

  /// every blight in the level, for painting their radii
  late final List<Blight> blights;

  double get timeOfDay => gameTime % params.dayLength;
  int get daysRemaining => (timeLeft.value / params.dayLength).floor();

  void announce(String text) => announcement.value = (text, gameTime);

  /// the current explanation tooltip: the facility (or train) that was tapped,
  /// which node it's anchored to, and its spans
  final Signal<(Object source, Node at, List<InlineSpan> spans)?> tooltip =
      signal(null);

  /// tapping the facility whose tooltip is showing closes it again
  void toggleTooltip(
    Object source,
    Node at,
    List<InlineSpan> Function() spans,
  ) {
    raiseNode(at);
    final cur = tooltip.value;
    tooltip.value = cur != null && identical(cur.$1, source)
        ? null
        : (source, at, spans());
  }

  int _stackTop = 0;

  /// Lifts a node's overlay above every other node's, and leaves it there: a
  /// node the player has just touched or walked into is a node whose badges
  /// they want to keep reading, and dropping it back under its neighbours the
  /// moment the tooltip closes or the player leaves would undo that mid-glance.
  void raiseNode(Node n) => n.stackRank = ++_stackTop;

  Game({
    required this.params,
    required this.catalog,
    required this.nodes,
    required this.edges,
    required this.players,
    required this.trains,
  }) : timeLeft = signal(params.globalTime) {
    selectedPlayer = signal(players.first);
    blights = [for (final n in nodes) ...n.facilities.whereType<Blight>()];
  }

  void update(double dt) {
    if (paused.value || phase.value != GamePhase.playing) return;
    gameTime += dt;
    clock.value = gameTime;
    timeLeft.value = max(0.0, timeLeft.value - dt);

    final night = timeOfDay >= params.dayLength / 2;
    if (night != isNight.value) {
      isNight.value = night;
      announce(night ? 'NIGHT HAS FALLEN' : 'DAY HAS RISEN');
    }
    final ann = announcement.value;
    if (ann != null && gameTime - ann.$2 > announcementTime) {
      announcement.value = null;
    }

    for (final p in players) {
      p.update(this, dt);
    }
    for (final t in trains) {
      t.updateTrain(this, dt);
    }
    for (final n in nodes) {
      for (final f in n.facilities) {
        f.update(this, dt);
      }
    }
    if (eudaimonia.value >= params.eudaimoniaGoal) {
      phase.value = GamePhase.won;
    } else if (timeLeft.value <= 0) {
      phase.value = GamePhase.lost;
    }
  }

  // ── inventory helpers (eudaimonia never occupies inventory: it converts
  // straight into score the moment it's received) ──

  bool playerHas(Player p, List<Quantity> qs) {
    for (final q in mergeQuantities(qs)) {
      if (p.inventory.value.where((it) => identical(it, q.item)).length < q.n) {
        return false;
      }
    }
    return true;
  }

  bool roomFor(Player p, List<Quantity> qs) {
    final n = qs.where((q) => !q.item.isEudaimonia).fold(0, (a, q) => a + q.n);
    return p.inventory.value.length + n <= params.inventoryCap;
  }

  void takeItems(Player p, List<Quantity> qs) {
    final inv = [...p.inventory.value];
    for (final q in qs) {
      for (var i = 0; i < q.n; i++) {
        inv.remove(q.item);
      }
    }
    p.inventory.value = inv;
  }

  /// gives as much as fits; returns the leftovers that didn't
  List<Quantity> giveItems(Player p, List<Quantity> qs) {
    var room = params.inventoryCap - p.inventory.value.length;
    final inv = [...p.inventory.value];
    final leftovers = <Quantity>[];
    for (final q in qs) {
      if (q.item.isEudaimonia) {
        eudaimonia.value += q.n;
        continue;
      }
      final give = min(q.n, room);
      room -= give;
      for (var i = 0; i < give; i++) {
        inv.add(q.item);
      }
      if (give < q.n) leftovers.add(Quantity(q.item, q.n - give));
    }
    p.inventory.value = inv;
    return leftovers;
  }

  // ── storage flows ──

  /// clicking an inventory item while storages are present loads it into the
  /// first storage with space. A storage that's out of hours isn't one of
  /// them: an out-of-hours facility does nothing at all, and this is a way
  /// into a storage that doesn't go through its own controls.
  void storeFromInventory(Player p, Item it) {
    final node = p.at.value;
    if (node == null) return;
    for (final s in node.facilities.whereType<Storage>()) {
      if (!s.activeNow(this)) continue;
      if (s.contents.value.length < s.capacity) {
        final inv = [...p.inventory.value];
        if (!inv.remove(it)) return;
        p.inventory.value = inv;
        s.contents.value = [...s.contents.value, it];
        return;
      }
    }
  }

  /// clicking a stored item rotates it on: to the next storage at the node
  /// with space, wrapping around to the player's inventory
  void rotateItemOnward(Player p, Storage from, Item it) {
    final node = from.node;
    final storages = node.facilities.whereType<Storage>().toList();
    final start = storages.indexOf(from);
    for (var k = start + 1; k < storages.length; k++) {
      if (!storages[k].activeNow(this)) continue;
      if (storages[k].contents.value.length < storages[k].capacity) {
        final c = [...from.contents.value];
        if (!c.remove(it)) return;
        from.contents.value = c;
        storages[k].contents.value = [...storages[k].contents.value, it];
        return;
      }
    }
    if (identical(p.at.value, node) &&
        p.inventory.value.length < params.inventoryCap) {
      final c = [...from.contents.value];
      if (!c.remove(it)) return;
      from.contents.value = c;
      p.inventory.value = [...p.inventory.value, it];
    }
  }

  // ── move scheduling ──

  /// Resolve a move-pad drag for [p]: pick the edge minimizing angle distance
  /// to the drag; if the minimum exceeds pi/2, don't move. Scheduling ahead is
  /// disabled for now — one move ongoing at a time, and none while the
  /// character is disabled.
  void schedulePlayerMove(Player p, double dragAngle) {
    if (!params.playersHaveMoveAction) return;
    if (p.incapacitatedFor.value > 0) return;
    if (p.traversing != null || p.plan.nodes.isNotEmpty) return;
    final source = p.at.value;
    if (source == null) return;
    Edge? best;
    var bestDist = double.infinity;
    for (final e in source.edges) {
      final d = shortestAngleDistance(dragAngle, e.angleFromNode(source)).abs();
      if (d < bestDist) {
        bestDist = d;
        best = e;
      }
    }
    if (best == null || bestDist > pi / 2) return;
    p.plan.nodes.add(best.other(source));
    p.plan.departureTimes.add(gameTime); // depart as soon as free
  }

  /// Same drag mechanic for a train, targeting its shortcut wires.
  void manualTrainMove(TrainNode train, Player by, double dragAngle) {
    final from = train.dockedAt.value;
    if (from == null || !train.manualAllowed || train.dockEdgeBusy(this)) {
      return;
    }
    Node? best;
    var bestDist = double.infinity;
    for (final s in train.stationNodes) {
      if (identical(s, from)) continue;
      final ang = offsetAngle(train.terminusFor[s]! - train.terminusFor[from]!);
      final d = shortestAngleDistance(dragAngle, ang).abs();
      if (d < bestDist) {
        bestDist = d;
        best = s;
      }
    }
    if (best == null || bestDist > pi / 2) return;
    final act = train.activation;
    if (act != null) {
      if (!playerHas(by, [act])) return;
      if (train.activationConsumed) takeItems(by, [act]);
    }
    train.departTo(this, best);
  }
}

// ────────────────────────────── level generation ──────────────────────────────

/// All randomness flows through one GameRng in a fixed order, so a seed fully
/// determines the level on every platform.
Game generateLevel(Parameters p) {
  final rng = GameRng(p.seed);
  final nodes = <Node>[];
  final edges = <Edge>[];

  Edge addEdge(Node a, Node b) {
    final e = Edge(a, b);
    a.edges.add(e);
    b.edges.add(e);
    edges.add(e);
    return e;
  }

  void removeEdge(Edge e) {
    e.a.edges.remove(e);
    e.b.edges.remove(e);
    edges.remove(e);
  }

  void removeNode(Node n) {
    for (final e in List.of(n.edges)) {
      removeEdge(e);
    }
    nodes.remove(n);
  }

  // 1 ── grid
  final n = p.gridSizeN;
  final grid = List.generate(
    n,
    (r) => List<Node?>.generate(n, (c) {
      final node = Node(Offset(c * p.gridSpacing, r * p.gridSpacing))
        ..gridRow = r
        ..gridCol = c;
      nodes.add(node);
      return node;
    }),
  );
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) addEdge(grid[r][c]!, grid[r][c + 1]!);
      if (r + 1 < n) addEdge(grid[r][c]!, grid[r + 1][c]!);
    }
  }

  // 2 ── distortions: push the two sides of a line apart
  final distortions =
      (n *
              (p.gridSizeDistortionCountStartp +
                  rng.nextDouble() * p.gridSizeDistortionCountVariancep))
          .ceil();
  for (var i = 0; i < distortions; i++) {
    final vertical = rng.chance(0.5); // vertical split line = push in x
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final node in nodes) {
      final v = vertical ? node.pos.dx : node.pos.dy;
      lo = min(lo, v);
      hi = max(hi, v);
    }
    final split = rangeIn(rng, lo, hi);
    final d = rng.nextDouble() * p.gridSizeDistortionp;
    for (final node in nodes) {
      final v = vertical ? node.pos.dx : node.pos.dy;
      final shift = v > split ? d / 2 : -d / 2;
      node.pos = vertical
          ? node.pos.translate(shift, 0)
          : node.pos.translate(0, shift);
    }
  }

  // 3 ── recenter on (0,0)
  var bounds = _boundsOf(nodes);
  final center = bounds.center;
  for (final node in nodes) {
    node.pos -= center;
  }

  // 4 ── line/column removal, transactional with connectivity retries
  bool wouldStayConnected(Set<Node> without) {
    final remaining = nodes.where((x) => !without.contains(x)).toList();
    if (remaining.isEmpty) return false;
    final seen = <Node>{remaining.first};
    final queue = [remaining.first];
    while (queue.isNotEmpty) {
      final x = queue.removeLast();
      for (final e in x.edges) {
        final o = e.other(x);
        if (!without.contains(o) && seen.add(o)) queue.add(o);
      }
    }
    return seen.length == remaining.length;
  }

  final lines = <List<Node?>>[
    for (var r = 0; r < n; r++) grid[r],
    for (var c = 0; c < n; c++) [for (var r = 0; r < n; r++) grid[r][c]],
  ];
  for (final line in lines) {
    for (var attempt = 0; attempt < 8; attempt++) {
      if (rng.nextDouble() <= p.lineRemovalProb) break; // line untouched
      final toDelete = <Node>{
        for (final node in line)
          if (node != null &&
              nodes.contains(node) &&
              rng.nextDouble() > p.pointRemovalProb)
            node,
      };
      if (toDelete.isEmpty) break;
      if (wouldStayConnected(toDelete)) {
        for (final node in toDelete) {
          removeNode(node);
          grid[node.gridRow][node.gridCol] = null;
        }
        break;
      }
      // else: rolled a disconnecting removal — retry the transaction
    }
  }

  // 5 ── split long edges with middle nodes
  for (final e in List.of(edges)) {
    final len = e.length;
    if (len <= 3) continue;
    if (rng.nextDouble() <= p.middleNodeProb) continue;
    final span = max(0.0, len - p.splitNodeMinDistance * 2);
    final d = len / 2 + rng.nextDouble() * span - span / 2;
    final mid = Node(Offset.lerp(e.a.pos, e.b.pos, d / len)!);
    final a = e.a, b = e.b;
    removeEdge(e);
    nodes.add(mid);
    addEdge(a, mid);
    addEdge(mid, b);
  }

  // 6 ── item catalog (needed below for train activation items; composite
  // icons are still assigned late, after traders exist)
  final catalog = ItemCatalog.generate(rng, p);

  // 7 ── trains & stations, before facility strewing
  final trains = <TrainNode>[];
  final stationsTaken = <Node>{};
  for (var i = 0; i < p.nTrains; i++) {
    final stationNodes = <Node>[];
    for (var s = 0; s < p.stationsPerTrain; s++) {
      Node? cand;
      for (var tries = 0; tries < 60; tries++) {
        final x = nodes[rng.nextInt(nodes.length)];
        if (x is TrainNode || stationsTaken.contains(x)) continue;
        final farEnough = stationNodes.every(
          (y) => (y.pos - x.pos).distance >= p.gridSpacing * 2,
        );
        if (farEnough || tries > 40) {
          cand = x;
          break;
        }
      }
      if (cand == null) break;
      stationsTaken.add(cand);
      stationNodes.add(cand);
    }
    if (stationNodes.length < 2) continue;

    final terminusFor = <Node, Offset>{
      for (final s in stationNodes)
        s:
            s.pos +
            angleToOffset(_openestAngle(rng, s)) * p.trainTerminusDistance,
    };
    final speed = weightedPick(rng, p.trainSpeedWeights);
    final scheduleKind = weightedPick(rng, p.scheduleDistribution);
    final schedule = switch (scheduleKind) {
      TrainScheduleKind.never => const NeverSchedule(),
      TrainScheduleKind.oneWay => const OneWaySchedule(),
      // cycle trains run on a division clock interval: so many trips a day,
      // always at the same times
      TrainScheduleKind.cycle => CycleSchedule(
        _divisionInterval(
          rng,
          p.dayLength,
          p.trainCycleDivisions[rng.nextInt(p.trainCycleDivisions.length)],
        ),
      ),
    };
    Quantity? activation;
    var activationConsumed = false;
    if (rng.chance(p.trainActivationProb)) {
      activationConsumed = rng.chance(p.trainActivationConsumedProb);
      // a pretty basic item, unless it's a fast or very fast train, in which
      // case it may be a medium one
      final fast = speed == TrainSpeed.f || speed == TrainSpeed.i;
      final tier = weightedPick(rng, [(0.6, 0), (0.3, 1), if (fast) (0.5, 2)]);
      activation = Quantity(
        _pick(rng, catalog.tiers[tier]),
        rng.chance(p.trainActivationTwoProb) ? 2 : 1,
      );
    }
    final manual = schedule is NeverSchedule || schedule is OneWaySchedule;
    final train = TrainNode(
      pos: terminusFor[stationNodes.first]!,
      speed: speed,
      activation: activation,
      activationConsumed: activationConsumed,
      movableFromInside: manual && rng.chance(p.movableFromInsideProb),
      schedule: schedule,
      stationNodes: stationNodes,
      terminusFor: terminusFor,
    );
    trains.add(train);
    nodes.add(train);
    for (final s in stationNodes) {
      final st = Station(train, weightedPick(rng, p.stationControlWeights));
      st.node = s;
      s.facilities.add(st);
    }
  }

  // 8 ── traders (directed hyperedges over the tiers), then composite icons
  final traders = generateTraders(rng, p, catalog);
  assignCompositeIcons(rng, p, catalog, traders);

  // 9 ── buckets: one per node, sizes apportioned to bucketSizeWeights
  final sizeCounts = apportionCounts(p.bucketSizeWeights, nodes.length);
  final bucketSizes = <int>[
    for (var size = 0; size < sizeCounts.length; size++)
      for (var k = 0; k < sizeCounts[size]; k++) size,
  ];
  shuffleInPlace(rng, bucketSizes);
  var totalSlots = bucketSizes.fold(0, (a, b) => a + b);
  while (totalSlots < traders.length) {
    bucketSizes[rng.nextInt(bucketSizes.length)] += 1;
    totalSlots += 1;
  }

  final kinds = [
    FacilityKind.tree,
    FacilityKind.storage,
    FacilityKind.mugger,
    FacilityKind.blight,
  ];
  final kindCounts = apportionCounts([
    for (final k in kinds) p.nonTraderWeights[k] ?? 0,
  ], totalSlots - traders.length);
  final pool = <Facility>[...traders];
  for (var ki = 0; ki < kinds.length; ki++) {
    for (var c = 0; c < kindCounts[ki]; c++) {
      pool.add(switch (kinds[ki]) {
        FacilityKind.tree => _generateTree(rng, p, catalog),
        FacilityKind.storage => Storage(
          logUniformInt(
            rng,
            p.storageCapacityRange.$1,
            p.storageCapacityRange.$2,
          ),
          secured: rng.chance(p.storageSecurep),
        ),
        FacilityKind.blight => _generateBlight(rng, p, catalog),
        _ => _generateMugger(rng, p, catalog),
      });
    }
  }
  // day/night restriction: muggers work the night, everything else that keeps
  // hours keeps day hours. Blights are nocturnal by nature, so they're exempt.
  for (final f in pool) {
    f.activePhase = switch (f) {
      Mugger _ =>
        rng.chance(p.muggerNightOnlyp)
            ? ActivePhase.nightOnly
            : ActivePhase.always,
      Blight _ => ActivePhase.always,
      _ =>
        rng.chance(p.facilityDayOnlyp)
            ? ActivePhase.dayOnly
            : ActivePhase.always,
    };
  }
  shuffleInPlace(rng, pool);
  var k = 0;
  for (var i = 0; i < nodes.length; i++) {
    for (var j = 0; j < bucketSizes[i] && k < pool.length; j++) {
      final f = pool[k++];
      f.node = nodes[i];
      nodes[i].facilities.add(f);
    }
  }

  // 9b ── node tone: with the facilities in place, every node draws its
  // colouring. A tinted node stains itself with one of the colours its own
  // facilities demand, so the map says a little about what's on it before
  // anything is tapped — which means a node whose facilities demand nothing
  // coloured has no business being tinted, and draws from the other two tones
  // instead. (Staining it with an unrelated item colour was the other way, and
  // it made the tint a lie.)
  for (final n in nodes) {
    final wanted = [
      for (final it in n.requiredItems)
        if (hasHue(iconDominantColor(it.icon))) iconDominantColor(it.icon),
    ];
    n.tone = weightedPick(rng, [
      for (final (w, t) in p.nodeToneWeights)
        if (t != NodeTone.tinted || wanted.isNotEmpty) (w, t),
    ]);
    if (n.tone == NodeTone.tinted) {
      n.tint = wanted[rng.nextInt(wanted.length)];
    }
  }

  // 10 ── players on one shared start node (no muggers, not a train)
  final startCandidates = nodes
      .where((x) => x is! TrainNode && !x.facilities.any((f) => f is Mugger))
      .toList();
  final start = startCandidates.isEmpty
      ? nodes.first
      : startCandidates[rng.nextInt(startCandidates.length)];
  final players = <Player>[];
  for (var i = 0; i < p.nPlayers.clamp(1, playerNames.length); i++) {
    final hue = (i * 137.5 + 40) % 360;
    final color = HSLuvColor.fromHSL(hue, 70, 55).toColor();
    final player = Player(playerNames[i], color);
    player.at.value = start;
    players.add(player);
  }
  start.playersPresent.value = List.of(players);

  final game = Game(
    params: p,
    catalog: catalog,
    nodes: nodes,
    edges: edges,
    players: players,
    trains: trains,
  );
  // the players start out standing on it, and nobody _arrive()d to say so
  game.raiseNode(start);
  for (final t in trains) {
    t.dock(game, t.homeStation);
  }
  return game;
}

Rect _boundsOf(List<Node> nodes) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final n in nodes) {
    minX = min(minX, n.pos.dx);
    minY = min(minY, n.pos.dy);
    maxX = max(maxX, n.pos.dx);
    maxY = max(maxY, n.pos.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// the direction from [node] whose angle distance from its edges is maximized
double _openestAngle(GameRng rng, Node node) {
  final angles = [for (final e in node.edges) e.angleFromNode(node)]..sort();
  if (angles.isEmpty) return rangeIn(rng, 0, 2 * pi);
  if (angles.length == 1) return angles[0] + pi;
  var bestMid = 0.0, bestGap = -1.0;
  for (var i = 0; i < angles.length; i++) {
    final a = angles[i];
    final b = i + 1 < angles.length ? angles[i + 1] : angles[0] + 2 * pi;
    if (b - a > bestGap) {
      bestGap = b - a;
      bestMid = (a + b) / 2;
    }
  }
  return bestMid;
}

Tree _generateTree(GameRng rng, Parameters p, ItemCatalog cat) {
  Quantity one() =>
      Quantity(_pick(rng, cat.tiers[rng.chance(p.treeTier1Prob) ? 1 : 0]), 1);
  final produces = mergeQuantities([
    one(),
    if (rng.chance(p.treeSecondItemProb)) one(),
  ]);
  // clock-regen trees come back once a day, at their own time of day —
  // several regrowths a day was more schedule than the player could hold
  final regen = rng.chance(p.treeClockIntervalp)
      ? ClockInterval(
          dayLength: p.dayLength,
          offset: rng.nextDouble() * p.dayLength,
        )
      : ArbitraryInterval(p.treeRegenTime);
  return Tree(produces, regen);
}

Mugger _generateMugger(GameRng rng, Parameters p, ItemCatalog cat) {
  final item = _pick(rng, cat.tiers[rng.chance(0.5) ? 0 : 1]);
  return Mugger(item, weightedPick(rng, p.muggerKindWeights));
}

Blight _generateBlight(GameRng rng, Parameters p, ItemCatalog cat) {
  final mitigable = rng.chance(p.blightMitigablep);
  // the item it wants is uniformly random across the whole catalogue
  final all = [for (final tier in cat.tiers) ...tier];
  final days =
      p.blightDaysRange.$1 +
      rng.nextInt(p.blightDaysRange.$2 - p.blightDaysRange.$1 + 1);
  return Blight(
    radius: p.blightRadii[rng.nextInt(p.blightRadii.length)],
    // it always comes at night, so its offset lands in the day's second half
    interval: ClockInterval(
      dayLength: p.dayLength,
      multiple: days,
      offset: rangeIn(rng, p.dayLength / 2, p.dayLength),
    ),
    mitigator: mitigable ? all[rng.nextInt(all.length)] : null,
    hungry: mitigable && rng.chance(p.blightHungryp),
  );
}

// ────────────────────────────── shared render bits ──────────────────────────────

String describeClock(ClockInterval c) => c.isDaily
    ? (c.multiple == 1
          ? 'daily at ${fmtTimeOfDay(c.timeOfDay, c.dayLength)}'
          : 'every ${c.multiple} days at '
                '${fmtTimeOfDay(c.timeOfDay, c.dayLength)}')
    : '${c.division} times a day, from '
          '${fmtTimeOfDay(c.timeOfDay, c.dayLength)}';

/// The day/night markers. Material's light_mode/dark_mode carry too much
/// interior detail to survive being drawn at eight logical pixels, so we draw
/// our own: shapes that stay readable when they're barely bigger than the text
/// beside them.
///
/// The sun is an eight-pointed star with a round hole punched out of it, so
/// what reads at small sizes is the ring of spikes rather than a blob.
class _SunPainter extends CustomPainter {
  final Color color;
  const _SunPainter(this.color);

  /// how far the star's valleys and its hole sit out from the centre, as
  /// fractions of the point radius. The hole is inside the valleys, leaving a
  /// thin band of solid ring holding the points together.
  static const _valley = 0.7;
  static const _hole = 0.33;

  @override
  void paint(Canvas canvas, Size size) {
    final r = min(size.width, size.height) / 2;
    final c = Offset(size.width / 2, size.height / 2);
    final star = Path();
    // sixteen vertices, alternating point and valley, starting at twelve
    // o'clock so the star sits square rather than tilted
    for (var i = 0; i < 16; i++) {
      final a = -pi / 2 + i * pi / 8;
      final rad = r * (i.isEven ? 1 : _valley);
      final p = c + Offset(cos(a) * rad, sin(a) * rad);
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    star.addOval(Rect.fromCircle(center: c, radius: r * _hole));
    star.fillType = PathFillType.evenOdd;
    canvas.drawPath(star, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.color != color;
}

/// The moon is a crescent: an inscribed disc with a second, smaller disc bitten
/// out of it from the up-right. Leaner than Material's dark_mode — that one's
/// bite is shallow enough that the result still reads as a disc at this size,
/// whereas thinning it to a proper sickle keeps it distinct from the pies and
/// dots it shares a row with. The horns very nearly reach the top and right
/// edges, so the shape still fills its box despite hugging the lower-left.
class _MoonPainter extends CustomPainter {
  final Color color;
  const _MoonPainter(this.color);

  /// the biting disc, as a fraction of the outer radius, and how far its centre
  /// sits up-right of the outer centre. The crescent's thickest point measures
  /// (1 - _innerR + _innerOff) outer radii, so these two together are the dial
  /// between "gibbous" and "hairline".
  static const _innerR = 0.66;
  static const _innerOff = 0.37;

  @override
  void paint(Canvas canvas, Size size) {
    final r = min(size.width, size.height) / 2;
    final c = Offset(size.width / 2, size.height / 2);
    final ri = r * _innerR;
    final d = r * _innerOff;
    const bite = -pi / 4; // up-right, the direction the bite comes from
    final ci = c + Offset(cos(bite), sin(bite)) * d;

    // Where the two circles cross, measured along the bite axis from each
    // centre: `a` from c, and a - d from ci. Half-angles subtended there give
    // the two arcs' extents.
    final a = (d * d + r * r - ri * ri) / (2 * d);
    final alpha = acos(a / r);
    final beta = acos((a - d) / ri);

    // the outer arc is everything the bite didn't take, swept away from the
    // bite; the inner arc then walks back along the bite's edge to the start
    canvas.drawPath(
      Path()
        ..arcTo(
          Rect.fromCircle(center: c, radius: r),
          bite + alpha,
          2 * pi - 2 * alpha,
          true,
        )
        ..arcTo(
          Rect.fromCircle(center: ci, radius: ri),
          bite - beta,
          -(2 * pi - 2 * beta),
          false,
        )
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_MoonPainter old) => old.color != color;
}

/// A day or night marker at [size], for wherever the game needs to say which
/// half of the day something belongs to.
Widget phaseIcon(bool night, {required double size, required Color color}) =>
    CustomPaint(
      size: Size.square(size),
      painter: night ? _MoonPainter(color) : _SunPainter(color),
    );

Widget badgeText(String s) => Text(
  s,
  style: TextStyle(
    fontSize: 10,
    color: palette.ink,
    fontWeight: FontWeight.w500,
  ),
);

Widget badgeIcon(IconData icon, {Color? color, double size = 13}) =>
    Icon(icon, size: size, color: color ?? palette.ink);

/// The gap between marks standing in a row — icons, item icons, text runs.
/// Sequences of items are only legible if it's clear where one ends and the
/// next begins, so nothing in a badge or a chip ever butts up against its
/// neighbour: everything laying icons out in a row uses this.
const badgeGap = 4.0;

/// item icon; quantities > 1 show the number at the bottom right corner, bold
Widget quantityWidget(Quantity q, {double size = 13}) {
  final item = ItemWidget(q.item, size: size);
  if (q.n <= 1) return item;
  return Stack(
    clipBehavior: Clip.none,
    children: [
      item,
      Positioned(
        // the count hangs just off the icon's corner; it stays inside the gap
        // to the next item so it never reads as part of that one
        right: -2,
        bottom: -3,
        child: Text(
          '${q.n}',
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.bold,
            color: palette.inkStrong,
            shadows: [
              Shadow(color: palette.ground, blurRadius: 2),
              Shadow(color: palette.ground, blurRadius: 3),
            ],
          ),
        ),
      ),
    ],
  );
}

/// How far an out-of-hours facility fades: its contents drop to this opacity.
/// The lozenge under them doesn't move — it's a node's colour, and a facility
/// keeping different hours doesn't put it on a different node. Mild enough to
/// still be read at a glance.
const dimFade = 0.55;

/// The compact lozenge that node facilities render into, filled with the
/// colour of the node it belongs to ([tone], defaulting to the graph's grey)
/// washed out to a tint — so a node's facilities look like they're part of
/// that node and not the one next to it. No outline: the fill is a light
/// enough touch that a border drawn round it was the loudest thing in the
/// node, and it was drawing a box around every icon on the map. [leading] is
/// the day or night marker, which sits in the row like any other icon but
/// never dims — [dim] fades the contents, and only the contents.
Widget badgeRow(
  List<Widget> children, {
  Widget? leading,
  bool dim = false,
  Color? tone,
}) {
  final fill = lozengeFill(tone ?? palette.node);
  Widget dimmed(Widget w) => dim ? Opacity(opacity: dimFade, child: w) : w;
  final Widget row;
  if (leading == null) {
    row = dimmed(
      Row(
        mainAxisSize: MainAxisSize.min,
        spacing: badgeGap,
        children: children,
      ),
    );
  } else {
    // The marker aligns to the top or bottom of the row, so the row is given a
    // definite height to align within.
    //
    // It also shares an unspaced row with the first icon rather than being an
    // item of the spaced row: the marker qualifies that icon, and at the size
    // it's drawn at, a badgeGap between the two is wide enough to read as the
    // marker belonging to nothing in particular. The gap resumes as normal
    // between that pair and the rest.
    row = IntrinsicHeight(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: badgeGap,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leading,
              for (final c in children.take(1)) Center(child: dimmed(c)),
            ],
          ),
          for (final c in children.skip(1)) Center(child: dimmed(c)),
        ],
      ),
    );
  }
  return Container(
    // the padding stands in for the 2px border that used to hold the contents
    // off the lozenge's edge, so dropping the outline didn't shrink anything
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(6),
    ),
    child: row,
  );
}

/// The pie sits on the top right corner of the whole thing it annotates —
/// always the same place, whatever the pie's label happens to be. The pie
/// itself is what's anchored there: [CountdownPie] lays its label out beyond
/// its own right edge without taking width for it, so a two-digit countdown
/// doesn't shove the pie inboard.
Widget withPie(Widget child, {required Widget pie}) => Stack(
  clipBehavior: Clip.none,
  children: [
    child,
    Positioned(right: -4, top: -4, child: pie),
  ],
);

/// The ubiquitous countdown pie. Progress (work) pies are sage; cooldowns are
/// black and labelled: with the clock time they're pinned to if they run on a
/// clock interval, and with the seconds remaining otherwise — one or the
/// other, never both. Both kinds shrink. Ticks on game time via its signal —
/// never wall clock — so pausing pauses pies.
class CountdownPie extends StatelessWidget {
  final Signal<double> remaining;
  final double total;
  final bool isCooldown;

  /// set when the countdown runs on a clock interval: its time of day is the
  /// more useful label, so it's shown in place of the seconds
  final ClockInterval? clock;
  final double size;
  const CountdownPie({
    super.key,
    required this.remaining,
    required this.total,
    required this.isCooldown,
    this.clock,
    this.size = 11,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final r = remaining.value;
      if (r <= 0 || total <= 0) return const SizedBox.shrink();
      final pie = CustomPaint(
        size: Size.square(size),
        painter: _PiePainter(
          fraction: clampUnit(r / total),
          color: isCooldown ? palette.inkStrong : sage,
        ),
      );
      if (!isCooldown) return pie;
      final label = clock != null
          ? fmtTimeOfDay(clock!.timeOfDay, clock!.dayLength)
          : '${r.ceil()}';
      // The label is positioned rather than laid out in a row: a Positioned
      // given only a left offset is left unconstrained, so the text hangs off
      // the pie's right without widening it, and the pie keeps the corner.
      return Stack(
        clipBehavior: Clip.none,
        children: [
          pie,
          Positioned(
            left: size + 1,
            top: size / 2 - 5,
            child: Text(
              label,
              style: TextStyle(fontSize: 8, color: palette.inkStrong),
            ),
          ),
        ],
      );
    });
  }
}

class _PiePainter extends CustomPainter {
  final double fraction;
  final Color color;
  _PiePainter({required this.fraction, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Anchored at twelve o'clock and swept the other way round, so the wedge's
    // free edge travels clockwise as it empties. No backing disc.
    canvas.drawArc(
      rect.deflate(0.5),
      -pi / 2,
      -fraction * 2 * pi,
      true,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.fraction != fraction || old.color != color;
}

Widget actionChip({
  required bool enabled,
  VoidCallback? onTap,
  required Widget child,
}) {
  return Opacity(
    opacity: enabled ? 1 : 0.35,
    child: GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.outline),
        ),
        child: child,
      ),
    ),
  );
}

/// an inventory-style item slot, used by the inventory row and storage controls
Widget slotBox({Item? item, VoidCallback? onTap, double dim = 26}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: dim,
      height: dim,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.outline),
      ),
      child: item != null
          ? Center(child: ItemWidget(item, size: dim * 0.7))
          : null,
    ),
  );
}

/// The move control: tap and drag in the direction of the wire you want.
/// Used for player moves and for scheduling trains from stations/inside.
class DragDirectionPad extends StatefulWidget {
  final void Function(double angle) onAngle;
  final bool enabled;
  final Widget? label; // centered
  final String? cornerText; // bottom right, e.g. 'drag to move'
  final double? dimension; // null = expand
  const DragDirectionPad({
    super.key,
    required this.onAngle,
    this.enabled = true,
    this.label,
    this.cornerText,
    this.dimension,
  });
  @override
  State<DragDirectionPad> createState() => _DragDirectionPadState();
}

class _DragDirectionPadState extends State<DragDirectionPad> {
  Offset _acc = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final threshold = Thumbspan.of(context) * 0.27;
    Widget pad = Container(
      decoration: BoxDecoration(
        color: palette.pad,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.outline),
      ),
      child: Stack(
        children: [
          Center(child: widget.label ?? const SizedBox.shrink()),
          if (widget.cornerText != null)
            Positioned(
              right: 5,
              bottom: 3,
              child: Text(
                widget.cornerText!,
                style: TextStyle(fontSize: 11, color: palette.inkFaint),
              ),
            ),
        ],
      ),
    );
    pad = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        _acc += details.delta;
        if (_acc.distance > threshold) {
          widget.onAngle(offsetAngle(_acc));
          _acc = Offset.zero;
        }
      },
      onPanEnd: (_) => _acc = Offset.zero,
      child: pad,
    );
    if (!widget.enabled) {
      pad = Opacity(opacity: 0.35, child: IgnorePointer(child: pad));
    }
    if (widget.dimension != null) {
      pad = SizedBox.square(dimension: widget.dimension, child: pad);
    }
    return pad;
  }
}

/// colored orb with the name over it inside a white container outlined in the
/// orb's color; renders at node-icon scale everywhere (it never zooms)
class PlayerOrb extends StatelessWidget {
  final Game game;
  final Player player;
  final double orbSize;
  final bool showName;
  final VoidCallback? onTap;
  const PlayerOrb(
    this.game,
    this.player, {
    super.key,
    this.orbSize = nodeIconSize * 1.4,
    this.showName = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SignalBuilder(builder: (context) {
        final selected = identical(game.selectedPlayer.value, player);
        // the name sits centered *over* the orb, not above it
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            withPie(
              Container(
                width: orbSize,
                height: orbSize,
                decoration: BoxDecoration(
                  color: player.color,
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: palette.ink, width: 2)
                      : null,
                ),
              ),
              pie: CountdownPie(
                remaining: player.incapacitatedFor,
                total: game.params.muggerIncapTime,
                isCooldown: true,
              ),
            ),
            if (showName)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: player.color,
                    width: selected ? 1.6 : 0.8,
                  ),
                ),
                child: Text(
                  player.name,
                  style: TextStyle(fontSize: 9, color: palette.ink),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// the train's own badge, shown in its node widget
Widget trainBadge(Game g, TrainNode t, NodeZoomLevel level) {
  return SignalBuilder(builder: (context) {
    final inTransit = t.dockedAt.value == null;
    Widget badge = badgeRow(tone: nodeColor(t), [
      badgeIcon(Icons.train),
      badgeText(t.speed.name),
      if (level != NodeZoomLevel.small) ...[
        if (t.activation != null)
          quantityWidget(t.activation!, size: itemSizeFor(level)),
        if (t.movableFromInside) badgeIcon(Icons.swipe_right_alt),
        if (t.schedule is OneWaySchedule) badgeText('sc(o)'),
        if (t.schedule case CycleSchedule c)
          badgeText('sc(${fmtSec(c.seconds)})'),
      ],
      if (inTransit) badgeText('${t.transitRemaining.value.ceil()}s'),
    ]);
    // cycle trains show a countdown pie to their next departure, plus the
    // clock time their interval is pinned to
    if (t.schedule case CycleSchedule c) {
      badge = withPie(
        badge,
        pie: CountdownPie(
          remaining: t.waitRemaining,
          total: c.interval.period,
          isCooldown: true,
          clock: c.interval,
        ),
      );
    }
    return GestureDetector(
      onTap: () => g.toggleTooltip(t, t, () => describeTrain(t)),
      child: badge,
    );
  });
}

List<InlineSpan> describeTrain(TrainNode t) {
  final speedName = switch (t.speed) {
    TrainSpeed.s => 'slow',
    TrainSpeed.r => 'regular',
    TrainSpeed.f => 'fast',
    TrainSpeed.i => 'very fast',
  };
  // a Never train has nothing to say about its schedule — it just sits there
  final schedule = switch (t.schedule) {
    NeverSchedule _ => null,
    OneWaySchedule _ => 'returns home on its own shortly after arriving',
    CycleSchedule c => 'shuttles on its own ${describeClock(c.interval)}',
  };
  return [
    tipText('a $speedName train${schedule == null ? '' : '; $schedule'}'),
    if (t.activation != null) ...[
      tipText('; moving it requires holding '),
      ...quantitySpans(t.activation!),
      if (t.activationConsumed) tipText(', which it takes'),
    ],
    if (t.movableFromInside) tipText('; can be moved from inside'),
  ];
}

// ────────────────────────────── screen ──────────────────────────────

class TrainscapeScreen extends StatefulWidget {
  /// generate this level rather than picking up the saved one. Passing a seed
  /// is asking for a particular map, which a save would only get in the way of
  final int? seed;
  const TrainscapeScreen({super.key, this.seed});
  @override
  State<TrainscapeScreen> createState() => _TrainscapeScreenState();
}

class _TrainscapeScreenState extends State<TrainscapeScreen>
    with SingleTickerProviderStateMixin {
  /// null until the saved level has been read back off disk, which is a
  /// database round trip. Everything below build's early return has a level
  Game? _game;
  Game get game => _game!;
  late int _seed;
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  Duration _last = Duration.zero;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  final ValueNotifier<int> _recenterNudge = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    // saving on the way out covers leaving the screen; backgrounding covers
    // the app being killed while it's down there, which is the usual way a
    // phone game ends
    _lifecycle = AppLifecycleListener(
      onPause: () {
        if (_game != null) saveLevel(game);
      },
    );
    _ticker = createTicker(_tick);
    _open();
  }

  /// The level the game was left in comes back, unless a particular map was
  /// asked for by seed. Reading it is a database round trip, so the screen
  /// spends a frame or two on the empty ground colour first — better than
  /// showing a freshly generated level and swapping it out from under them.
  Future<void> _open() async {
    final saved = widget.seed == null ? await loadSavedLevel() : null;
    if (!mounted) return;
    setState(() {
      _game = saved ?? generateLevel(Parameters.levelOne(widget.seed ?? 1));
      _seed = game.params.seed;
    });
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1 / 15);
    _last = elapsed;
    game.update(dt);
    _frame.value++;
  }

  @override
  void dispose() {
    if (_game != null) saveLevel(game);
    _lifecycle.dispose();
    _ticker.dispose();
    _frame.dispose();
    _recenterNudge.dispose();
    super.dispose();
  }

  void _newGame(int seed) {
    setState(() {
      _seed = seed;
      _game = generateLevel(Parameters.levelOne(_seed));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_game == null) return ColoredBox(color: palette.ground);
    return EscapeToPop(
      // Everything under here is built against [palette], so the flip has to
      // happen above it and rebuild the lot. It's a rebuild, not a
      // restructure: the tree keeps its shape, so the world view's state —
      // the player's zoom and pan — rides through the turn of the day.
      child: SignalBuilder(builder: (context) {
        palette = game.isNight.value ? nightPalette : dayPalette;
        return Scaffold(
          backgroundColor: palette.ground,
          body: SafeArea(
            child: Stack(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide =
                        constraints.maxWidth > constraints.maxHeight;
                    final world = Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: WorldView(
                              key: ObjectKey(game),
                              game: game,
                              frame: _frame,
                              recenterNudge: _recenterNudge,
                            ),
                          ),
                          Positioned(
                            left: 10,
                            right: 10,
                            top: 3,
                            child: _hud(),
                          ),
                          Positioned.fill(child: _announcement()),
                        ],
                      ),
                    );
                    final controls = isWide
                        ? SizedBox(
                            width: 340,
                            child: ControlsPanel(
                              game: game,
                              recenterNudge: _recenterNudge,
                            ),
                          )
                        : SizedBox(
                            height: 210,
                            child: ControlsPanel(
                              game: game,
                              recenterNudge: _recenterNudge,
                            ),
                          );
                    return isWide
                        ? Row(children: [world, controls])
                        : Column(children: [world, controls]);
                  },
                ),
                _phaseOverlay(),
              ],
            ),
          ),
        );
      }),
    );
  }

  /// the big transient caps message, centered over the world
  Widget _announcement() => SignalBuilder(builder: (context) {
    final a = game.announcement.value;
    if (a == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: Text(
          a.$1,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: 3,
            color: palette.ink,
            shadows: [
              Shadow(color: palette.ground, blurRadius: 8),
              Shadow(color: palette.ground, blurRadius: 14),
            ],
          ),
        ),
      ),
    );
  });

  Widget _hud() {
    return SignalBuilder(builder: (context) {
      final paused = game.paused.value;
      final night = game.isNight.value;
      // the timer, the day clock and the standing orders all read as one line
      // in the one voice; the wrap is screen-wide so they spill onto a second
      // line rather than overflowing on a narrow phone
      final hudStyle = TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: palette.ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      // the requirement counts what's still owed, so it falls as they earn it
      final owed = max(0, game.params.eudaimoniaGoal - game.eudaimonia.value);
      return SizedBox(
        width: double.infinity,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 2,
          children: [
            // bare tappable icons rather than IconButtons, whose own padding
            // made the spacing along this line uneven
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: Icon(Icons.arrow_back, size: 20, color: palette.ink),
            ),
            GestureDetector(
              onTap: () => game.paused.value = !paused,
              child: Icon(
                paused ? Icons.play_arrow : Icons.pause,
                size: 20,
                color: palette.ink,
              ),
            ),
            Text(fmtClock(game.timeLeft.value), style: hudStyle),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                phaseIcon(night, size: 16, color: palette.ink),
                const SizedBox(width: 3),
                Text(
                  fmtTimeOfDay(game.timeOfDay, game.params.dayLength),
                  style: hudStyle,
                ),
              ],
            ),
            Text(
              game.daysRemaining == 0
                  ? "FINAL DAY"
                  : game.daysRemaining == 1
                  ? "1 DAY REMAINS"
                  : "${game.daysRemaining} DAYS REMAIN",
              style: hudStyle,
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$owed '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: CustomPaint(
                      size: const Size.square(16),
                      painter: ItemIconPainter(const HeartIcon()),
                    ),
                  ),
                  const TextSpan(text: ' REQUIRED'),
                ],
              ),
              style: hudStyle,
            ),
          ],
        ),
      );
    });
  }

  Widget _phaseOverlay() {
    return SignalBuilder(builder: (context) {
      final phase = game.phase.value;
      if (phase == GamePhase.playing) return const SizedBox.shrink();
      final won = phase == GamePhase.won;
      return Positioned.fill(
        child: ColoredBox(
          color: palette.scrim,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (won)
                  CustomPaint(
                    size: const Size.square(48),
                    painter: ItemIconPainter(const HeartIcon()),
                  ),
                const SizedBox(height: 8),
                Text(
                  won ? 'Eudaimonia achieved' : 'Time has run out',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 16),
                // these are the only Material-styled things on the screen, and
                // the surrounding app's theme follows the device rather than
                // the time of day in here, so they're told what ink to use
                TextButtonTheme(
                  data: TextButtonThemeData(
                    style: TextButton.styleFrom(foregroundColor: palette.ink),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => _newGame(_seed),
                        child: const Text('Restart'),
                      ),
                      TextButton(
                        onPressed: () => _newGame(_seed + 1),
                        child: const Text('New map'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Exit'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

// ────────────────────────────── controls panel ──────────────────────────────

class ControlsPanel extends StatelessWidget {
  final Game game;
  final ValueNotifier<int> recenterNudge;
  const ControlsPanel({
    super.key,
    required this.game,
    required this.recenterNudge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.panel,
      padding: const EdgeInsets.all(6),
      child: SignalBuilder(builder: (context) {
        final sel = game.selectedPlayer.value;
        final atNode = sel.at.value;
        final actionWidgets = <Widget>[
          if (atNode != null) ...[
            // a facility that's out of hours offers nothing
            for (final f in atNode.facilities)
              if (f.activeNow(game)) ...f.actionsFor(game, sel),
            if (atNode is TrainNode && atNode.movableFromInside)
              _insideTrainPad(atNode, sel),
          ],
        ];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _inventoryRow(sel),
                  const SizedBox(height: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: actionWidgets,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (game.params.playersHaveMoveAction)
              SizedBox(
                width: 110,
                child: DragDirectionPad(
                  enabled: sel.incapacitatedFor.value <= 0,
                  onAngle: (a) => game.schedulePlayerMove(sel, a),
                  // the instruction at the bottom right, the move icon in the
                  // center
                  label: Icon(
                    Icons.swipe_right_alt,
                    color: palette.inkFaint,
                    size: 28,
                  ),
                  cornerText: 'drag to move',
                ),
              ),
            const SizedBox(width: 6),
            SizedBox(width: 64, child: _roster()),
          ],
        );
      }),
    );
  }

  Widget _insideTrainPad(TrainNode train, Player p) {
    return SignalBuilder(builder: (context) {
      final docked = train.dockedAt.value;
      final enabled =
          docked != null &&
          train.manualAllowed &&
          !train.dockEdgeBusy(game) &&
          (train.activation == null || game.playerHas(p, [train.activation!]));
      return DragDirectionPad(
        dimension: 64,
        enabled: enabled,
        onAngle: (a) => game.manualTrainMove(train, p, a),
        label: Column(
          mainAxisSize: MainAxisSize.min,
          children: [badgeIcon(Icons.train), badgeIcon(Icons.swipe_right_alt)],
        ),
      );
    });
  }

  Widget _inventoryRow(Player p) {
    return SignalBuilder(builder: (context) {
      final inv = p.inventory.value;
      final atNode = p.at.value;
      // clicking an inventory item while a storage is open loads it in
      final hasStorage =
          atNode != null &&
          atNode.facilities.any((f) => f is Storage && f.activeNow(game));
      // muggings and blights flash the inventory red three times
      final redness = p.flash.active
          ? p.flash.rednessAt(game.clock.value)
          : 0.0;
      final row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < game.params.inventoryCap; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            slotBox(
              item: i < inv.length ? inv[i] : null,
              onTap: hasStorage && i < inv.length
                  ? () => game.storeFromInventory(p, inv[i])
                  : null,
            ),
          ],
        ],
      );
      if (redness <= 0) return row;
      return Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.55 * redness),
          borderRadius: BorderRadius.circular(8),
        ),
        child: row,
      );
    });
  }

  Widget _roster() {
    return SignalBuilder(builder: (context) {
      return ListView(
        children: [
          for (final p in game.players)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: PlayerOrb(
                game,
                p,
                orbSize: 30,
                onTap: () {
                  game.selectedPlayer.value = p;
                  recenterNudge.value++;
                },
              ),
            ),
        ],
      );
    });
  }
}

// ────────────────────────────── world view ──────────────────────────────

class WorldView extends StatefulWidget {
  final Game game;
  final Listenable frame;
  final ValueNotifier<int> recenterNudge;
  const WorldView({
    super.key,
    required this.game,
    required this.frame,
    required this.recenterNudge,
  });
  @override
  State<WorldView> createState() => _WorldViewState();
}

class _WorldViewState extends State<WorldView> {
  /// The camera, in world units, following the selected player + the user's
  /// pan. Each axis eases with a pair of joined parabola segments — accelerate
  /// then decelerate, arriving in [camSeekSeconds] flat — and retargeting
  /// mid-flight picks the new pair up at the current position *and* velocity,
  /// so a target that moves again while the camera is still travelling doesn't
  /// jolt it. Wall time, not game time: the view keeps settling while paused.
  final _camX = TimelyParabolicSimulation.unset(duration: camSeekSeconds);
  final _camY = TimelyParabolicSimulation.unset(duration: camSeekSeconds);
  final Stopwatch _camClock = Stopwatch()..start();
  double _camSegStart = 0; // when the segments in flight began
  Offset? _camFollow; // the world point the segments in flight were aimed at

  /// Seeks the point the selected player is at (or heading for). Only a change
  /// in that point starts new segments; the user's pan doesn't go through here
  /// — see [_panCam].
  Offset _seekCam(Offset follow) {
    final now = _camClock.elapsedMicroseconds / 1e6;
    if (_camFollow != follow) {
      final t = now - _camSegStart;
      _camX.target(follow.dx + _userPan.dx, time: t);
      _camY.target(follow.dy + _userPan.dy, time: t);
      _camSegStart = now;
      _camFollow = follow;
    }
    final t = now - _camSegStart;
    return Offset(_camX.x(t), _camY.x(t));
  }

  /// A drag is the player's own hand on the camera, so it moves the
  /// destination rather than starting a fresh seek towards it: the segments in
  /// flight keep their shape and their timing, and the end they're aimed at
  /// slides along under the finger. A camera at rest has finished its
  /// segments, so this moves it with the drag one to one, which is what a drag
  /// should feel like; one still in flight takes up the shift in proportion to
  /// how far along it is, rather than lurching or re-easing from a standstill.
  void _panCam(Offset delta) {
    _userPan += delta;
    _camX.endValue += delta.dx;
    _camY.endValue += delta.dy;
  }

  Offset _userPan = Offset.zero;
  double? _zoom; // logical pixels per world unit
  double _zoomAtGestureStart = 1;
  double _defaultZoom = 1;

  /// whether we're zoomed out past farZoomThreshold → NodeZoomLevel.small.
  /// A signal so cached node widgets react without being rebuilt from here.
  final Signal<bool> farZoom = signal(false);
  final Map<Node, Widget> _contentCache = {};

  /// The world the moving layer covers, in world units, fixed for the life of
  /// the level. Fixed on purpose: it's the origin every node widget is placed
  /// from, so recomputing it as the trains wander would shift every node in
  /// the layer by whatever the bounds had changed by, and the [Animove]s would
  /// chase it. The margin is what keeps a node widget at the far edge — which
  /// is drawn at a fixed pixel size, not a world one — inside the layer's box,
  /// where taps still reach it.
  late final Rect _worldRect = _boundsOf(widget.game.nodes).inflate(10);

  /// One holder for the life of the view, not one per frame: it's what lets a
  /// frame dispose the picture the frame before it recorded.
  final GraphRecording _graphRecording = GraphRecording();

  @override
  void initState() {
    super.initState();
    widget.recenterNudge.addListener(_recenter);
  }

  @override
  void dispose() {
    widget.recenterNudge.removeListener(_recenter);
    _graphRecording.picture?.dispose();
    super.dispose();
  }

  /// Drops the user's pan and seeks the followed point again. The follow point
  /// itself hasn't moved, so [_seekCam] wouldn't notice on its own — clearing
  /// it is what asks for the new segments.
  void _recenter() {
    _userPan = Offset.zero;
    _camFollow = null;
  }

  void _updateFarZoom() {
    final far = _defaultZoom / _zoom! > widget.game.params.farZoomThreshold;
    if (farZoom.peek() != far) {
      // deferred: this can be reached during build (layout changes), and
      // notifying subscribers mid-build isn't allowed
      scheduleMicrotask(() {
        if (mounted) farZoom.value = far;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final viewShort = min(size.width, size.height);
        _defaultZoom = viewShort / 12;
        _zoom ??= _defaultZoom;
        game.zoomMin = viewShort / 40;
        game.zoomMax = viewShort / 5;
        _updateFarZoom();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => game.tooltip.value = null,
          onScaleStart: (d) => _zoomAtGestureStart = _zoom!,
          onScaleUpdate: (d) {
            // both gestures amplified 3x: pans move three times as far,
            // pinches zoom as scale cubed (about the view center for now)
            _panCam(-d.focalPointDelta * 3 / _zoom!);
            if (d.scale != 1) {
              _zoom = (_zoomAtGestureStart * pow(d.scale, 3))
                  .clamp(game.zoomMin, game.zoomMax)
                  .toDouble();
              _updateFarZoom();
            }
          },
          child: ClipRect(
            child: ListenableBuilder(
              listenable: widget.frame,
              builder: (context, _) {
                // the camera heads straight for the node the selected player is
                // moving to, rather than tracking them along the wire
                final sel = game.selectedPlayer.value;
                final cam = _seekCam(
                  sel.traversalTarget?.pos ?? sel.worldPos(),
                );
                final zoom = _zoom!;
                final viewCenter = size.center(Offset.zero);
                Offset project(Offset world) =>
                    (world - cam) * zoom + viewCenter;
                final cullRect = (Offset.zero & size).inflate(nodeIconSize * 5);

                // nodes that have been raised — walked into, or tapped for a
                // tooltip — are shunted to the end in the order it happened, so
                // they render on top of the others; global keys keep their
                // widget state stable across the reordering
                final raised = game.nodes.where((x) => x.stackRank > 0).toList()
                  ..sort((a, b) => a.stackRank - b.stackRank);
                final orderedNodes = [
                  ...game.nodes.where((x) => x.stackRank == 0),
                  ...raised,
                ];
                final tip = game.tooltip.value;
                // Once the map is small enough that the badges cover the graph
                // they're standing on, a second copy of the graph fades in over
                // the top of them. Only recorded when it's going to be used.
                // Measured in log zoom, so the fade tracks how far out the
                // pinch has taken you rather than the raw scale, which spends
                // most of its range near the far end.
                final overGraphp =
                    overGraphMaxOpacity *
                    unlerpUnit(log(_defaultZoom), log(game.zoomMin), log(zoom));
                final recording = overGraphp > 0 ? _graphRecording : null;
                // Everything anchored to a node goes inside one moving layer,
                // laid out in world units scaled by the zoom and shifted whole
                // by the camera. The nodes used to be positioned individually
                // at wherever the camera projected them, which meant a pan
                // moved every one of them relative to their parent, and the
                // [Animove]s around the badges read that as the badges moving.
                // Panning the container instead leaves them still inside it.
                final layerOrigin = project(_worldRect.topLeft);
                Offset inLayer(Offset world) =>
                    (world - _worldRect.topLeft) * zoom;

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      size: size,
                      painter: _WorldPainter(
                        game: game,
                        cam: cam,
                        zoom: zoom,
                        viewCenter: viewCenter,
                        recording: recording,
                      ),
                    ),
                    Positioned(
                      left: layerOrigin.dx,
                      top: layerOrigin.dy,
                      width: _worldRect.width * zoom,
                      height: _worldRect.height * zoom,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // node widgets are still culled every frame, and
                          // still don't scale with the zoom — only their places
                          // in the layer do
                          for (final node in orderedNodes)
                            if (cullRect.contains(project(node.pos)))
                              _positioned(
                                inLayer(node.pos),
                                _contentCache[node] ??= NodeContentWidget(
                                  game: game,
                                  node: node,
                                  farZoom: farZoom,
                                ),
                                key: GlobalObjectKey(node),
                              ),
                        ],
                      ),
                    ),
                    if (recording != null)
                      CustomPaint(
                        size: size,
                        painter: _OverGraphPainter(recording, overGraphp),
                      ),
                    // players in transit stay above the overlay: they're what
                    // the eye is following
                    for (final p in game.players)
                      if (p.traversing != null &&
                          cullRect.contains(project(p.worldPos())))
                        _positioned(project(p.worldPos()), PlayerOrb(game, p)),
                    if (tip != null && cullRect.contains(project(tip.$2.pos)))
                      _tooltipBubble(project(tip.$2.pos), tip.$3, tip.$2),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _positioned(Offset at, Widget child, {Key? key}) => Positioned(
    key: key,
    left: at.dx,
    top: at.dy,
    child: FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: child,
    ),
  );

  /// The explanation bubble a tapped facility icon shows, hovering over its
  /// node; tapping the world dismisses it. Filled like the lozenges of the
  /// node it came from — it's what one of them had to say, so it's the same
  /// colour saying it. It keeps a border where the lozenges dropped theirs:
  /// this one floats over the map instead of sitting in a node's own stack,
  /// and it has to hold its own over whatever it's covering.
  Widget _tooltipBubble(Offset at, List<InlineSpan> spans, Node from) =>
      Positioned(
        left: at.dx - 110,
        top: at.dy,
        width: 220,
        child: FractionalTranslation(
          translation: const Offset(0, -1.35),
          child: Center(
            child: GestureDetector(
              onTap: () => widget.game.tooltip.value = null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: lozengeFill(nodeColor(from)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.outlineStrong, width: 0.8),
                  boxShadow: [BoxShadow(color: palette.shadow, blurRadius: 6)],
                ),
                child: Text.rich(
                  TextSpan(
                    children: spans,
                    style: TextStyle(fontSize: 11, color: palette.ink),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The graph as it was painted this frame, held so it can be laid down a second
/// time over the node widgets without rebuilding every path and gradient.
/// [_WorldPainter] fills it and [_OverGraphPainter] reads it; the two are
/// children of one stack, in that order, so the ink is dry before it's needed.
class GraphRecording {
  ui.Picture? picture;
}

class _WorldPainter extends CustomPainter {
  final Game game;
  final Offset cam;
  final double zoom;
  final Offset viewCenter;

  /// non-null only when the zoomed-out overlay is going to want a copy
  final GraphRecording? recording;
  _WorldPainter({
    required this.game,
    required this.cam,
    required this.zoom,
    required this.viewCenter,
    this.recording,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (recording == null) {
      _paintGraph(canvas, size);
      return;
    }
    final recorder = ui.PictureRecorder();
    _paintGraph(Canvas(recorder), size);
    // the previous frame's picture has been through the raster thread and the
    // display list that used it holds its own reference, so this handle is the
    // last thing keeping it alive
    recording!.picture?.dispose();
    recording!.picture = recorder.endRecording();
    canvas.drawPicture(recording!.picture!);
  }

  void _paintGraph(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewCenter.dx, viewCenter.dy);
    canvas.scale(zoom);
    canvas.translate(-cam.dx, -cam.dy);

    // The graph's edges are filled rather than stroked — see the loop below,
    // which builds each one as a shape so its fillets can come along for the
    // ride. The trains' rails are still strokes: they get no fillets, and a
    // stroke is what a rail is.
    final edgePaint = Paint();
    final trainEdgePaint = Paint()
      ..strokeWidth = edgeWidth
      ..strokeCap = StrokeCap.round;

    // Each blight's territory, under the whole graph: a thick opaque dashed
    // ring in its red washed most of the way out to the background, with a
    // disc of the same behind the blight's own node. Kept faint by colour
    // rather than by transparency, so nothing drawn over it is tinted.
    final blightBase = Color.lerp(
      Colors.red,
      palette.ground,
      palette.blightWash,
    )!;
    for (final b in game.blights) {
      final color = b.flash.active
          ? Color.lerp(blightBase, Colors.red, 0.5)!
          : b.dormant
          ? Color.lerp(blightBase, palette.ground, 0.55)!
          : blightBase;
      canvas.drawCircle(b.node.pos, 2, Paint()..color = color);
      _paintDashedCircle(
        canvas,
        b.node.pos,
        b.radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = color,
      );
    }

    // the trains' own shortcuts, which nothing else can travel along, each in
    // its train's livery
    for (final t in game.trains) {
      trainEdgePaint.color = nodeColor(t);
      final termini = t.stationNodes.map((s) => t.terminusFor[s]!).toList();
      for (var i = 0; i < termini.length; i++) {
        for (var j = i + 1; j < termini.length; j++) {
          canvas.drawLine(termini[i], termini[j], trainEdgePaint);
        }
      }
    }
    // An edge runs a gradient between the colours of the two nodes it joins:
    // it belongs to both of them, and one flat colour would have had to pick a
    // side. The paint carries a shader per edge now rather than one colour for
    // the whole graph — a station's edge to a docked train fades from the grey
    // into the livery, which is the join saying which of the two it is at
    // either end.
    //
    // The gradient's ends are pulled in past the node circles rather than run
    // centre to centre, so the whole of the transition happens in the open
    // between them. Anchored at the centres, a third of the fade would be
    // hidden under the discs and an edge would leave its node already part
    // way to the other one's colour. Clamped stops carry each end colour flat
    // through the gap. On an edge too short to give both ends their margin the
    // handles close up towards the middle and the fade is what's left — but
    // never all the way onto each other: a station's edge to its docked train
    // is shorter than two margins, and a gradient with both ends in the same
    // place isn't a gradient.
    //
    // Body and fillets go into one path filled in one go, rather than a stroke
    // plus four wedges. The gradient is the reason: it's defined in world
    // coordinates, so a separately drawn fillet could be given the same shader
    // and still land the same colour — but drawing it separately means abutting
    // two antialiased edges along the flank, which leaves a hairline seam of
    // whatever's underneath. One path, one fill, no seam, and one draw call an
    // edge instead of two.
    for (final e in game.edges) {
      final span = e.b.pos - e.a.pos;
      final length = span.distance;
      if (length == 0) continue;
      final inset =
          min(nodeRadius + edgeGradientMargin, length * 0.45) / length;
      edgePaint.shader = ui.Gradient.linear(
        e.a.pos + span * inset,
        e.b.pos - span * inset,
        [nodeColor(e.a), nodeColor(e.b)],
      );
      // the body: the wire as a quad, running centre to centre — the ends are
      // buried under the discs, which are drawn over it
      final flank = Offset(-span.dy, span.dx) / length * (edgeWidth / 2);
      final path = Path()
        ..addPolygon([
          e.a.pos + flank,
          e.b.pos + flank,
          e.b.pos - flank,
          e.a.pos - flank,
        ], true);
      // Fillets at each end, unless that end is a train: a train is a vehicle
      // sitting on the line, not a junction the line grows out of, and welding
      // it to its own rail would say otherwise.
      final angle = offsetAngle(span);
      for (final (node, facing) in [(e.a, angle), (e.b, angle + pi)]) {
        if (node is TrainNode) continue;
        final placement = _filletPlacement(node.pos, facing);
        for (final fillet in _edgeFillets) {
          path.addPath(fillet, Offset.zero, matrix4: placement);
        }
      }
      canvas.drawPath(path, edgePaint);
    }
    edgePaint.shader = null;
    // nodes: circles [nodeRadius] wide, thicker than the edges, each in its
    // own colour — a departure from the graph's grey, or from its rail's
    // colour where the node is a train
    final nodePaint = Paint();
    for (final n in game.nodes) {
      nodePaint.color = nodeColor(n);
      canvas.drawCircle(n.pos, nodeRadius, nodePaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WorldPainter old) => true;
}

/// The graph again, over the node widgets, once the map is zoomed out far
/// enough that the badges have closed over it. It replays what [_WorldPainter]
/// recorded a moment ago rather than painting the graph a second time: the
/// geometry is identical, and building it is the expensive half — a path and a
/// gradient per edge — where replaying a picture is not.
///
/// The layer is what makes it one translucent graph rather than a pile of
/// translucent parts: draw the ops at [opacity] each and every place two edges
/// cross comes out darker than the rest of the graph, which is precisely where
/// the structure the overlay exists to show is hardest to read.
class _OverGraphPainter extends CustomPainter {
  final GraphRecording recording;
  final double opacity;
  _OverGraphPainter(this.recording, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final picture = recording.picture;
    if (picture == null || opacity <= 0) return;
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
    );
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverGraphPainter old) => true;

  /// it's a veil over the map, not something to tap — without this it would sit
  /// in front of every badge in the stack and swallow the taps meant for them
  @override
  bool? hitTest(Offset position) => false;
}

/// One flank's worth of the wedge that fills the notch where an edge meets a
/// node, in a frame with the node at the origin and the edge running out along
/// +x. [side] is which flank: +1 for the one on +y, -1 for its mirror.
///
/// Every join in the graph is the same shape — every node is [nodeRadius] and
/// every edge [edgeWidth] — so the two of these are built once and stamped
/// wherever they're needed. The arc of [edgeFilletRadius] is tangent to both
/// the disc and the edge's flank, which is what makes it read as a curve
/// between them rather than a lump stuck on: its centre stands [edgeFilletRadius]
/// clear of the flank and nodeRadius + edgeFilletRadius from the node's centre,
/// and those two conditions fix where along the edge it sits.
Path _buildFillet(double side) {
  const h = edgeWidth / 2;
  const f = edgeFilletRadius;
  final along = sqrt((nodeRadius + f) * (nodeRadius + f) - (h + f) * (h + f));
  final centre = Offset(along, side * (h + f));
  // where the fillet touches the disc, and where the flank runs into it — the
  // wedge is bounded by the fillet's arc, the disc's arc between those two,
  // and the stretch of flank back to where the fillet started
  final onDisc = side * atan2(h + f, along);
  final flank = side * atan2(h, sqrt(nodeRadius * nodeRadius - h * h));
  return Path()
    ..arcTo(
      Rect.fromCircle(center: centre, radius: f),
      side * -pi / 2,
      onDisc - side * pi / 2,
      true,
    )
    ..arcTo(
      Rect.fromCircle(center: Offset.zero, radius: nodeRadius),
      onDisc,
      flank - onDisc,
      false,
    )
    ..close();
}

final List<Path> _edgeFillets = [_buildFillet(1), _buildFillet(-1)];

/// the transform that takes a fillet from its own frame to a node at [at] with
/// its edge leaving along [angle], as the column-major 4x4 [Path.addPath] wants
Float64List _filletPlacement(Offset at, double angle) {
  final c = cos(angle), s = sin(angle);
  return Float64List.fromList([
    c, s, 0, 0, //
    -s, c, 0, 0, //
    0, 0, 1, 0, //
    at.dx, at.dy, 0, 1, //
  ]);
}

/// dashes are ~0.6 units long with a 0.5-unit gap, so the ring reads the same
/// however big the blight is. Butt caps: round ones on a stroke this thick
/// would close the gaps up on a small blight.
void _paintDashedCircle(Canvas canvas, Offset center, double r, Paint paint) {
  final circumference = 2 * pi * r;
  final n = max(5, (circumference / 2.8).round());
  final step = 2 * pi / n;
  final rect = Rect.fromCircle(center: center, radius: r);
  for (var i = 0; i < n; i++) {
    canvas.drawArc(rect, i * step, step * 0.55, false, paint);
  }
}

/// how far either column is held clear of the node's dot
const double _nodeSplitGap = 1.5;

/// The stationary box a node's cluster is centred in, and the coordinate space
/// its badges' [Animove]s are measured against. Generous on purpose: it costs
/// nothing to paint — nothing is drawn in the margin — but a cluster that grew
/// past it would have the overhanging part of itself outside the box, where
/// taps don't reach. Big enough for the widest badge a trader can produce at
/// full size and a column of players beside it, twice over.
const Size clusterFrameSize = Size(600, 400);

/// The [GlobalKey] an [Animove] needs to recognise a widget as the same one it
/// was tracking a frame ago. Badges are rebuilt from scratch on every signal,
/// so the key can't live in the widget — it's hung off the thing the badge is
/// *of*, and comes back on demand. [GlobalObjectKey] would have done it, but
/// the node overlay already keys itself by node and a train's badge is of its
/// node, so the two would collide.
///
/// Weak, so a level that's been thrown away takes its keys with it.
final Expando<GlobalKey> _badgeKeys = Expando('badge keys');
GlobalKey badgeKey(Object of) => _badgeKeys[of] ??= GlobalKey();

/// The facilities in a column left of the node's dot and the players present in
/// a column right of it — but only while both are there to straddle it; alone,
/// either sits on the dot. Straddling rather than centring one wide row keeps
/// each side's inner edge anchored to the dot regardless of what the other side
/// is doing. Rerenders via the playersPresent signal.
class NodeContentWidget extends StatelessWidget {
  final Game game;
  final Node node;
  final Signal<bool> farZoom;
  const NodeContentWidget({
    super.key,
    required this.game,
    required this.node,
    required this.farZoom,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // These widgets are cached by node and handed back to the stack as the
        // same instance every frame, so a rebuild from above passes them by —
        // subscribing to the phase here is what repaints the badges in the
        // other half of the day's [palette].
        game.isNight.value;
        final players = node.playersPresent.value;
        final level = players.isNotEmpty
            ? NodeZoomLevel.selected
            : farZoom.value
            ? NodeZoomLevel.small
            : NodeZoomLevel.normal;
        // Every badge is wrapped in an [Animove] so that when the column
        // rearranges under it — a player arriving and shoving the facilities
        // off the dot, a badge changing width as the zoom level changes what
        // it shows — the badges slide to their new places instead of jumping.
        final facilityBadges = <Widget>[
          if (node is TrainNode)
            Animove(
              key: badgeKey(node),
              child: trainBadge(game, node as TrainNode, level),
            ),
          for (final f in node.facilities)
            Animove(key: badgeKey(f), child: f.badge(game, level)),
        ];
        final facilityColumn = facilityBadges.isEmpty
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                // badges of unequal width line their right edges up on the dot
                // while they're beside a player column, but stack centred on it
                // once they have the node to themselves
                crossAxisAlignment: players.isEmpty
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < facilityBadges.length; i++) ...[
                    if (i > 0) const SizedBox(height: 2),
                    facilityBadges[i],
                  ],
                ],
              );
        final playerColumn = players.isEmpty
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in players)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: PlayerOrb(
                        game,
                        p,
                        onTap: () => game.selectedPlayer.value = p,
                      ),
                    ),
                ],
              );
        // With only one side of the split present there's nothing to make room
        // for, so it sits on the dot rather than hanging off one side of it.
        // Otherwise each half is wrapped in a box of twice its own width with
        // the half pushed to one end, which puts the box's centre exactly on
        // the half's inner edge. Stacking the two boxes centred then lands both
        // inner edges on the node's dot without either side having to know how
        // wide the other one came out — and unlike translating the halves out
        // of place, everything stays inside the stack, where taps still reach
        // it.
        final content = facilityColumn == null || playerColumn == null
            ? facilityColumn ?? playerColumn ?? const SizedBox.shrink()
            : Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(right: _nodeSplitGap),
                      child: facilityColumn,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    widthFactor: 2,
                    child: Padding(
                      padding: const EdgeInsets.only(left: _nodeSplitGap),
                      child: playerColumn,
                    ),
                  ),
                ],
              );
        // The cluster's own [AnimoveFrame], which is what keeps the badges out
        // of the camera's business: their offsets are measured against this
        // box, which travels with the node as one piece, so neither panning nor
        // zooming is a move as far as they're concerned. Only rearranging
        // inside the cluster is.
        //
        // The frame is a fixed box with the cluster centred in it rather than
        // the cluster itself. Shrink-wrapped, the frame's own edges would move
        // whenever the contents changed width — the box is centred on the dot,
        // so widening it by anything shifts its left edge by half of that — and
        // every badge in it would read that shift as having moved, and slide in
        // from one side to land back where it already was. A box that doesn't
        // move can't lie to them about it.
        return AnimoveFrame(
          child: SizedBox.fromSize(
            size: clusterFrameSize,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [content],
            ),
          ),
        );
      },
    );
  }
}
