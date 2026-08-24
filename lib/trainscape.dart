// Trainscape: Thrival — a game about time. See trainscape_thrival.txt for the
// original design doc, and trainscape prompts.txt for later on when we stopped maintaining the design doc. The
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

/// The scheme the whole UI draws itself in. There are two, [lightPalette] and
/// [darkPalette], and the system's brightness setting picks between them — see
/// [paletteSignal]. The game used to flip between them itself, as its own day
/// turned, which is a different and worse idea: the player never asked for it,
/// and it arrived mid-glance.
///
/// The dark one is not the light one inverted. An inverting filter would have
/// been one decision instead of twenty, but it leaves the surfaces exactly as
/// far from the ground as they were, when what a dark UI wants is surfaces
/// lifted clear of the ground and contrast pulled *in* rather than mirrored. So
/// the two are written out independently.
///
/// Item colours are deliberately not in here: an item is known by its colour,
/// and a thing that changes colour isn't recognisable.
class const Palette({
  /// what the world is drawn on; everything that has to recede is mixed
  /// towards this rather than made transparent
  required final Color ground,

  /// chips, slots and name plates — the things that sit on the ground holding
  /// a mark without belonging to a node. The ones that do belong to a node
  /// (its facilities' lozenges, and the tooltip they raise) are filled from
  /// that node's colour instead; see [lozengeFill].
  required final Color surface,

  /// the controls strip those surfaces sit on
  required final Color panel,

  /// the drag pad's face, which reads as recessed rather than raised
  required final Color pad,

  /// The two colours an ordinary node comes in — [NodeTone.plain] and
  /// [NodeTone.deeper] — and so the two colours an ordinary wire can be, since
  /// a wire is a gradient between the nodes at its ends. Written out by hand
  /// rather than derived from one another: they sit close enough together that
  /// any arithmetic producing the second from the first was going to be a
  /// fudge factor standing in for a colour someone had picked by eye anyway.
  ///
  /// "Darker" is the light scheme's word for it. In the dark scheme the deeper
  /// tone steps up rather than down, since that's where the room is.
  required final Color node,
  required final Color nodeDarker,

  /// the same pair for a train's node, the graph's colour warmed. A train's
  /// rails take it too: a train and its line are the same thing seen twice.
  required final Color trainNode,
  required final Color trainNodeDarker,

  /// A node standing in the way of something that can hurt you — a blight. The
  /// one colour on the map that isn't a shade of the graph, and the one that
  /// overrides a node's tone rather than being drawn alongside it: where a
  /// blight will strike is the thing a player has to be able to read across
  /// the whole map without tapping anything, so it can't be left to a roll.
  required final Color hazardNode,

  /// slot, chip and pad borders
  required final Color outline,

  /// the tooltip's border, which has to hold its own over the map
  required final Color outlineStrong,

  /// text and icons
  required final Color ink,

  /// the marks that want the most contrast they can get: numerals sitting on
  /// item icons, cooldown pies
  required final Color inkStrong,

  /// corner hints and the drag pad's arrow
  required final Color inkFaint,
  required final Color shadow,

  /// How far a blight's red is washed out towards [ground]. Its territory is a
  /// region rather than a mark, so it sits barely off the ground and behind
  /// everything.
  required final double blightWash,

  /// what the world is veiled with once the game is over
  required final Color scrim,

  /// The lozenge a node's facilities render into carries that node's colour,
  /// but as a wash rather than at strength: the node's saturation scaled by
  /// [lozengeSaturation], then the whole colour carried [lozengeTintp] of the
  /// way towards [lozengeTint].
  ///
  /// A colour to aim at rather than a distance to travel from the ground, so
  /// the lozenge is stated outright instead of falling out of arithmetic on
  /// the node's. It desaturates a little on the way, which a lozenge wants
  /// anyway.
  required final Color lozengeTint,
  required final double lozengeTintp,
  required final double lozengeSaturation,
}) {
  /// Which side this scheme is on. Almost nothing needs to ask — the point of
  /// a palette is that its colours are already the right way round — but a mark
  /// that means something in absolute terms does: a clock face is pale before
  /// noon in both schemes, so it has to know which of [ground] and [inkStrong]
  /// is the pale one. Derived rather than declared, so it can't disagree with
  /// the colours it's about.
  bool get isDark => HSLuvColor.fromColor(ground).lightness < 50;
}

const lightPalette = Palette(
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

/// The ground doesn't go all the way to black — pure black would make every
/// surface on it glare — and the surfaces sit a clear step above it, since in
/// the light scheme they're told apart from the ground by their outline alone
/// and that trick doesn't survive the dark. Ink stops short of white for the
/// same reason black87 stops short of black over there.
const darkPalette = Palette(
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

/// The scheme in force, following the platform's brightness. Written by
/// [TrainscapeScreen], which is the only thing that reads the platform.
///
/// Read it with `.value` and read it during build, so that whatever is building
/// subscribes and redraws itself when the system flips — the reason the screen
/// and the node widgets are a [SignalStatefulWidget] and a [SignalWidget]. A
/// rebuild from the top can't be relied on to carry a change of scheme down:
/// the map hands the same cached widget back for a node every frame, so a
/// rebuild from above passes those by entirely.
///
/// A [CustomPainter] is the one place this doesn't hold — nothing subscribes
/// during paint — so a painter takes the colours it uses as fields, and its
/// `shouldRepaint` compares them.
final Signal<Palette> paletteSignal = signal(platformPalette());

/// what the platform's brightness setting says the scheme should be, asked
/// right now. [TrainscapeScreen] pushes this into [paletteSignal] whenever it
/// could have changed; the signal's own initial value comes from here too, so a
/// screen that was already up when the code reloaded still starts from the
/// truth rather than from whichever scheme was written down first.
Palette platformPalette() =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark
    ? darkPalette
    : lightPalette;

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

/// The stops the map's zoom button cycles through, as the span of world the
/// short side of the view covers at each — smaller is closer in. Only these two
/// are fixed; the third stop is whatever it takes to fit the whole map in the
/// view, so the cycle reads in → medium → the lot → in again.
const double zoomHighSpan = 6.0;
const double zoomMediumSpan = 16.0;

/// What a pixel of vertical drag on the zoom button is worth, as a factor on
/// the zoom: dragging up pulls the view out, down pushes it in. It's a factor
/// per pixel rather than a step, so the whole range is a drag of the same
/// length wherever you start from.
const double zoomDragPerPixel = 1 / 160;

/// The little square controls stacked against the map's bottom right corner —
/// see [mapButton] — and the gaps they're laid out on.
const double mapButtonIcon = 22.0;
const double mapButtonPad = 6.0;
const double mapButtonExtent = mapButtonIcon + mapButtonPad * 2;
const double mapButtonInset = 10.0;
const double mapButtonGap = 8.0;

/// Clear space around each button that is still part of it as far as a thumb
/// is concerned. Exactly half the gap, which is the most it can be without two
/// buttons fighting over the same tap — their touch areas end up meeting
/// precisely in the middle of the space between them, and nothing about where
/// the buttons look like they are changes.
const double mapButtonTouch = mapButtonGap / 2;

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

/// The game's unit of time is the in-game second, and a day is a day: 86400 of
/// them, laid over the 24-hour clock face the level's schedules are read off.
/// Everything with time in it is in these units — [Game.now], every deadline
/// the event loop waits on, every span and rate in [Parameters] — and so is
/// the moment [Game.advanceTo] is asked for.
///
/// Real time exists in exactly two places. One is the ticker, which converts
/// the frame's wall-clock delta once, on the way in (see [Parameters.pace] and
/// [Parameters.dayRealSeconds]); nothing downstream of it knows how fast the
/// day is being played. The other is the two feedback spans below.
/// Game time is an integer count of ticks, never a float. Two reasons, and the
/// second is the one that matters. The small one: the clock is rewound as well
/// as advanced, and float addition doesn't undo itself. The large one: the
/// world is re-simulated from an earlier moment every time the clock moves
/// back, and a re-simulation that lands a hair off the original is a
/// re-simulation that produces a different game — a player who arrives 1e-15
/// before a train leaves rather than 1e-15 after. Deadlines have to compare
/// exactly, and integers are the only things that do.
///
/// [tickRate] per game second is far finer than anything the game measures —
/// the shortest span in a level is a trade of twenty-odd game minutes — so the
/// quantisation is invisible. It's this fine so that a rate expressed in the
/// units below (`17.5 / gameHour`) has plenty of resolution left after being
/// multiplied back up into a duration.
///
/// The ceiling is [dart:core int], which is 64-bit on every target but the web,
/// where it's a double and stops being exact past 2^53 — the same constraint
/// [GameRng] is written around. 2^53 ticks is seventeen thousand years of game
/// time, so nothing here comes near it.
typedef TTime = int;

/// ticks per game second
const TTime tickRate = 1 << 14;

const TTime gameSecond = tickRate;
const TTime gameMinute = 60 * gameSecond;
const TTime gameHour = 60 * gameMinute;
const TTime gameDay = 24 * gameHour;

/// A span computed in floating point — a distance divided by a speed, a rolled
/// duration — landing on the tick grid. Every span that enters the simulation
/// goes through here, and it's the only door: a double that reaches a deadline
/// unrounded is the bug this whole module exists to prevent.
///
/// Deterministic because it's a pure function of the double handed in, and the
/// doubles handed in are computed the same way on every replay.
TTime ticksOf(double t) => t.round();

/// These two are the only spans stated in real seconds. They aren't part of
/// the level: they're how long a piece of feedback takes to read, which is a
/// fact about the player's eyes and doesn't restretch when the day does. They
/// still tick on the game clock, so pausing pauses them — [Parameters.pace] is
/// what carries them across, via [Parameters.redFlashSpan] and
/// [Parameters.announcementSpan]. Nothing should compare them to a game time
/// directly.
///
/// how long an announcement (MUGGED, BLIGHTSTRUCK…) stays up
const double announcementRealSeconds = 3;

/// a red flash is three pulses over this many seconds
const double redFlashRealSeconds = 1.2;
const int redFlashPulses = 3;

enum FacilityKind {
  trader,
  tree,
  mugger,
  storage,
  station,
  blight,
  outbox,
  inbox,
  jumpStation,
  landingStation,
}

/// A facility can be restricted to one half of the day: day-only ones carry a
/// small day icon before their badge (top-aligned) and fade at night;
/// night-only ones carry a night icon (bottom-aligned) and fade in the day.
///
/// Nothing is generated restricted any more — half of what a player had learnt
/// about the map being inactionable at any given moment cost more than the
/// texture was worth — so every facility is [always] in practice. The display
/// is kept: it's what a restriction would look like if one were ever handed
/// out again, and a saved game can still carry one.
enum ActivePhase { always, dayOnly, nightOnly }

/// r: requires the item to pass, without taking it;
/// rc: requires and confiscates the same item.
enum MuggerKind { r, rc }

/// how a node widget displays, decided by the world view
enum NodeZoomLevel {
  normal, // icons shrunk to a standard width
  small, // badges collapse to their leading icon, item icons hidden
}

enum TrainScheduleKind { never, oneWay, cycle }

enum StationControl {
  none, // render: 's' + small Icons.train
  remote, // + Icons.swipe_right_alt — can move the train from here anytime
  localOnly, // + 'L' Icons.swipe_right_alt — only when the train is docked here
}

enum GamePhase { playing, won, lost }

/// Why the clock is moving, which is the only thing that decides how eagerly
/// it gets there.
///
/// One mover serves all of it, because there's only one clock and it can be
/// pushed by several things at once — a walk playing out while a finger is on
/// the dial. What changes is how hard.
///
/// [hourSeconds] is how long it takes to cross one game hour from a standstill
/// and stop dead on the far side. Stated that way round because it's the thing
/// anyone tuning this actually wants to say; the acceleration is worked out
/// from it. Bigger distances take longer, but only as the square root — a
/// day's worth is not twenty-four times the wait.
enum ClockPush {
  /// catching up to the end of something the player set going
  ease(0.5),

  /// following a finger on the dial. Quick, because a control that lags behind
  /// the thumb doesn't read as a control at all — what smoothing there is here
  /// is for taking the jitter out of a drag, not for feel.
  dial(0.14),

  /// plain unpaused play, where the destination keeps receding. Quick, so the
  /// standing lag behind a moving target stays too small to see.
  play(0.1);

  const ClockPush(this.hourSeconds);
  final double hourSeconds;

  /// ticks per real second per real second. Constant acceleration, so the
  /// distance covered goes as the square of the time — which is what makes
  /// this a parabola rather than the exponential it replaced.
  double get accel => 4 * gameHour / (hourSeconds * hourSeconds);
}

// ────────────────────────────── intervals ──────────────────────────────

/// Repetition comes in two flavours. An [ArbitraryInterval] is just a span of
/// time, counted from whenever it was last started — it has no relationship to
/// the day. A [ClockInterval] is locked to the day: its period is a whole
/// multiple of the day or a whole fraction of it, so it always fires at the
/// same time(s) of day, and it can be displayed as a clock time.
/// Neither kind holds a moment of its own any more. An interval is a shape of
/// repetition and nothing else; whatever is repeating writes down when it last
/// went off (see [Tree.pickedAt]). That's what lets the clock be moved: there
/// is no "time remaining" anywhere to be wound back, only moments and the
/// arithmetic between them.
sealed class Interval {
  TTime get period;
}

class ArbitraryInterval(@override final TTime period) extends Interval {}

class ClockInterval({
  /// exactly one of these is > 1: the period is a whole multiple of the day,
  /// or a whole fraction of it
  final int multiple = 1,
  final int division = 1,

  /// where in the period it fires, in ticks
  required final TTime offset,
}) extends Interval {
  /// Exact because [gameDay] carries a factor of 2^14 from [tickRate] and
  /// another of 86400, so every division the game hands out divides it whole.
  @override
  TTime get period => gameDay * multiple ~/ division;

  /// ticks from [t] until the next firing, counting a firing exactly at [t] as
  /// having already gone: this is always the span to a moment strictly after
  /// [t], which is what the event scheduler wants of it (see [Game.advanceTo])
  /// and what a countdown wants of it too
  TTime remainingAt(TTime t) {
    final r = (offset - t) % period;
    return r == 0 ? period : r;
  }

  /// the next firing strictly after [t] — the scheduler's view of [remainingAt]
  TTime nextAfter(TTime t) => t + remainingAt(t);

  /// which repetition [t] falls in; a firing is a change in this number.
  /// Floor division, not [num.~/], which truncates towards zero and so would
  /// put the whole period before the offset in cycle 0 along with the one
  /// after it.
  int cycleAt(TTime t) {
    final d = t - offset;
    return d >= 0 ? d ~/ period : -((-d + period - 1) ~/ period);
  }

  /// whether the period is a whole multiple of a day (rather than a fraction),
  /// which is what makes a single time of day meaningful
  bool get isDaily => division == 1;

  /// the time of day it fires at, in ticks into the day
  TTime get timeOfDay => offset % gameDay;
}

/// picks a clock interval firing [division] times a day at a random phase
ClockInterval _divisionInterval(GameRng rng, int division) => ClockInterval(
  division: division,
  offset: ticksOf(rng.nextDouble() * gameDay / division),
);

/// A three-pulse red flash, driven off the game clock. It clears itself once
/// spent so that nothing stays subscribed to the clock while idle.
/// A three-pulse red flash, driven off the game clock.
///
/// Nothing clears it: it's the moment it was set off and it stays that, and
/// whether it's showing is worked out from the clock. That's what makes it
/// rewindable for free — a flash triggered by an event the player has since
/// rewound past reads as not showing, because [Game.now] is back before it
/// again, and no undo had to run.
///
/// It still costs an idle facility nothing per frame. [flashingAt] peeks at
/// the clock rather than reading it, so a badge only subscribes to the clock —
/// inside [rednessAt] — during the second or so it's actually pulsing. The
/// last frame of a flash is subscribed, so it rebuilds once more and lets go.
class RedFlash {
  final Signal<TTime?> startedAt = signal(null);
  void trigger(TTime t) => startedAt.value = t;

  /// whether the flash is showing at [now], without subscribing to the clock
  bool flashingAt(TTime now, TTime span) {
    final s = startedAt.value;
    return s != null && now >= s && now - s <= span;
  }

  /// 0..1 redness at game time [t], over a flash lasting [span] ticks
  /// ([Parameters.redFlashSpan]); reading this subscribes to the clock, so
  /// only call it when [flashingAt]
  double rednessAt(TTime t, TTime span) {
    final s = startedAt.value;
    if (s == null) return 0;
    final e = t - s;
    if (e < 0 || e > span) return 0;
    return sin(e / span * redFlashPulses * pi).abs();
  }
}

// ────────────────────────────── parameters ──────────────────────────────

/// Every "may or may not"/"some" choice from the design doc. One instance per
/// level, and nothing here has a default: a level is a whole set of these
/// answers written down together, not a couple of edits to an implied one. The
/// levels themselves are the static methods at the bottom — [levelOne] is the
/// one being played and tuned, [urLevel] the one it started as.
class Parameters({
  required final int seed,

  // goal
  required final TTime globalTime,
  required final int eudaimoniaGoal,

  /// How long a day takes to play, in real seconds — the level's pace, and the
  /// one number here that isn't in game time. A day is always [gameDay] long
  /// and the clock face always runs midnight to midnight; this is only how
  /// fast the player watches that happen, and the only thing that reads it is
  /// the ticker, through [pace].
  required final double dayRealSeconds,

  // players
  required final int nPlayers,
  required final int inventoryCap,
  required final double playerSpeed, // world units per tick
  required final bool playersHaveMoveAction,

  // grid & graph (levelgen section of the doc)
  required final int gridSizeN,
  required final double gridSpacing,
  required final double gridSizeDistortionCountStartp,
  required final double gridSizeDistortionCountVariancep,
  required final double gridSizeDistortionp,
  required final double lineRemovalProb, // doc: acts when rng > prob
  required final double pointRemovalProb, // ditto
  required final double middleNodeProb, // ditto
  required final double splitNodeMinDistance,

  // items
  required final List<Color> itemColors,
  required final List<int> tierCount, // length = number of item tiers
  required final List<TraderGeneratorsForTier> traderGeneratorsPerTier,
  required final double
  iconNestingp, // chance a host icon absorbs each later part
  /// chance a nesting squircle is willing to take a 2x2 footprint, so that its
  /// inner grid gets full-size cells; it falls back to 1x1 where that won't fit
  required final double squircleTryEmbeddingLargep,

  /// when an icon has both a big and a small footprint available, the chance
  /// the big one is the one tried first
  required final double iconGridPlacementBigp,

  // rendering: node widgets drop to NodeZoomLevel.small when zoomed out
  // beyond this multiple of the default zoom
  required final double farZoomThreshold,

  // facility strewing: one bucket per node (incl. train nodes); sizes follow
  // bucketSizeWeights closely (apportioned, not sampled); all generated
  // traders are placed first, remaining slots filled by nonTraderWeights.
  // Every parameter that divides something up is a set of weights with an
  // arbitrary total, never proportions that have to sum to one — weights are
  // what a human can actually sit down and tweak.
  required final List<double>
  bucketSizeWeights, // index = bucket size, starting at 0
  required final Map<FacilityKind, double> nonTraderWeights,

  /// how often each of the three node colourings comes up. See [NodeTone].
  required final List<(double, NodeTone)> nodeToneWeights,

  // trees
  required final TTime treeRegenTime, // arbitrary-interval trees
  required final double
  treeClockIntervalp, // else the regen is a daily clock interval
  required final double treeSecondItemProb, // "an item or two"
  required final double treeTier1Prob, // else tier 0 ("first or second tier")
  // traders
  required final double traderInstantProb,
  required final (TTime, TTime) tradeDurationRange,
  required final double traderCooldownProb,
  required final (TTime, TTime) traderCooldownRange,

  // muggers
  required final TTime muggerIncapTime,
  required final List<(double, MuggerKind)> muggerKindWeights,

  // storage
  required final (int, int) storageCapacityRange, // log-distributed
  required final double storageSecurep, // secured storages are safe from blight
  // outboxes & inboxes
  /// An outbox holds less than a storage does: its contents can be lifted off
  /// the map from anywhere, and a warehouse that can be siphoned from across
  /// the level is a level with fewer journeys in it. Log-distributed, and
  /// secured on the same [storageSecurep] — the lock is proof against the
  /// blight, not against the network.
  required final (int, int) outboxCapacityRange,
  required final double inboxActivationProb, // requires a held Quantity to pull
  required final double inboxActivationConsumedProb, // of those: an actual cost
  // jump stations
  required final double jumpFreeAimp, // else it can only reach landing stations
  required final double jumpCostItemp,
  required final double jumpCooldownp,
  required final (TTime, TTime) jumpCooldownRange,
  // blights
  /// The sizes a blight comes in, drawn from uniformly. Discrete rather than a
  /// range: a blight's radius is something the player has to judge by eye from
  /// across the map, and a handful of recognisable sizes can be learned where
  /// a continuum of them can only be guessed at.
  required final List<double> blightRadii,
  required final double blightMitigablep,
  required final double blightHungryp, // of the mitigable ones
  required final (int, int)
  blightDaysRange, // its clock interval, in whole days
  // trains
  required final int nTrains,
  required final int stationsPerTrain,

  required final double trainSpeed, // world units per tick, as [playerSpeed]
  required final double trainActivationProb, // requires a held Quantity to move
  required final double trainActivationConsumedProb, // of those: an actual cost
  required final double trainActivationTwoProb, // quantity 2 instead of 1
  required final List<(double, TrainScheduleKind)> scheduleDistribution,
  required final List<int>
  trainCycleDivisions, // shuttles this many times a day
  required final double movableFromInsideProb, // of manually movable trains
  required final List<(double, StationControl)> stationControlWeights,
  required final double trainTerminusDistance,
  required final TTime oneWayReturnDelay,
}) {
  // ── pace ──
  //
  // Everything above with time in it is in ticks (or units per tick), written
  // with the [gameMinute]/[gameHour]/[gameDay] constants so that the figure and
  // its unit sit together. Ticks are what the update loop steps by, what the
  // save file holds, and what the readouts are formatted from, so nothing below
  // here converts a span — the only conversion in the game is this one, from
  // the wall clock into game time, and it happens once a frame in the ticker.
  //
  // A rate written `17.5 / gameHour` needs no attention on the way across: it
  // was units per game second when [gameHour] was 3600 and it's units per tick
  // now that [gameHour] counts ticks, because the same constant is doing the
  // dividing either way.

  /// ticks per real second — how fast the day is being played
  double get pace => gameDay / dayRealSeconds;

  /// [s] real seconds as the ticks they'll take to elapse
  TTime realSeconds(double s) => ticksOf(s * pace);

  /// [redFlashRealSeconds] and [announcementRealSeconds] on the game clock
  TTime get redFlashSpan => realSeconds(redFlashRealSeconds);
  TTime get announcementSpan => realSeconds(announcementRealSeconds);

  /// The level being played and tuned. Started as a straight copy of
  /// [urLevel] — which is the point of urLevel: this one is free to move.
  /// Unlike urLevel it's allowed to name live things ([defaultItemColors],
  /// [levelOneTraders]), since it isn't holding anything still.
  static Parameters levelOne(int seed) {
    const tierCount = [13, 10, 4];
    return Parameters(
      seed: seed,
      globalTime: 4 * gameDay,
      eudaimoniaGoal: 4,
      dayRealSeconds: 240,
      nPlayers: 2,
      inventoryCap: 4,
      playerSpeed: 17.5 / gameHour,
      playersHaveMoveAction: true,
      gridSizeN: 8,
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
        FacilityKind.mugger: 2,
        FacilityKind.blight: 0.1,
        FacilityKind.outbox: 4,
        FacilityKind.inbox: 0.8,
        FacilityKind.jumpStation: 1.5,
        FacilityKind.landingStation: 5,
      },
      nodeToneWeights: const [
        (1, NodeTone.plain),
        (0.1, NodeTone.deeper),
        (1, NodeTone.tinted),
      ],
      treeRegenTime: 4 * gameHour,
      treeClockIntervalp: 0.6,
      treeSecondItemProb: 0.3,
      treeTier1Prob: 0.3,
      traderInstantProb: 0.5,
      tradeDurationRange: (24 * gameMinute, 90 * gameMinute),
      traderCooldownProb: 0.3,
      traderCooldownRange: (1 * gameHour, 40 * gameHour),
      muggerIncapTime: 2 * gameHour,
      muggerKindWeights: const [(3, MuggerKind.r), (2.3, MuggerKind.rc)],
      storageCapacityRange: (2, 12),
      storageSecurep: 0.12,
      outboxCapacityRange: (1, 6),
      inboxActivationProb: 0.55,
      inboxActivationConsumedProb: 0.7,
      jumpFreeAimp: 0.3,
      jumpCostItemp: 0.5,
      jumpCooldownp: 0.6,
      jumpCooldownRange: (1 * gameHour, 40 * gameHour),
      blightRadii: const [5, 7, 14],
      blightMitigablep: 0.8,
      blightHungryp: 0.15,
      blightDaysRange: (1, 3),
      nTrains: 3,
      stationsPerTrain: 2,
      trainSpeed: 60 / gameHour,
      trainActivationProb: 0.35,
      trainActivationConsumedProb: 0.25,
      trainActivationTwoProb: 0.25,
      scheduleDistribution: const [
        (1, TrainScheduleKind.never),
        (0, TrainScheduleKind.oneWay),
        (0, TrainScheduleKind.cycle),
      ],
      trainCycleDivisions: const [8, 10, 12, 15, 16, 20, 24, 30],
      movableFromInsideProb: 0.8,
      stationControlWeights: const [
        (3, StationControl.none),
        (4, StationControl.remote),
        (3, StationControl.localOnly),
      ],
      trainTerminusDistance: 1.5,
      oneWayReturnDelay: 12 * gameMinute,
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
      globalTime: 10 * gameDay,
      eudaimoniaGoal: 3,
      dayRealSeconds: 240,
      nPlayers: 2,
      inventoryCap: 5,
      playerSpeed: 17.5 / gameHour,
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
      // The kinds that didn't exist yet are weighted 0 rather than left out:
      // the snapshot is of a level that had no outboxes or jump stations in
      // it, and a zero-weighted kind takes no slots and draws no numbers, so
      // the rng stream comes out exactly as it did.
      nonTraderWeights: const {
        FacilityKind.tree: 10,
        FacilityKind.storage: 4,
        FacilityKind.mugger: 3,
        FacilityKind.blight: 0.12,
        FacilityKind.outbox: 0,
        FacilityKind.inbox: 0,
        FacilityKind.jumpStation: 0,
        FacilityKind.landingStation: 0,
      },
      nodeToneWeights: const [
        (1, NodeTone.plain),
        (1, NodeTone.deeper),
        (1, NodeTone.tinted),
      ],
      treeRegenTime: 150 * gameMinute,
      treeClockIntervalp: 0.6,
      treeSecondItemProb: 0.3,
      treeTier1Prob: 0.23,
      traderInstantProb: 0.5,
      tradeDurationRange: (24 * gameMinute, 90 * gameMinute),
      traderCooldownProb: 0.3,
      traderCooldownRange: (30 * gameMinute, 150 * gameMinute),
      muggerIncapTime: 2 * gameHour,
      muggerKindWeights: const [(3, MuggerKind.r), (4, MuggerKind.rc)],
      storageCapacityRange: (2, 12),
      storageSecurep: 0.12,
      // nothing in the snapshot generates one of these; they're here because
      // the constructor wants them
      outboxCapacityRange: (1, 6),
      inboxActivationProb: 0.55,
      inboxActivationConsumedProb: 0.7,
      jumpFreeAimp: 0.3,
      jumpCostItemp: 0.5,
      jumpCooldownp: 0.6,
      jumpCooldownRange: (1 * gameHour, 40 * gameHour),
      blightRadii: const [5, 7, 14],
      blightMitigablep: 0.8,
      blightHungryp: 0.15,
      blightDaysRange: (1, 3),
      nTrains: 3,
      stationsPerTrain: 2,
      trainSpeed: 60 / gameHour,
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
      oneWayReturnDelay: 12 * gameMinute,
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

class const BasicIcon(final BasicShape shape, final Color color)
    extends ItemIcon {
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

class const IconPlacement(
  final Coord pos, // top-left cell of the footprint in the containing grid
  /// how many cells it took, untilted. Size is settled per placement, not per
  /// icon: a rod is 1x2 or 1x1, a squircle 2x2 or 1x1, whichever fit.
  final Coord footprint,
  final bool tilted, // irregular footprints may rotate 90°
  final ItemIcon icon,
) {
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
class const NestingIcon(
  final BasicIcon container,
  final Coord dims,
  final List<IconPlacement> children, {

  /// Whether this squircle is willing to take a 2x2 footprint in the grid it
  /// sits in, so that its own 2x2 inner grid gets full-size cells rather than
  /// quarter-size ones. Only an eligibility — whether it actually gets one is
  /// settled where it's placed — and not part of the icon's identity, which is
  /// why [==] ignores it.
  final bool mayEmbedLarge = false,
}) extends ItemIcon {
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
class const RootGridIcon(final Coord dims, final List<IconPlacement> children)
    extends ItemIcon {
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
class Item(
  final int tier, // 0 = basic; eudaimonia sits above the final tier
  final int iInTier, {
  final bool isEudaimonia = false,
}) {
  late final ItemIcon icon; // basics at construction, composites late-assigned
  /// An item is a value, not a thing: two of the same item are the same item,
  /// and where it sits in the catalogue is its whole name — which is exactly
  /// how the save format writes it down, so this agrees with what's on disk.
  ///
  /// It matters more here than the [Identified] numbers do, because it's what
  /// the implicit comparisons run on: an inventory is a `List<Item>` and the
  /// game does `remove` and `contains` on it, and an inbox gathers the map's
  /// outboxes into a `Map<Item, int>`. Those worked before only because the
  /// catalogue hands out one object per item and everything shares it. Now
  /// they work because they're the same item.
  @override
  bool operator ==(Object other) =>
      other is Item &&
      other.tier == tier &&
      other.iInTier == iInTier &&
      other.isEudaimonia == isEudaimonia;

  @override
  int get hashCode => Object.hash(tier, iInTier, isEudaimonia);
}

class const Quantity(final Item item, final int n);

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

class ItemCatalog(
  final List<List<Item>> tiers, // tiers[tier][i]; lengths = params.tierCount
  final Item eudaimonia,
) {
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
                t.gives.any((q) => q.item == item) &&
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

class const ItemWidget(
  final Item item, {
  super.key,
  final double size = 13,
  final bool outlineOn = false,
}) extends StatelessWidget {
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

class ItemIconPainter(final ItemIcon icon, [final bool outlineOn = false])
    extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) =>
      paintItemIcon(canvas, icon, Offset.zero & size, outlineOn: outlineOn);
  @override
  bool shouldRepaint(ItemIconPainter old) =>
      old.icon != icon || old.outlineOn != outlineOn;
}

// ────────────────────────────── trader generation ──────────────────────────────

typedef RequiredTraderGen = Trader? Function(
  GameRng rng,
  ItemCatalog cat,
  int iItem,
  List<Item> thisTierRequired,
  int iTier,
  List<Item>? nextTierRequired,
);
typedef SupplementalTraderGen = Trader? Function(
  GameRng rng,
  ItemCatalog cat,
  int iTier,
);

class const TraderGeneratorsForTier({
  required final List<(double, RequiredTraderGen)> requiredGenerators,
  required final int supplementalRuns,
  required final List<(double, SupplementalTraderGen)> supplementalGenerators,
});

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
      if (!takes.any((q) => q.item == it)) it,
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
            } while (give == a || give == b);
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
            } while (give == a || give == b);
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
    out.every((t) => !t.gives.any((g) => t.takes.any((k) => k.item == g.item))),
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
      t.duration = roundToMinute(
        rangeInTicks(rng, p.tradeDurationRange.$1, p.tradeDurationRange.$2),
      );
    }
    if (rng.chance(p.traderCooldownProb)) {
      t.cooldown = roundToMinute(
        rangeInTicks(rng, p.traderCooldownRange.$1, p.traderCooldownRange.$2),
      );
    }
  }
  return out;
}

// ────────────────────────────── world graph ──────────────────────────────

/// Everything in a level that is a particular *something* — a node, a player,
/// a facility — as opposed to a value like an [Item] or a piece of topology
/// like an [Edge]. Each carries a number that names it within its level.
///
/// The numbers are positions in the lists the level is written down as, and
/// they're stamped by the [Game] constructor, which is what makes them the
/// same numbers when a saved level is read back: the lists go to disk in order
/// and come back in order. Two things follow. They're what the event ordering
/// breaks ties on (see [Game.advanceTo]) — a replay has to resolve a collision
/// the same way the first run did. And they're what [same] compares, so that
/// asking whether two references are the same thing doesn't depend on their
/// being the same object.
///
/// One number space across all three kinds, so that a node's number can never
/// collide with a facility's and make [same] quietly agree about two unrelated
/// things.
mixin Identified {
  /// -1 until the level is built; see [same]
  int id = -1;
}

/// Whether two references are the same thing. Null is nobody, and nobody is
/// only the same as nobody, so this reads on a null receiver.
///
/// The assert is the guard rail on the one place it can't be used: level
/// generation, which makes and discards nodes long before any of them has been
/// numbered. Down there everything is one graph being assembled and [identical]
/// is both correct and the only thing that works — see [Edge.other], which is
/// called from inside the generator.
extension Sameness on Identified? {
  bool isSameAs(Identified? other) {
    final self = this;
    if (self == null || other == null) return self == null && other == null;
    assert(
      self.id >= 0 && other.id >= 0,
      'compared two things before the level numbered them — during generation, '
      'use identical()',
    );
    return self.id == other.id;
  }
}

class Node with Identified {
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
/// the lozenges its facilities render into. Reads [paletteSignal], so calling
/// it during build is what subscribes that build to the scheme — see there. A
/// tinted node is the plain colour stained; the other
/// two tones are colours in their own right, written out in the scheme. A node
/// that bites is the hazard colour whatever it rolled.
Color nodeColor(Node n) {
  if (n.isHazard) return paletteSignal.value.hazardNode;
  final train = n is TrainNode;
  final plain = train
      ? paletteSignal.value.trainNode
      : paletteSignal.value.node;
  return switch (n.tone) {
    NodeTone.plain => plain,
    NodeTone.deeper =>
      train
          ? paletteSignal.value.trainNodeDarker
          : paletteSignal.value.nodeDarker,
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
    c.saturation * paletteSignal.value.lozengeSaturation,
    c.lightness,
  ).toColor();
  return Color.lerp(
    washed,
    paletteSignal.value.lozengeTint,
    paletteSignal.value.lozengeTintp,
  )!;
}

/// whether a colour has enough of a hue to stain anything with. The item
/// palette carries two greys, and a node tinted with one of those has drawn
/// [NodeTone.tinted] and come out looking like it drew [NodeTone.plain].
bool hasHue(Color c) => HSLuvColor.fromColor(c).saturation > 20;

class Edge(
  final Node a,
  final Node b, {

  /// non-null for the temporary station↔train edge that exists while [dockTrain]
  /// is docked; players walk it to board
  final TrainNode? dockTrain,
}) {
  double get length => (a.pos - b.pos).distance;

  /// [identical] rather than [same] on purpose: this is called from inside
  /// level generation, before anything has been numbered.
  Node other(Node n) => identical(n, a) ? b : a;
  double angleFromNode(Node n) => offsetAngle(other(n).pos - n.pos);
}

/// Base class for entities that have positions in the graph and can have move
/// paths scheduled (for now only players move along move paths).
abstract class Thing with Identified {
  final Signal<Node?> at = signal(null); // null while traversing an edge
}

// ────────────────────────────── what a player did ──────────────────────────────

/// What an action turned out to have done, kept so that a replay can notice it
/// doing something else.
///
/// It's the player's whole hand afterwards, not just what the action itself
/// moved. That's deliberately conservative: an action is part of a plan, and a
/// plan made while holding one thing is not a plan worth carrying out while
/// holding another. So a walk whose only difference is that the walker was
/// robbed on the way here counts as a divergence, and the player is told
/// rather than watched blundering on. Stopping too often is a nuisance;
/// stopping too rarely is a level quietly playing out wrong.
class ActionResult(final List<Item> holding, final Node? at) {
  /// as a multiset, since two identical hands in a different order are the
  /// same hand
  bool matches(ActionResult o) {
    if (!at.isSameAs(o.at) || holding.length != o.holding.length) return false;
    for (final it in holding) {
      if (holding.where((x) => x == it).length !=
          o.holding.where((x) => x == it).length) {
        return false;
      }
    }
    return true;
  }

  static ActionResult of(Player p) =>
      ActionResult(p.inventory.peek(), p.at.peek());
}

/// One thing a player decided to do.
///
/// A level is a starting state plus a list of these per player, and where the
/// world is at any moment is what you get by playing them out. That's the
/// whole reason the clock can be wound back: going back doesn't undo anything,
/// it puts an earlier state in place and runs the scripts forward again. Which
/// in turn is why an action has to be a *decision* and not an effect — "take
/// what this tree is holding", never "gain two of item 4" — so that running it
/// again in a world someone else has meddled with does what the player would
/// have done, or visibly fails to.
sealed class PlayerAction {
  /// The moment it was committed; it never runs before this. Not a promise
  /// that it runs *at* this — a player halfway along a wire finishes walking
  /// first, and one who's been mugged waits until they're back on their feet.
  ///
  /// Nudged forward by [Game.commit] when the player already has something
  /// down for that tick, so that one player's decisions are never two things
  /// happening at the same instant. See there for why.
  TTime notBefore;
  PlayerAction({required this.notBefore});

  /// When it actually happened, and when what it started was over — the same
  /// moment for everything but a walk. Null until it has run once.
  ///
  /// Recorded for the same reason [recorded] is: it's history, and history
  /// outlives a rewind. It can't be worked out afterwards — an action waits on
  /// the walk in front of it and on being on your feet — and it's what the
  /// dial's wheel is drawn from. See [SyntheticClock].
  TTime? ranAt, ranUntil;

  /// What it did the first time round. Null until it has run once; after that
  /// it's what a replay is held against. Not part of a snapshot — see
  /// [PlayerScript] — because it belongs to the history, not to the moment.
  ActionResult? recorded;

  /// Carry it out. Null means it couldn't be — the tree is bare, the train has
  /// gone, the wire isn't there any more.
  ActionResult? perform(Game g, Player p);

  /// for the alert when a replay of this doesn't come out the same way
  String get name;
}

/// Everything a player has done, and how much of it has happened yet.
///
/// [actions] is the history and is never rewound: it's the *input* to the
/// simulation rather than one of its results, so a snapshot doesn't carry it.
/// [done] is, because how far through the list the world has got is exactly
/// what moving the clock changes.
///
/// Committing while [done] is short of the end throws the tail away. That's
/// the ordinary meaning of doing something else instead: you went back, you
/// made a different decision, and what you were going to do afterwards was a
/// plan for a world that now isn't going to happen.
class PlayerScript {
  final List<PlayerAction> actions = [];
  int done = 0;

  PlayerAction? get next => done < actions.length ? actions[done] : null;

  /// Everything from here on, gone. Used when a replay comes out differently:
  /// the rest was a plan resting on something that didn't happen.
  void truncate() => actions.removeRange(done, actions.length);

  /// Drops only what has been played once already — the stretch a rewind left
  /// sitting ahead of the cursor, waiting to happen again.
  ///
  /// The distinction matters because two things can be ahead of the cursor and
  /// they mean opposite things. An action carrying a [PlayerAction.recorded]
  /// has happened before and is queued to happen again, and deciding to do
  /// something else instead is what replaces it. An action without one has
  /// never happened at all — it's a step the player queued a moment ago while
  /// walking, and they want both it and the one they're adding now.
  void truncateReplayed() {
    var k = done;
    while (k < actions.length && actions[k].recorded != null) {
      k++;
    }
    actions.removeRange(done, k);
  }
}

/// Step onto the next node along. The only action that leaves the player busy
/// afterwards; the rest are done the moment they're done.
class MoveAction(final Node to, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'walk';

  @override
  ActionResult? perform(Game g, Player p) {
    final from = p.at.peek();
    if (from == null) return null;
    final edge = from.edges.firstWhereOrNull((e) => e.other(from).isSameAs(to));
    if (edge == null) return null; // the wire's gone: its train left
    p.departOn(g, edge, to);
    return ActionResult.of(p);
  }
}

class HarvestAction(final Tree tree, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'harvest';

  @override
  ActionResult? perform(Game g, Player p) =>
      tree.harvest(g, p) ? ActionResult.of(p) : null;
}

class TradeAction(final Trader trader, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'trade';

  @override
  ActionResult? perform(Game g, Player p) =>
      trader.startTrade(g, p) ? ActionResult.of(p) : null;
}

class CollectAction(final Trader trader, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'collect';

  @override
  ActionResult? perform(Game g, Player p) =>
      trader.collect(g, p) ? ActionResult.of(p) : null;
}

class FeedAction(final Blight blight, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'appease';

  @override
  ActionResult? perform(Game g, Player p) =>
      blight.feed(g, p) ? ActionResult.of(p) : null;
}

/// Naming the item is the point: an inbox reaches into every outbox on the
/// map, and what's in them is exactly what another player can have changed
/// while this one was walking. Asking for the item rather than for "the first
/// slot" is what lets a replay tell "I got what I came for" from "I got
/// whatever happened to be there".
class PullAction(final Inbox inbox, final Item item, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'take from the inbox';

  @override
  ActionResult? perform(Game g, Player p) =>
      inbox.pull(g, p, item) ? ActionResult.of(p) : null;
}

class JumpAction(
  final JumpStation station,
  final Node to, {
  required super.notBefore,
}) extends PlayerAction {
  @override
  String get name => 'jump';

  @override
  ActionResult? perform(Game g, Player p) =>
      station.jump(g, p, to) ? ActionResult.of(p) : null;
}

class StoreAction(final Item item, {required super.notBefore})
    extends PlayerAction {
  @override
  String get name => 'put away';

  @override
  ActionResult? perform(Game g, Player p) =>
      g.storeFromInventory(p, item) ? ActionResult.of(p) : null;
}

class RotateAction(
  final Storage from,
  final Item item, {
  required super.notBefore,
}) extends PlayerAction {
  @override
  String get name => 'move an item on';

  @override
  ActionResult? perform(Game g, Player p) =>
      g.rotateItemOnward(p, from, item) ? ActionResult.of(p) : null;
}

/// Sending a train isn't something the player does to themselves, so what it
/// leaves behind in [ActionResult] is only whatever the fare cost them. The
/// train's own journey is the train's, and is replayed by the train.
class TrainMoveAction(
  final TrainNode train,
  final Node to, {
  required super.notBefore,
}) extends PlayerAction {
  @override
  String get name => 'send the train';

  @override
  ActionResult? perform(Game g, Player p) =>
      g.manualTrainMove(train, p, to) ? ActionResult.of(p) : null;
}

class Player(final String name, final Color color) extends Thing {
  final Signal<List<Item>> inventory = signal(const []);

  /// while [Game.now] is under this, everything the player could do is blocked;
  /// null when they're free
  final Signal<TTime?> incapacitatedUntil = signal(null);

  /// flashes their inventory red — muggings and blights
  final RedFlash flash = RedFlash();

  /// everything this player has decided to do, and how far through it the
  /// world has got
  final PlayerScript script = PlayerScript();

  /// The walk in progress: which wire, which end of it they're heading for,
  /// and the two moments that bracket the crossing.
  ///
  /// Both ends are recorded rather than a progress fraction being carried
  /// along. A fraction has to be advanced by the size of whatever step the
  /// simulation happens to take, which makes where the player is a function of
  /// how the clock was cut up on the way here — the same journey run in one
  /// step and in a thousand ends in different places, because the step that
  /// crosses the far end overshoots it and the overshoot is thrown away. Two
  /// absolute moments and a lerp between them give the same answer at a given
  /// [Game.now] however the clock got there, which is the whole requirement
  /// for the world being re-simulable. (Everything else in the file that used
  /// to count down does the same thing now, for the same reason.)
  Edge? traversing;
  Node? traversalTarget;
  TTime departedAt = 0, arrivesAt = 0;

  Offset worldPos(TTime now) {
    final edge = traversing;
    if (edge != null) {
      final from = edge.other(traversalTarget!);
      final span = arrivesAt - departedAt;
      return Offset.lerp(
        from.pos,
        traversalTarget!.pos,
        span <= 0 ? 1 : clampUnit((now - departedAt) / span),
      )!;
    }
    return at.value?.pos ?? Offset.zero;
  }

  bool incapacitatedAt(TTime now) {
    final u = incapacitatedUntil.value;
    return u != null && now < u;
  }

  /// The next moment this player does something: land at the far end of a
  /// walk, or carry out the next thing on their list. Neither can happen while
  /// they're flat on their back, so the block is folded into the time rather
  /// than being an event of its own — coming round from a mugging isn't
  /// something that happens, it's something that stops being true.
  TTime? nextEventAt(Game g) {
    if (traversing != null) return arrivesAt;
    final a = script.next;
    if (a == null || at.peek() == null) return null;
    final u = incapacitatedUntil.peek();
    return u == null ? a.notBefore : max(a.notBefore, u);
  }

  /// whether the pending event is an arrival, which sorts ahead of departures;
  /// see [Game.advanceTo]
  bool get nextIsArrival => traversing != null;

  void fire(Game g) {
    if (traversing != null) {
      _arrive(g);
    } else {
      g.runNextAction(this);
    }
  }

  /// Sets off along [edge] towards [to]. Called by [MoveAction], which is the
  /// only thing that ever decides to walk; the arrival at the far end is a
  /// consequence rather than a decision, and gets an event of its own.
  void departOn(Game g, Edge edge, Node to) {
    final from = at.peek()!;
    traversing = edge;
    traversalTarget = to;
    departedAt = g.now;
    // never zero, or a wire with no length would be an event that fires at the
    // moment it was scheduled and the event loop would never get past it
    arrivesAt = g.now + max(1, ticksOf(edge.length / g.params.playerSpeed));
    at.value = null;
    from.playersPresent.value = from.playersPresent.value
        .where((p) => !p.isSameAs(this))
        .toList();
  }

  void _arrive(Game g) {
    final node = traversalTarget!;
    traversing = null;
    traversalTarget = null;
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
class const CycleSchedule(final ClockInterval interval) extends TrainSchedule {
  TTime get period => interval.period;
}

/// Trains ARE nodes: they hold facilities and players like any other node.
/// They dock at terminus points held just off their station nodes; while
/// docked a temporary walkable edge to the station exists, and the permanent
/// shortcut between termini is theirs alone. A train takes its colour from the
/// scheme like every other node — see [Palette.trainNode] — and its rails take
/// it from the train.
class TrainNode({
  required Offset pos,
  required final Quantity? activation, // must be held by the mover
  required final bool activationConsumed, // true (an actual cost) less often
  required final bool movableFromInside,
  required final TrainSchedule schedule,
  required final List<Node> stationNodes,
  required final Map<Node, Offset> terminusFor,
}) extends Node {
  final Signal<Node?> dockedAt = signal(null);

  /// when the train now in transit reaches its far terminus; null when it's
  /// docked. With [departedAt] it brackets the crossing, and [pos] is read off
  /// the pair — see [Player.traversing] for why nothing counts down.
  final Signal<TTime?> arrivesAt = signal(null);
  TTime departedAt = 0;
  Offset _fromPos = Offset.zero, _toPos = Offset.zero;
  Node? _toStation;
  Edge? _dockEdge;

  /// when this train leaves on its own while docked; null = it doesn't
  final Signal<TTime?> departsAt = signal(null);

  this : super(pos);

  Node get homeStation => stationNodes.first;

  /// a train's activation item is a demand the train itself makes, on top of
  /// whatever its facilities want
  @override
  List<Item> get requiredItems => [
    ...super.requiredItems,
    if (activation != null) activation!.item,
  ];

  double unitsPerTick(Parameters p) => p.trainSpeed;

  TTime travelTimeBetween(Node s1, Node s2, Parameters p) => max(
    1,
    ticksOf((terminusFor[s1]! - terminusFor[s2]!).distance / unitsPerTick(p)),
  );

  bool get manualAllowed => switch (schedule) {
    NeverSchedule _ => true,
    OneWaySchedule _ => dockedAt.value.isSameAs(homeStation),
    CycleSchedule _ => false,
  };

  /// [identical] and not [same], because an [Edge] is the one part of a level
  /// with no name of its own — it isn't [Identified], and a gangway in
  /// particular is made and unmade as the train docks and leaves. Anything
  /// that has to survive being rebuilt names an edge by its two ends instead;
  /// see [restoreState].
  bool dockEdgeBusy(Game g) =>
      _dockEdge != null &&
      g.players.any((p) => identical(p.traversing, _dockEdge));

  /// Puts the gangway in, or takes it out again. The boarding wire is the one
  /// piece of the graph that comes and goes, which makes it the one piece a
  /// snapshot has to rebuild rather than assign — hence the pair, used by
  /// docking and departing and by [restoreState] alike.
  void attachDock(Game g, Node station) {
    if (_dockEdge != null) detachDock(g);
    _dockEdge = Edge(station, this, dockTrain: this);
    station.edges.add(_dockEdge!);
    edges.add(_dockEdge!);
    g.edges.add(_dockEdge!);
  }

  void detachDock(Game g) {
    final e = _dockEdge;
    if (e == null) return;
    e.a.edges.remove(e);
    edges.remove(e);
    g.edges.remove(e);
    _dockEdge = null;
  }

  void dock(Game g, Node station) {
    pos = terminusFor[station]!;
    dockedAt.value = station;
    arrivesAt.value = null;
    _toStation = null;
    attachDock(g, station);
    departsAt.value = switch (schedule) {
      OneWaySchedule _ when !station.isSameAs(homeStation) =>
        g.now + g.params.oneWayReturnDelay,
      // cycle trains leave at their clock times, not a fixed wait after docking
      CycleSchedule c => c.interval.nextAfter(g.now),
      _ => null,
    };
  }

  void departTo(Game g, Node station) {
    final from = dockedAt.value;
    if (from == null || from.isSameAs(station)) return;
    detachDock(g);
    dockedAt.value = null;
    _fromPos = pos;
    _toPos = terminusFor[station]!;
    _toStation = station;
    departedAt = g.now;
    arrivesAt.value = g.now + travelTimeBetween(from, station, g.params);
    departsAt.value = null;
  }

  /// Where the train is at [now], written back onto [pos] because everything
  /// that paints a node reads that field. Called once per advance rather than
  /// per event: between two events a train in transit is still moving, and its
  /// position is the one piece of state here that's continuous.
  void syncPos(TTime now) {
    final a = arrivesAt.peek();
    if (a == null) return;
    final span = a - departedAt;
    pos = Offset.lerp(
      _fromPos,
      _toPos,
      span <= 0 ? 1 : clampUnit((now - departedAt) / span),
    )!;
  }

  Node? _nextAutoStation() {
    final here = dockedAt.value;
    if (here == null) return null;
    return switch (schedule) {
      OneWaySchedule _ => here.isSameAs(homeStation) ? null : homeStation,
      CycleSchedule _ => stationNodes.firstWhereOrNull(
        (s) => !s.isSameAs(here),
      ),
      NeverSchedule _ => null,
    };
  }

  /// docking at the end of a crossing, or the scheduled departure — the two
  /// things a train does by itself
  TTime? nextEventAt(Game g) =>
      _toStation != null ? arrivesAt.peek() : departsAt.peek();

  /// whether the pending event is an arrival; see [Game.advanceTo]
  bool get nextIsArrival => _toStation != null;

  void fire(Game g) {
    if (_toStation != null) {
      dock(g, _toStation!);
      return;
    }
    final next = _nextAutoStation();
    if (next == null) {
      departsAt.value = null;
    } else if (dockEdgeBusy(g)) {
      // someone's boarding; try again shortly
      departsAt.value = g.now + gameMinute;
    } else {
      departTo(g, next);
    }
  }
}

// ────────────────────────────── facilities ──────────────────────────────

abstract class Facility with Identified {
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
    return SignalBuilder(
      builder: (context) {
        return badgeRow(
          children,
          tone: tone,
          dim: !activeNow(g),
          leading: Align(
            alignment: dayOnly ? Alignment.topCenter : Alignment.bottomCenter,
            // smaller than the material icons had to be: these shapes hold up
            child: phaseIcon(!dayOnly, size: 7, color: paletteSignal.value.ink),
          ),
        );
      },
    );
  }

  /// the tooltip shown when the badge is tapped: paraphrases the icon
  /// sequence in english, except items, which display as their icons at
  /// full size
  List<InlineSpan> describe(Game g);

  /// action widgets surfaced in the selected player's control panel when
  /// they're at this facility's node
  List<Widget> actionsFor(Game g, Player p) => const [];

  /// The next moment this facility acts of its own accord, or null if it's not
  /// waiting on anything.
  ///
  /// A countdown is not automatically an event. A cooldown running out changes
  /// nothing in the world — it stops being true, and everything that cared was
  /// asking a predicate anyway — so the only reason the ones below are still
  /// scheduled is that the controls that go dim during a cooldown are driven
  /// by signals, and a signal that nothing ever writes is a chip that never
  /// comes back. They're a handful of events per level either way.
  TTime? nextEventAt(Game g) => null;

  /// Whether this facility ever has anything for [nextEventAt] to report —
  /// asked once, when the level is built, so that the event loop can skip the
  /// two thirds of a map that only ever react to being walked into. Override
  /// it to true alongside [nextEventAt]; the pair go together, and a facility
  /// that schedules without saying so simply never gets its turn.
  bool get everSchedules => false;

  /// Runs at exactly the [nextEventAt] that was last reported. Whatever it
  /// changes has to be state the level writes down, because a rewind past this
  /// moment puts the world back by re-running it, not by undoing it.
  void fire(Game g) {}

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

/// item icon size for a badge — the standard shrunk width
const double _facilityItemSize = 11;

class Station(final TrainNode train, final StationControl control)
    extends Facility {
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
    final controlDesc = switch (control) {
      StationControl.none => "this station can't move the train",
      StationControl.remote => 'this station can control the train',
      StationControl.localOnly =>
        'this station can move the train only while it waits here',
    };
    return [tipText('a station of a train; $controlDesc')];
  }

  @override
  List<Widget> actionsFor(Game g, Player p) {
    if (control == StationControl.none) return const [];
    final docked = train.dockedAt.peek();
    final target = train.stationNodes.firstWhereOrNull(
      (s) => !s.isSameAs(node),
    );
    final controlSatisfied =
        docked != null &&
        (control == StationControl.remote || docked.isSameAs(node));
    final enabled =
        controlSatisfied &&
        train.manualAllowed &&
        !train.dockEdgeBusy(g) &&
        (train.activation == null || g.playerHas(p, [train.activation!]));
    final time = docked != null && target != null
        ? train.travelTimeBetween(docked, target, g.params)
        : null;
    return [
      DragDirectionPad(
        dimension: 64,
        enabled: enabled,
        onAngle: (a) => g.dragTrainMove(train, p, a),
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
            if (time != null) badgeText(fmtSpan(time)),
            if (train.activation != null) quantityWidget(train.activation!),
          ],
        ),
      ),
    ];
  }
}

class Tree(
  final List<Quantity> produces, // one or two tier-0/1 items
  /// Either kind of interval: an arbitrary one regrows that many seconds after
  /// it's picked, a clock one regrows at its times of day however long ago it
  /// was picked.
  final Interval regen,
) extends Facility {
  /// when it was last stripped, or null if it's standing in fruit. The moment
  /// rather than a flag plus a countdown: the regrowth is [regrowsAt] away
  /// from it, and both survive the clock being moved.
  final Signal<TTime?> pickedAt = signal(null);

  bool get ready => pickedAt.value == null;

  /// when the fruit is back, or null if it's already there
  TTime? get regrowsAt {
    final t = pickedAt.value;
    if (t == null) return null;
    return switch (regen) {
      ArbitraryInterval _ => t + regen.period,
      // a clock tree comes back at its own time of day however long ago it was
      // stripped, so the wait is measured from the picking to the next firing
      ClockInterval c => c.nextAfter(t),
    };
  }

  @override
  ClockInterval? get clockSchedule =>
      regen is ClockInterval ? regen as ClockInterval : null;

  TTime get regenTotal => regen.period;

  @override
  bool get everSchedules => true;

  @override
  TTime? nextEventAt(Game g) => regrowsAt;

  @override
  void fire(Game g) => pickedAt.value = null;

  /// true if it happened. Everything a player does reports that, because
  /// [PlayerAction.perform] is the only caller and a replay has to be able to
  /// tell "done" from "couldn't".
  bool harvest(Game g, Player p) {
    if (!ready || !p.at.value.isSameAs(node)) return false;
    if (!g.roomFor(p, produces)) return false;
    g.giveItems(p, produces);
    pickedAt.value = g.now;
    return true;
  }

  @override
  // tapping a plant on the map only explains it — harvesting is the control
  // panel's job
  Widget badge(Game g, NodeZoomLevel level) => explainTap(
    g,
    SignalBuilder(
      builder: (context) {
        return withPie(
          phaseBadgeRow(g, [
            badgeIcon(Icons.local_florist),
            if (level != NodeZoomLevel.small)
              for (final q in produces)
                quantityWidget(q, size: _facilityItemSize),
          ]),
          pie: CountdownPie(
            game: g,
            endsAt: () => regrowsAt,
            total: regenTotal,
            isCooldown: true,
            clock: clockSchedule,
          ),
        );
      },
    ),
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('a plant producing '),
    ...quantitiesSpans(produces),
    ...switch (regen) {
      ArbitraryInterval a => [
        tipText('; regrows ${fmtSpan(a.period)} after harvest'),
      ],
      ClockInterval c => [tipText('; regrows '), ...describeClockSpans(c)],
    },
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) => [
    actionChip(
      enabled: ready && g.roomFor(p, produces),
      onTap: () => g.commit(p, HarvestAction(this, notBefore: g.actionMoment)),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: badgeGap,
        runSpacing: 2,
        children: [
          badgeIcon(Icons.local_florist),
          badgeText('take'),
          for (final q in produces) quantityWidget(q),
        ],
      ),
    ),
  ];
}

class Trader(final List<Quantity> takes, final List<Quantity> gives)
    extends Facility {
  @override
  List<Item> get requiredItems => [for (final q in takes) q.item];

  TTime duration = 0; // 0 = instant
  TTime cooldown = 0; // 0 = none
  /// when the trade under way completes, and when the rest after one ends;
  /// null for neither. The two never overlap — the rest is set as the work
  /// finishes — so which one the scheduler is waiting on is never in doubt.
  final Signal<TTime?> workEndsAt = signal(null);
  final Signal<TTime?> cooldownEndsAt = signal(null);
  final Signal<List<Quantity>> pendingOutput = signal(const []);
  Player? _worker;

  bool get busy => workEndsAt.value != null;
  bool get cooling => cooldownEndsAt.value != null;

  bool canTrade(Game g, Player p) =>
      !busy &&
      !cooling &&
      pendingOutput.value.isEmpty &&
      p.at.value.isSameAs(node) &&
      g.playerHas(p, takes) &&
      (duration > 0 || _roomForInstant(g, p));

  bool _roomForInstant(Game g, Player p) {
    final takesN = takes.fold(0, (a, q) => a + q.n);
    final givesN = gives
        .where((q) => !q.item.isEudaimonia)
        .fold(0, (a, q) => a + q.n);
    return p.inventory.value.length - takesN + givesN <= g.params.inventoryCap;
  }

  bool startTrade(Game g, Player p) {
    if (!canTrade(g, p)) return false;
    g.takeItems(p, takes);
    if (duration <= 0) {
      _deliver(g, p);
    } else {
      workEndsAt.value = g.now + duration;
      _worker = p;
    }
    return true;
  }

  void _deliver(Game g, Player? p) {
    var leftovers = gives;
    if (p != null && p.at.value.isSameAs(node)) {
      leftovers = g.giveItems(p, gives);
    }
    if (leftovers.isNotEmpty) {
      pendingOutput.value = [...pendingOutput.value, ...leftovers];
    }
    if (cooldown > 0) cooldownEndsAt.value = g.now + cooldown;
  }

  bool collect(Game g, Player p) {
    if (!p.at.value.isSameAs(node) || pendingOutput.value.isEmpty) return false;
    pendingOutput.value = g.giveItems(p, pendingOutput.value);
    return true;
  }

  @override
  bool get everSchedules => true;

  @override
  TTime? nextEventAt(Game g) => workEndsAt.value ?? cooldownEndsAt.value;

  @override
  void fire(Game g) {
    if (workEndsAt.peek() != null) {
      final w = _worker;
      _worker = null;
      workEndsAt.value = null;
      _deliver(g, w);
    } else {
      cooldownEndsAt.value = null;
    }
  }

  /// A [Wrap] rather than a [Row], because this is the widest thing the
  /// control panel ever has to fit and the panel is a strip along the bottom
  /// of a phone. Two items in, two out, a duration and an arrow comes to more
  /// than the width on offer, and a row that can't fit just clips — the player
  /// loses the right-hand half of what the trade actually is.
  Widget _exchangeRow(Game g, {double itemSize = 13}) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: badgeGap,
    runSpacing: 2,
    children: [
      badgeText('T'),
      for (final q in takes) quantityWidget(q, size: itemSize),
      badgeIcon(Icons.navigate_next, size: 12),
      for (final q in gives) quantityWidget(q, size: itemSize),
      if (duration > 0) badgeText(fmtSpan(duration)),
    ],
  );

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(
    builder: (context) {
      final hasPending = pendingOutput.value.isNotEmpty;
      final working = busy;
      return explainTap(
        g,
        withPie(
          phaseBadgeRow(g, [
            if (level == NodeZoomLevel.small)
              badgeText('T')
            else
              _exchangeRow(g, itemSize: _facilityItemSize),
            if (hasPending) badgeIcon(Icons.outbox, size: 12),
          ]),
          pie: working
              ? CountdownPie(
                  game: g,
                  endsAt: () => workEndsAt.value,
                  total: duration,
                  isCooldown: false,
                )
              : CountdownPie(
                  game: g,
                  endsAt: () => cooldownEndsAt.value,
                  total: cooldown,
                  isCooldown: true,
                ),
        ),
      );
    },
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('trades '),
    ...quantitiesSpans(takes),
    tipText(' for '),
    ...quantitiesSpans(gives),
    if (duration > 0) tipText('; takes ${fmtSpan(duration)}'),
    if (cooldown > 0) tipText('; then rests ${fmtSpan(cooldown)}'),
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) {
    final pending = pendingOutput.peek();
    if (pending.isNotEmpty) {
      return [
        actionChip(
          enabled: true,
          onTap: () =>
              g.commit(p, CollectAction(this, notBefore: g.actionMoment)),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: badgeGap,
            runSpacing: 2,
            children: [
              badgeIcon(Icons.outbox, size: 12),
              badgeText('collect'),
              for (final q in pending) quantityWidget(q),
            ],
          ),
        ),
      ];
    }
    final chip = actionChip(
      enabled: canTrade(g, p),
      onTap: () => g.commit(p, TradeAction(this, notBefore: g.actionMoment)),
      child: _exchangeRow(g),
    );
    // A chip that's gone dim doesn't say whether the trader is working, or
    // resting, or waiting on something the player hasn't got — and the pies
    // that do say it are out on the map badge, which isn't where a player who
    // has just tapped this is looking. So the chip carries the same pie the
    // badge does: sage while the trade runs, black and counting while the
    // trader rests afterwards. It sits outside the chip's dimming, since its
    // whole job is to be the part that's still alive.
    if (busy) {
      return [
        withPie(
          chip,
          pie: CountdownPie(
            game: g,
            endsAt: () => workEndsAt.value,
            total: duration,
            isCooldown: false,
          ),
        ),
      ];
    }
    if (cooling) {
      return [
        withPie(
          chip,
          pie: CountdownPie(
            game: g,
            endsAt: () => cooldownEndsAt.value,
            total: cooldown,
            isCooldown: true,
          ),
        ),
      ];
    }
    return [chip];
  }
}

class Mugger(final Item item, final MuggerKind kind) extends Facility {
  /// flashes red when it strikes; subscribing to the clock only while it's
  /// flashing keeps idle muggers from rebuilding every frame
  final RedFlash flash = RedFlash();

  bool get _takes => kind != MuggerKind.r;

  @override
  List<Item> get requiredItems => [item];

  @override
  void onPlayerEntered(Game g, Player p) {
    if (!activeNow(g)) return;
    // muggers no longer freeze anyone: they clean you out
    if (!g.playerHas(p, [Quantity(item, 1)])) {
      flash.trigger(g.now);
      if (p.inventory.peek().isNotEmpty) {
        p.inventory.value = const [];
        p.flash.trigger(g.now);
      }
      return;
    }
    // The toll: taken from anyone who has it, including the ones who were
    // never at risk of the robbery. It flashes like the robbery does — an item
    // leaving the inventory with no red anywhere is indistinguishable from a
    // bug, and this is the only way a player loses something without being
    // told about it.
    if (_takes && g.playerHas(p, [Quantity(item, 1)])) {
      g.takeItems(p, [Quantity(item, 1)]);
      flash.trigger(g.now);
      p.flash.trigger(g.now);
    }
  }

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(
    builder: (context) {
      var color = paletteSignal.value.ink;
      if (flash.flashingAt(g.now, g.params.redFlashSpan)) {
        color = Color.lerp(
          paletteSignal.value.ink,
          Colors.red,
          flash.rednessAt(g.clock.value, g.params.redFlashSpan),
        )!;
      }
      return explainTap(
        g,
        phaseBadgeRow(g, [
          badgeIcon(Icons.savings, color: color),
          if (level != NodeZoomLevel.small) ...[
            badgeText(kind.name),
            ItemWidget(item, size: _facilityItemSize),
          ],
        ]),
      );
    },
  );

  @override
  List<InlineSpan> describe(Game g) => switch (kind) {
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

class Storage(
  final int capacity, { // 2..12, log-distributed
  /// secured storages are out of the blight's reach
  final bool secured = false,
}) extends Facility {
  final Signal<List<Item>> contents = signal(const []);

  /// what this store leads with, in the badge and in its control. An [Outbox]
  /// is a storage in every way that the storage flows care about — it's loaded
  /// the same, it rotates with the rest, and the blight reaches into it on the
  /// same terms — so what separates the two on screen is this icon and what
  /// the tooltip says.
  IconData get storeIcon => Icons.inventory_2;

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(
    builder: (context) {
      final c = contents.value;
      return explainTap(
        g,
        phaseBadgeRow(g, [
          badgeIcon(storeIcon),
          if (secured) badgeIcon(Icons.lock, size: 11),
          if (level == NodeZoomLevel.small || c.length > 3)
            badgeText('${c.length}/$capacity')
          else
            for (final it in c) ItemWidget(it, size: _facilityItemSize),
        ]),
      );
    },
  );

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
  List<Widget> actionsFor(Game g, Player p) {
    final stored = contents.peek();
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          badgeIcon(storeIcon),
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
                        ? () => g.commit(
                            p,
                            RotateAction(
                              this,
                              stored[i],
                              notBefore: g.actionMoment,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    ];
  }
}

/// A storage whose contents any [Inbox] on the map can reach into. Everything
/// else about it is a storage: it's loaded from the inventory the same way,
/// rotates with the other stores on its node, and an unsecured one loses its
/// contents to a blight like any other — which stings more here, since what
/// was taken belonged to the whole map rather than to this node.
class Outbox(super.capacity, {super.secured}) extends Storage {
  @override
  IconData get storeIcon => Icons.outbox_rounded;

  @override
  List<InlineSpan> describe(Game g) => [
    tipText(
      secured
          ? 'a secured outbox with $capacity slots — inboxes anywhere on the '
                'map can take from it, and the blight cannot reach in'
          : 'an outbox with $capacity slots — inboxes anywhere on the map can '
                'take from it',
    ),
  ];
}

/// The other end of the outboxes: a place to pull an item out of any one of
/// them, wherever it's standing. There's no network object anywhere — what an
/// inbox offers is walked out of the outboxes each time it's asked, so nothing
/// has to be kept in step and nothing extra goes to disk.
class Inbox({
  /// what a pull demands of the player, if anything. [activationConsumed]
  /// separates the ones that only want to see it from the ones that take it,
  /// as the trains and the muggers do.
  final Quantity? activation,
  final bool activationConsumed = false,
}) extends Facility {
  @override
  List<Item> get requiredItems => [if (activation != null) activation!.item];

  /// Every item the outboxes hold between them, in one list per distinct item
  /// with the outbox each one would come out of. Node order, so the same tap
  /// takes the same item from the same place every time it's replayed.
  List<(Item, int)> available(Game g) {
    final counts = <Item, int>{};
    for (final o in _outboxes(g)) {
      for (final it in o.contents.value) {
        counts[it] = (counts[it] ?? 0) + 1;
      }
    }
    return [for (final e in counts.entries) (e.key, e.value)];
  }

  Iterable<Outbox> _outboxes(Game g) sync* {
    for (final n in g.nodes) {
      for (final o in n.facilities.whereType<Outbox>()) {
        // an outbox that's out of hours isn't in the network while it's shut,
        // the same as it's skipped when a player loads one by hand
        if (o.activeNow(g)) yield o;
      }
    }
  }

  bool _paid(Game g, Player p) =>
      activation == null || g.playerHas(p, [activation!]);

  bool canPull(Game g, Player p) =>
      p.at.value.isSameAs(node) &&
      p.inventory.value.length < g.params.inventoryCap &&
      _paid(g, p);

  /// The price is per item pulled rather than per visit, and it's charged here
  /// rather than when the panel opens — so an inbox nobody can pay at is still
  /// one they can look inside, which is half of what an inbox is for.
  bool pull(Game g, Player p, Item it) {
    if (!canPull(g, p)) return false;
    final from = _outboxes(g)
        .firstWhereOrNull((o) => o.contents.value.contains(it));
    if (from == null) return false;
    if (activation != null && activationConsumed) g.takeItems(p, [activation!]);
    final c = [...from.contents.value];
    c.remove(it);
    from.contents.value = c;
    p.inventory.value = [...p.inventory.value, it];
    return true;
  }

  /// A tray with an arrow coming down into it. Material's own move_to_inbox is
  /// a tray with an arrow inside it, which at the size a badge draws at is the
  /// same handful of pixels as the outbox's tray — and the two of them are the
  /// pair that most needs telling apart. Stacking the arrow above the tray
  /// puts the difference in the silhouette instead of in the detail.
  static Widget _mark({double size = 13}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      badgeIcon(Icons.arrow_downward_rounded, size: size * 0.62),
      badgeIcon(Icons.inbox, size: size),
    ],
  );

  Widget _costRow({double itemSize = 13}) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: badgeGap,
    children: [
      _mark(),
      if (activation != null) ...[
        badgeText(activationConsumed ? 'c' : 'r'),
        quantityWidget(activation!, size: itemSize),
      ],
    ],
  );

  @override
  Widget badge(Game g, NodeZoomLevel level) => explainTap(
    g,
    phaseBadgeRow(g, [
      if (level == NodeZoomLevel.small)
        _mark()
      else
        _costRow(itemSize: _facilityItemSize),
    ]),
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('an inbox — takes an item out of any outbox on the map'),
    if (activation != null) ...[
      tipText(activationConsumed ? '; each pull costs ' : '; demands to see '),
      ...quantitiesSpans([activation!]),
    ],
  ];

  /// Like a storage's control with the loading taken out: the slots are what
  /// the outboxes are holding, and tapping one brings it here.
  @override
  List<Widget> actionsFor(Game g, Player p) {
    final offer = available(g);
    final enabled = canPull(g, p);
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _costRow(),
          const SizedBox(width: 3),
          if (offer.isEmpty)
            badgeText('every outbox is empty')
          else
            Flexible(
              child: Opacity(
                opacity: enabled ? 1 : 0.35,
                child: Wrap(
                  spacing: 3,
                  runSpacing: 3,
                  children: [
                    for (final (it, n) in offer)
                      slotBox(
                        item: it,
                        count: n,
                        onTap: enabled
                            ? () => g.commit(
                                p,
                                PullAction(this, it, notBefore: g.actionMoment),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ];
  }
}

/// Somewhere a [JumpStation] can send a player. Inert on its own: it has no
/// action, and its whole function is being a place another node can reach.
class LandingStation extends Facility {
  @override
  Widget badge(Game g, NodeZoomLevel level) =>
      explainTap(g, phaseBadgeRow(g, [badgeIcon(Icons.flight_land)]));

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('a landing station — jump stations can send someone here'),
  ];
}

/// Sends a player across the map in no time at all: to a [LandingStation], or
/// anywhere at all if it's free-aim, which is dear enough that it always costs
/// something. The cooldown is the station's rather than the traveller's — it
/// recharges once for everybody — and it's an arbitrary interval, since it
/// runs from whenever it was last used rather than from a time of day.
class JumpStation({
  final bool freeAim = false,
  final Quantity? cost, // taken on the jump, not on aiming
  final TTime cooldown = 0, // 0 = none
}) extends Facility {
  final Signal<TTime?> cooldownEndsAt = signal(null);

  @override
  List<Item> get requiredItems => [if (cost != null) cost!.item];

  bool get cooling => cooldownEndsAt.value != null;

  @override
  bool get everSchedules => true;

  @override
  TTime? nextEventAt(Game g) => cooldownEndsAt.value;

  @override
  void fire(Game g) => cooldownEndsAt.value = null;

  bool canJump(Game g, Player p) =>
      p.at.value.isSameAs(node) &&
      !cooling &&
      (cost == null || g.playerHas(p, [cost!]));

  /// Where this station will send someone. Never the node they're already
  /// standing on; a free-aim station will send them to any node at all, trains
  /// and their stations included — a train is a node like any other, and
  /// landing on one is the same as stepping aboard from its gangway.
  bool isTarget(Node n, Player p) {
    if (n.isSameAs(node) || n.isSameAs(p.at.value)) return false;
    return freeAim || n.facilities.any((f) => f is LandingStation);
  }

  bool jump(Game g, Player p, Node to) {
    if (!canJump(g, p) || !isTarget(to, p)) return false;
    if (cost != null) g.takeItems(p, [cost!]);
    if (cooldown > 0) cooldownEndsAt.value = g.now + cooldown;
    g.teleport(p, to);
    return true;
  }

  Widget _row({double itemSize = 13}) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: badgeGap,
    children: [
      badgeIcon(Icons.flight_rounded),
      if (freeAim) badgeIcon(Icons.public, size: 11),
      if (cost != null) quantityWidget(cost!, size: itemSize),
    ],
  );

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(
    builder: (context) => explainTap(
      g,
      withPie(
        phaseBadgeRow(g, [
          if (level == NodeZoomLevel.small)
            badgeIcon(Icons.flight_rounded)
          else
            _row(itemSize: _facilityItemSize),
        ]),
        pie: CountdownPie(
          game: g,
          endsAt: () => cooldownEndsAt.value,
          total: cooldown,
          isCooldown: true,
        ),
      ),
    ),
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText(
      freeAim
          ? 'a jump station — sends one person to any node on the map'
          : 'a jump station — sends one person to any landing station',
    ),
    if (cost != null) ...[
      tipText('; costs '),
      ...quantitiesSpans([cost!]),
    ],
    if (cooldown > 0) tipText('; then rests ${fmtSpan(cooldown)}'),
  ];

  @override
  List<Widget> actionsFor(Game g, Player p) {
    final aiming = g.jumping.peek()?.$1.isSameAs(this) ?? false;
    final chip = actionChip(
      enabled: aiming || canJump(g, p),
      onTap: () => aiming ? g.cancelJump() : g.startJump(this, p),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: badgeGap,
        runSpacing: 2,
        children: [
          _row(),
          badgeText(
            aiming
                ? (freeAim
                      ? 'click which node on the map you want to jump to'
                      : 'click a landing station on the map')
                : 'jump',
          ),
        ],
      ),
    );
    // the same pie the badge carries, for the same reason the trader's chip
    // carries one: a chip that's gone dim doesn't say why
    if (!cooling) return [chip];
    return [
      withPie(
        chip,
        pie: CountdownPie(
          game: g,
          endsAt: () => cooldownEndsAt.value,
          total: cooldown,
          isCooldown: true,
        ),
      ),
    ];
  }
}

/// A wide nocturnal wave that strips everything loose inside its radius —
/// items carried by players and anything sitting in unsecured storage. Plants
/// keep their fruit. Most blights can be bought off with a particular item;
/// hungry ones ('R') want another one every cycle.
class Blight({
  required final double radius,
  required final ClockInterval interval, // one to three days, firing at night
  required final Item? mitigator, // null when nothing placates it
  required final bool hungry, // wants feeding again after every wave
}) extends Facility {
  final Signal<bool> satiated = signal(false);

  @override
  List<Item> get requiredItems => [if (mitigator != null) mitigator!];

  @override
  bool get isHazard => true;

  final RedFlash flash = RedFlash();

  @override
  ClockInterval? get clockSchedule => interval;

  /// once a non-hungry blight has been fed it's done, so it stops counting
  bool get dormant => satiated.value && !hungry;

  /// when the next wave lands, or null if it's been put down for good.
  ///
  /// Worked out from the clock rather than counted towards, and no record is
  /// kept of which cycle last went off — which is what makes the wave survive
  /// the clock being moved. Winding back past a wave doesn't have to un-fire
  /// it; the question "when does this next fire after now" simply answers
  /// differently, and the wave happens again on the way forward.
  TTime? nextWaveAt(Game g) => dormant ? null : interval.nextAfter(g.now);

  @override
  bool get everSchedules => true;

  @override
  TTime? nextEventAt(Game g) => nextWaveAt(g);

  @override
  void fire(Game g) {
    if (satiated.value) {
      // a hungry blight is only bought off for the one cycle
      if (hungry) satiated.value = false;
      return;
    }
    flash.trigger(g.now);
    bool within(Offset o) => (o - node.pos).distance <= radius;
    final struck = <Player>[];
    for (final p in g.players) {
      if (!within(p.worldPos(g.now))) continue;
      p.inventory.value = const [];
      p.flash.trigger(g.now);
      struck.add(p);
    }
    for (final n in g.nodes) {
      if (!within(n.pos)) continue;
      for (final s in n.facilities.whereType<Storage>()) {
        if (!s.secured) s.contents.value = const [];
      }
    }
    // MUGGED and BLIGHTSTRUCK used to be announced here. Taken out rather
    // than fixed: the announcement was written for a world where time only
    // went forwards, and it has no answer for being replayed, wound past, or
    // raised for something that hasn't happened yet. The red flashes still
    // say it happened, and they're worked out from the clock so they say it
    // at the right moments. See [RedFlash] and [Game.announce], which the
    // divergence alert still uses.
  }

  bool canFeed(Game g, Player p) =>
      mitigator != null &&
      !satiated.value &&
      g.playerHas(p, [Quantity(mitigator!, 1)]);

  bool feed(Game g, Player p) {
    if (!canFeed(g, p)) return false;
    g.takeItems(p, [Quantity(mitigator!, 1)]);
    satiated.value = true;
    return true;
  }

  @override
  Widget badge(Game g, NodeZoomLevel level) => SignalBuilder(
    builder: (context) {
      var color = paletteSignal.value.ink;
      if (flash.flashingAt(g.now, g.params.redFlashSpan)) {
        color = Color.lerp(
          paletteSignal.value.ink,
          Colors.red,
          flash.rednessAt(g.clock.value, g.params.redFlashSpan),
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
                  child: ItemWidget(mitigator!, size: _facilityItemSize),
                ),
            ],
          ]),
          // a placated blight that wants nothing more stops counting down
          pie: dormant
              ? const SizedBox.shrink()
              : CountdownPie(
                  game: g,
                  endsAt: () => nextWaveAt(g),
                  total: interval.period,
                  isCooldown: true,
                  clock: interval,
                ),
        ),
      );
    },
  );

  @override
  List<InlineSpan> describe(Game g) => [
    tipText('a blight — '),
    ...describeClockSpans(interval),
    tipText(
      ' it strips every loose item within ${fmt1(radius)} units, from players '
      'and unsecured storage alike',
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
    final fed = satiated.peek();
    return [
      actionChip(
        enabled: !fed && canFeed(g, p),
        onTap: () => g.commit(p, FeedAction(this, notBefore: g.actionMoment)),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: badgeGap,
          runSpacing: 2,
          children: [
            badgeIcon(Icons.dangerous, size: 12),
            badgeText(fed ? 'sated' : 'appease'),
            ItemWidget(mitigator!, size: 13),
          ],
        ),
      ),
    ];
  }
}

// ────────────────────────────── game ──────────────────────────────

class Game({
  required final Parameters params,
  required final ItemCatalog catalog,
  required final List<Node> nodes, // includes TrainNodes
  required final List<Edge> edges,
  required final List<Player> players,
  required final List<TrainNode> trains,
}) {
  /// The clock, in ticks since the level began; ALL deadlines are moments on
  /// it. [advanceTo] moves it, and it moves in game time, never real time —
  /// the ticker converts before it gets here.
  TTime now = 0;

  /// [now] mirrored as a signal, for the things that animate off it reactively
  /// (countdown pies, the red pulses); most rendering rides the frame notifier
  final Signal<TTime> clock = signal(0);
  final Signal<int> eudaimonia = signal(0);

  /// Whether the clock only moves when the player moves it — by doing
  /// something, or by turning the dial. A level starts this way now: with two
  /// characters to run and a clock that can be wound, time running on its own
  /// while you think is the thing the whole feature exists to stop. The play
  /// button is still there for watching a stretch go by.
  final Signal<bool> paused = signal(true);
  late final Signal<Player> selectedPlayer;
  final Signal<GamePhase> phase = signal(GamePhase.playing);

  /// Day occupies the first half of each day, night the second. It goes by
  /// unremarked — nothing about the world changes as it turns — and is here
  /// for the two things that still read the half of the day they're in: a
  /// clock face's AM/PM colouring, and an [ActivePhase]-restricted facility.
  final Signal<bool> isNight = signal(false);

  /// How far the view is allowed to zoom, in logical pixels per world unit.
  /// They depend on the viewport, so the map view writes them every layout;
  /// they live here rather than there because the zoom range is what the
  /// overgraph fade is measured against, and that's read from elsewhere too.
  /// Placeholders until the first layout.
  double zoomMin = 1, zoomMax = 1;

  /// the big transient caps message: MUGGED, BLIGHTSTRUCK… along with whoever
  /// it happened to, who is shown beside it
  final Signal<(String text, List<Player> who, TTime at)?> announcement =
      signal(null);

  /// every blight in the level, for painting their radii
  late final List<Blight> blights;

  TTime get timeOfDay => now % gameDay;

  /// Derived, not counted down: the level's whole span less how much of it has
  /// gone. One less thing to put back when the clock moves.
  TTime get timeLeft => max(0, params.globalTime - now);
  int get daysRemaining => timeLeft ~/ gameDay;

  /// [who] it happened to is part of the message, not decoration: the camera is
  /// rarely on every player at once, and a bare MUGGED with the victim off
  /// screen is sheer confusion. Two players struck by the same thing while the
  /// message is still up merge into one announcement rather than one silently
  /// overwriting the other.
  void announce(String text, {List<Player> who = const []}) {
    final prev = announcement.value;
    final all =
        (prev != null &&
            prev.$1 == text &&
            now - prev.$3 <= params.announcementSpan)
        ? [...prev.$2, ...who.where((p) => !prev.$2.any((q) => p.isSameAs(q)))]
        : who;
    announcement.value = (text, all, now);
  }

  /// the current explanation tooltip: the facility (or train) that was tapped,
  /// which node it's anchored to, and its spans
  /// [Identified] rather than Object: what gets tapped is always a facility or
  /// a train, and typing it that way is what lets [same] decide whether the
  /// tooltip already open is this one's
  final Signal<(Identified source, Node at, List<InlineSpan> spans)?> tooltip =
      signal(null);

  /// The jump station currently aiming, and who it's aiming for. While this is
  /// set the map is in targeting mode: the legal targets keep their colour and
  /// the rest of the graph washes out, and the next tap on the world either
  /// lands the jump or backs out of it.
  final Signal<(JumpStation, Player)?> jumping = signal(null);

  void startJump(JumpStation s, Player p) {
    if (!s.canJump(this, p)) return;
    tooltip.value = null;
    jumping.value = (s, p);
  }

  void cancelJump() => jumping.value = null;

  /// Bumped when the followed player has been put somewhere they didn't walk
  /// to. The map view drops the user's pan and seeks them again; see
  /// [teleport]. A counter rather than a flag, so two of them in a row are two
  /// requests, and it's [peek]ed rather than watched — the view is looking at
  /// it every frame anyway.
  final Signal<int> recenterWanted = signal(0);

  /// Takes the tap on [n] as the target, if it's a legal one. Returns whether
  /// it was: an illegal target is a tap on the map like any other, and the
  /// caller backs out of aiming.
  bool tryJumpTo(Node n) {
    final j = jumping.value;
    if (j == null) return false;
    final (station, p) = j;
    if (!station.isTarget(n, p)) return false;
    jumping.value = null;
    commit(p, JumpAction(station, n, notBefore: actionMoment));
    return true;
  }

  /// tapping the facility whose tooltip is showing closes it again — unless a
  /// jump is being aimed, in which case a tap on a facility is a tap on the
  /// node it's standing on, and the badges are the easiest thing on the map to
  /// hit
  void toggleTooltip(
    Identified source,
    Node at,
    List<InlineSpan> Function() spans,
  ) {
    if (tryJumpTo(at)) return;
    raiseNode(at);
    final cur = tooltip.value;
    tooltip.value = cur != null && cur.$1.isSameAs(source)
        ? null
        : (source, at, spans());
  }

  int _stackTop = 0;

  /// Lifts a node's overlay above every other node's, and leaves it there: a
  /// node the player has just touched or walked into is a node whose badges
  /// they want to keep reading, and dropping it back under its neighbours the
  /// moment the tooltip closes or the player leaves would undo that mid-glance.
  void raiseNode(Node n) {
    if (probing) return; // the pile order is not the probe's business
    n.stackRank = ++_stackTop;
  }

  this {
    selectedPlayer = signal(players.first);
    blights = [for (final n in nodes) ...n.facilities.whereType<Blight>()];
    // Numbering everything in a level, in one sequence. One sequence and not
    // three so that a node's number can't collide with a facility's — see
    // [Identified] — and in this order because it's the order the level is
    // written down in, which is what makes the numbers come back the same when
    // a save is read.
    var next = 0;
    for (final p in players) {
      p.id = next++;
    }
    for (final n in nodes) {
      n.id = next++;
      for (final f in n.facilities) {
        f.id = next++;
      }
    }
    _scheduled = [
      for (final n in nodes)
        for (final f in n.facilities)
          if (f.everSchedules) f,
    ];
    markOrigin();
  }

  /// Takes the world as it stands to be as far back as the clock goes.
  ///
  /// Whoever finishes building a level calls this, and it has to be the last
  /// thing they do: a [Game] is constructed before its world is finished —
  /// [generateLevel] docks the trains afterwards, and [LevelType] fills in
  /// almost everything afterwards — so an origin taken any earlier is a clock
  /// reading of zero attached to a world that was never in that state. The
  /// constructor takes one anyway, so that the field is never unset, but it
  /// expects to be overruled.
  void markOrigin() {
    _snapshots.clear();
    _origin = captureState(this);
  }

  /// The facilities the event loop has to ask, flattened once: two thirds of a
  /// level is storage, muggers and stations, which never act on their own (see
  /// [Facility.everSchedules]), and walking the node graph to ask each of them
  /// a question whose answer is always null is work for nothing.
  ///
  /// Worth measuring before believing, and it was: skipping them takes about a
  /// tenth off a replay. The scan was never where the time went — a replay
  /// spends essentially all of it inside the handlers, in the signal writes
  /// and list churn of players arriving and leaving — so this is a tidy-up,
  /// not the thing that makes replaying affordable. What makes it affordable
  /// is not replaying much: the cost tracks the number of player moves being
  /// played back, which is what a snapshot is there to bound.
  late final List<Facility> _scheduled;

  /// Guards the one thing that could go quietly wrong about the list above: a
  /// facility that reports an event but forgot to say it ever would, which
  /// would be an event that never fires and a level that stops halfway. In
  /// debug only — it's the whole sweep that the list exists to avoid.
  bool _noneSkippedAreWaiting() {
    for (final n in nodes) {
      for (final f in n.facilities) {
        if (!f.everSchedules && f.nextEventAt(this) != null) return false;
      }
    }
    return true;
  }

  /// Where the ordering of two events landing on the same tick is decided.
  ///
  /// Kind comes first, and it's the same rule read twice: a player is
  /// *somewhere* from the tick they land on it up to and including the tick
  /// they leave it. So arrivals go first, then everything that acts on who's
  /// standing where, then departures. Two consequences worth knowing, both
  /// deliberate: someone who walks into a node at the exact tick a blight
  /// fires is caught by it, and someone who steps onto a train's gangway at
  /// the exact tick it was going to leave gets aboard and holds it up.
  ///
  /// [Thing.id] and [Facility.id] settle what's left. They're positions in
  /// lists that go to disk in order, so the same two events break the same way
  /// every time this stretch of the level is played out — which they have to,
  /// because it gets played out again every time the clock is moved back.
  static const int _rankArrive = 0;
  static const int _rankAct = 1;
  static const int _rankDepart = 2;

  /// Runs the world forward to [t], stopping at each thing that happens on the
  /// way so that it happens at its own moment rather than at the end of a step.
  ///
  /// This is the whole reason the simulation can be re-run. Nothing here is a
  /// function of how the clock was cut up: [t] is arrived at through exactly
  /// the events that lie between here and there, in exactly one order, whether
  /// it's one frame away or two days. `advanceTo(x)` then `advanceTo(y)` leaves
  /// the world where `advanceTo(y)` alone would have.
  ///
  /// It only ever goes forward. Going back is re-running from an earlier state,
  /// which is a different operation and doesn't live here.
  void advanceTo(TTime t) {
    assert(t >= now, 'advanceTo only goes forward; rewinding re-simulates');
    assert(_noneSkippedAreWaiting(), 'a facility schedules without saying so');
    while (true) {
      // the earliest pending event no later than t, and who owns it
      TTime? bestAt;
      var bestRank = 0, bestId = 0;
      Object? best;
      void consider(Object owner, TTime? at, int rank, int id) {
        if (at == null || at > t) return;
        if (bestAt == null ||
            at < bestAt! ||
            (at == bestAt! &&
                (rank < bestRank || (rank == bestRank && id < bestId)))) {
          bestAt = at;
          bestRank = rank;
          bestId = id;
          best = owner;
        }
      }

      for (final p in players) {
        consider(
          p,
          p.nextEventAt(this),
          p.nextIsArrival ? _rankArrive : _rankDepart,
          p.id,
        );
      }
      for (final tr in trains) {
        consider(
          tr,
          tr.nextEventAt(this),
          tr.nextIsArrival ? _rankArrive : _rankDepart,
          // trains and players only ever share a rank, never an id space that
          // means anything across kinds; a train's node index is as stable as
          // a player's list index, which is all the tie-break needs
          tr.id,
        );
      }
      for (final f in _scheduled) {
        consider(f, f.nextEventAt(this), _rankAct, f.id);
      }

      if (best == null) break;
      now = bestAt!;
      clock.value = now;
      switch (best!) {
        case Player p:
          p.fire(this);
        case TrainNode tr:
          tr.fire(this);
        case Facility f:
          f.fire(this);
      }
      // a replay that came out differently stops the world where it noticed,
      // rather than at the moment it was asked for — see [runNextAction]
      if (_halted) {
        _halted = false;
        headingFor = null;
        _settle();
        return;
      }
    }
    now = t;
    clock.value = now;
    _settle();
  }

  /// Puts the world back to [t] and plays it forward again from there.
  ///
  /// The only way back. There is no undo anywhere in this game: going back is
  /// finding a state from before [t], putting it in place, and re-running the
  /// scripts over it. Which is why nothing in [advanceTo] has to know how to
  /// reverse itself, and why a facility can be written without a thought for
  /// the clock — see [Facility.fire].
  ///
  /// The scripts themselves are untouched. Winding back doesn't unmake
  /// anyone's decisions; it only unmakes their having happened yet.
  void rewindTo(TTime t) {
    final to = max(t, earliestMoment);
    if (to >= now) {
      advanceTo(to);
      return;
    }
    final from = _snapshots.lastWhereOrNull((s) => s.at <= to) ?? _origin;
    restoreState(this, from);
    advanceTo(to);
  }

  /// How far back the clock can go. Zero for a level being played from the
  /// start, and where it was put down for one picked up off disk: a save
  /// carries the world as it stood and everyone's history, but not the ladder
  /// of moments in between, so there's nothing to wind back *through*.
  TTime get earliestMoment => _origin.at;

  /// The state the level began in, and a ladder of moments since, so that
  /// going back is a short replay rather than the whole level again. Kept at
  /// [_snapshotEvery]; a couple of hundred fields each, so a level's worth of
  /// them is a rounding error — see [GameSnapshot].
  late GameSnapshot _origin;
  final List<GameSnapshot> _snapshots = [];
  static const TTime _snapshotEvery = 30 * gameMinute;

  /// Takes one down if the clock has moved far enough since the last, and
  /// drops any that the clock has since gone back past — those describe a
  /// future that has been replaced.
  void _keepSnapshots() {
    while (_snapshots.isNotEmpty && _snapshots.last.at > now) {
      _snapshots.removeLast();
    }
    final lastAt = _snapshots.isEmpty ? 0 : _snapshots.last.at;
    if (now - lastAt >= _snapshotEvery) _snapshots.add(captureState(this));
  }

  // ── doing things ──

  /// Writes [a] down as something [p] has decided to do, and starts the clock
  /// running until it's been done.
  ///
  /// Anything that player was going to do after this moment is dropped: the
  /// clock has been wound back and a different decision made, and what came
  /// after was a plan for a world that isn't going to happen now. Only *that*
  /// player's tail goes — everyone else's stands, which is the point of the
  /// whole arrangement. You wind back to before your second character moved so
  /// that you can move them, and your first character walks their walk again
  /// around you.
  ///
  /// One further thing happens here: an action lands on a tick of its own.
  /// [actionMoment] is the next tick and the clock doesn't move while a tap is
  /// being read, so three taps in a row would otherwise all be down for the
  /// same instant, and the event loop would run all three of one player's
  /// before it looked at anyone else — two players queueing at the same
  /// standstill would come out grouped rather than taking turns. A tick each
  /// is what makes the order they were decided the order they happen in.
  void commit(Player p, PlayerAction a) {
    p.script.truncateReplayed();
    final last = p.script.actions.lastOrNull;
    if (last != null && a.notBefore <= last.notBefore) {
      a.notBefore = last.notBefore + 1;
    }
    p.script.actions.add(a);
    playUntilIdle(p);
  }

  /// The moment an action decided on now belongs to: the next tick, not this
  /// one.
  ///
  /// A tick is 1/16384 of a game second and nobody will ever see the
  /// difference, but it buys a property worth having — **for every action
  /// there is a moment at which it hasn't happened yet**. Give it this instant
  /// instead and it's welded to it: [advanceTo] runs everything due at or
  /// before the moment it's asked for, so winding back to the instant of an
  /// action replays it, and there's nowhere to stand and watch the world as it
  /// was just before. For the first action of a level that's fatal, because
  /// there is no earlier moment to wind back to at all.
  ///
  /// It also makes an instant action move the clock, which is what carries it
  /// out. Picking a tree takes no time, so a plan to be done by now is a plan
  /// the ticker has no journey to make for, and it would sit there until
  /// something else happened to move time.
  TTime get actionMoment => now + 1;

  /// Carries out whatever [p] is up to next, and decides whether it came out
  /// the way it did the first time.
  ///
  /// The first run is the record. Every run after that is measured against it,
  /// and a run that doesn't match — because the container was emptied, or the
  /// train had gone, or someone took the thing they were coming for — stops
  /// that player where they stand and says so. It stops the clock too: the
  /// entire premise of replaying somebody is that nobody is watching them, so
  /// a quiet note in the corner would be found three game-hours later.
  void runNextAction(Player p) {
    final a = p.script.next;
    if (a == null) return;
    final got = a.perform(this, p);
    // A probe is a question, not a turn. It runs the world forward to see what
    // things will look like and is thrown away immediately afterwards — so it
    // must not write anything a snapshot won't put back. Recording an outcome,
    // dropping an action, raising an alert and stopping the clock are all
    // exactly that: they change the history rather than the world, and the
    // history is what the replay is made of. See [probing].
    if (probing) {
      p.script.done++;
      return;
    }
    final was = a.recorded;
    if (was == null) {
      if (got == null) {
        // it couldn't be done even the first time; it never happened, so it
        // doesn't go in the history
        p.script.actions.removeAt(p.script.done);
        return;
      }
      a.recorded = got;
    } else if (got == null || !got.matches(was)) {
      p.script.truncate();
      _halted = true;
      announce("${a.name.toUpperCase()} DIDN'T WORK", who: [p]);
      // whoever it happened to is almost certainly off screen, since not
      // watching them is why they were being replayed
      selectedPlayer.value = p;
      recenterWanted.value++;
      return;
    }
    a.ranAt = now;
    a.ranUntil = p.traversing != null ? p.arrivesAt : now;
    p.script.done++;
  }

  /// Set when a replay came out differently; [advanceTo] notices and stops
  /// there rather than carrying on to the moment it was asked for.
  bool _halted = false;

  /// Whether the world is being run forward to be *looked at* rather than
  /// played. Everything that would outlive a [restoreState] checks this and
  /// holds off: see [runNextAction], [raiseNode], [teleport], [_settle].
  bool probing = false;

  /// When [p] runs out of things to do — the end of their history, and where
  /// tapping the clock takes them. [now] if there's nothing left.
  ///
  /// Walked out rather than guessed at. Walking is the only thing on a script
  /// that takes any time, wires don't change length, and where each step
  /// leaves them is what says which wire the next step is along — so following
  /// the chain gives the real answer rather than an estimate. It can still be
  /// wrong, but only by being optimistic in the one way the whole feature is
  /// about: if a wire isn't there when they get to it, they'll stop early and
  /// be told.
  TTime frontierOf(Player p) => frontier(p).$1;

  /// Where [p] will be standing once their list runs out — which is the node
  /// the next thing they're told to do has to make sense from. A drag on the
  /// move pad while they're already walking means "and then from there", so
  /// this is what the drag is resolved against.
  Node? frontierNodeOf(Player p) => frontier(p).$2;

  /// When and where the next thing [p] is told to do would actually take
  /// effect — which is the moment the controls should be describing, because
  /// showing someone a world they'll have walked away from by the time their
  /// tap lands is showing them the wrong world.
  ///
  /// Not the same as [frontierOf], and the difference is the point. Anything
  /// on the list that has already been played once is replay material, and
  /// deciding to do something else is what replaces it — see
  /// [PlayerScript.truncateReplayed] — so it isn't in the way. What *is* in
  /// the way is the walk already under way, which can't be called back, and
  /// anything queued behind it that hasn't happened yet.
  (TTime, Node?) actionTimeFor(Player p) => frontier(p, onlyUnplayed: true);

  /// When the one thing [p] is in the middle of, or about to start, is done.
  ///
  /// A walk already under way is the thing in hand and nothing on the list is,
  /// so that's the answer; otherwise it's the next item and only the next
  /// item. This is what tapping the clock runs to — one thing at a time, tap
  /// again for the one after — where [frontierOf] is the whole list and is
  /// what the dial's bands are drawn from.
  TTime nextActionEndsAt(Player p) =>
      p.traversing != null ? max(now, p.arrivesAt) : frontier(p, take: 1).$1;

  /// The far end of the last thing [p] has been told to do, whichever side of
  /// the clock it falls on. [earliestMoment] for somebody who has never done
  /// anything: they have been standing about since the level opened, so the
  /// moment their story runs out is the moment it started.
  ///
  /// [frontierOf] only ever looks forward, so a player who ran out of things
  /// to do an hour ago comes back as [now] — true, and useless for finding
  /// them. This one goes back for them, off the record of when their last
  /// action went; see [PlayerAction.ranAt].
  TTime storyEndOf(Player p) {
    if (p.script.done < p.script.actions.length) return frontierOf(p);
    for (var i = p.script.done - 1; i >= 0; i--) {
      final a = p.script.actions[i];
      final ran = a.ranUntil ?? a.ranAt;
      // an action off a save carries no record of when it went, and there's
      // no winding back past the save anyway — which is where this lands
      if (ran != null) return ran;
    }
    return earliestMoment;
  }

  (TTime, Node?) frontier(Player p, {bool onlyUnplayed = false, int? take}) =>
      walkPlan(p, onlyUnplayed: onlyUnplayed, take: take);

  /// Plays [p]'s list out on paper: every action still ahead of the cursor,
  /// handed to [each] with the stretch of clock it would take up and where it
  /// leaves them. Returns where the whole list runs out, which is [frontier].
  ///
  /// The one place the shape of a plan is worked out, because the frontier and
  /// [SyntheticClock] have to agree: one is where tapping the clock lands, the
  /// other is the picture of it you tapped.
  ///
  /// Optimistic in the way the whole feature is: it assumes every wire is
  /// where it was and nobody gets mugged on the way. If that turns out to be
  /// wrong the player stops early and is told — see [runNextAction].
  (TTime, Node?) walkPlan(
    Player p, {
    bool onlyUnplayed = false,
    int? take,
    void Function(PlayerAction a, TTime from, TTime to, Node? at)? each,
  }) {
    var t = now;
    var here = p.at.peek();
    if (p.traversing != null) {
      t = max(t, p.arrivesAt);
      here = p.traversalTarget;
    }
    // Nothing happens while they're flat on their back, which the event loop
    // folds into the time rather than treating as an event — see
    // [Player.nextEventAt] — so the plan has to fold it in the same way, or it
    // says "now" for something that can't be done until they come round, and
    // says it again next frame.
    final coming = p.incapacitatedUntil.peek();
    if (coming != null) t = max(t, coming);
    for (var i = p.script.done; i < p.script.actions.length; i++) {
      if (take != null && i - p.script.done >= take) break;
      final a = p.script.actions[i];
      if (onlyUnplayed && a.recorded != null) break;
      final from = max(t, a.notBefore);
      t = from;
      switch (a) {
        case MoveAction m:
          final was = here;
          if (was != null) {
            final e = was.edges.firstWhereOrNull(
              (x) => x.other(was).isSameAs(m.to),
            );
            if (e != null) {
              t += max(1, ticksOf(e.length / params.playerSpeed));
            }
          }
          here = m.to;
        case JumpAction j:
          here = j.to;
        default:
          break; // everything else is done the moment it's begun
      }
      each?.call(a, from, t, here);
    }
    return (t, here);
  }

  /// What the controls should be showing.
  ///
  /// Not the world as it is — the world as it will be when the next thing the
  /// player taps would actually happen. Someone halfway along a wire is about
  /// to be somewhere else, and offering them the tree they're walking away
  /// from is offering them a tap that will miss.
  ///
  /// Read by running the world forward to that moment, taking down what the
  /// controls need, and putting it straight back. Which is why it's here and
  /// not in a widget: restoring writes a couple of hundred signals, and doing
  /// that from inside a build is dirtying widgets in the middle of building
  /// them. The ticker is where writing to the world already belongs.
  ///
  /// The widgets it comes back with are ordinary ones, built and frozen at the
  /// moment they were read. That's why nothing under [Facility.actionsFor]
  /// subscribes to a signal any more — a control that re-read the world for
  /// itself would quietly go back to describing now.
  PanelView readControls() {
    final p = selectedPlayer.peek();
    final (at, _) = actionTimeFor(p);
    if (at <= now) return _controlsHere(p);
    final held = captureState(this);
    final was = _outsideTheSnapshot();
    probing = true;
    advanceTo(at);
    final v = _controlsHere(p);
    probing = false;
    restoreState(this, held);
    assert(
      _outsideTheSnapshot() == was,
      'a probe changed something a snapshot does not put back — see [probing]',
    );
    return v;
  }

  /// A fingerprint of the state that [restoreState] would *not* undo: the
  /// histories, and the odds and ends that belong to the person playing rather
  /// than to the world.
  ///
  /// This is what keeps [probing] honest. Guarding each of those writes by
  /// hand is a standing obligation on everyone who adds one, and an obligation
  /// nobody is reminded of is one that gets forgotten — the symptom being a
  /// plan quietly truncated, or an alert for something that hasn't happened,
  /// by the mere act of looking at the future. Debug only; it's a few thousand
  /// integers at the end of a long level.
  int _outsideTheSnapshot() {
    var h = _stackTop * 31 + recenterWanted.peek();
    for (final p in players) {
      h = h * 31 + p.script.actions.length;
      for (final a in p.script.actions) {
        h = h * 31 + (a.recorded == null ? 0 : 1);
        h = h * 31 + a.notBefore + (a.ranAt ?? 0);
      }
    }
    return h;
  }

  PanelView _controlsHere(Player p) {
    final node = p.at.peek();
    return PanelView(
      at: now,
      node: node,
      inventory: p.inventory.peek(),
      canMove: !p.incapacitatedAt(now),
      hasStorage:
          node != null &&
          node.facilities.any((f) => f is Storage && f.activeNow(this)),
      actions: [
        if (node != null) ...[
          // a facility that's out of hours offers nothing
          for (final f in node.facilities)
            if (f.activeNow(this)) ...f.actionsFor(this, p),
          if (node is TrainNode && node.movableFromInside)
            DragDirectionPad(
              dimension: 64,
              enabled:
                  node.dockedAt.peek() != null &&
                  node.manualAllowed &&
                  !node.dockEdgeBusy(this) &&
                  (node.activation == null || playerHas(p, [node.activation!])),
              onAngle: (a) => dragTrainMove(node, p, a),
              label: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  badgeIcon(Icons.train),
                  badgeIcon(Icons.swipe_right_alt),
                ],
              ),
            ),
        ],
      ],
    );
  }

  // ── playback ──
  //
  // The clock never jumps to where it's been asked for; it travels there, on a
  // spring, so that a walk is watched rather than reported. Every way of
  // moving time — an action playing out, the dial being turned, plain unpaused
  // play — is the same one mechanism: name a moment and say why, and the
  // ticker carries the world to it.

  /// whether a finger is on the dial, which stops free-running play from
  /// arguing with it — see [TimeDial]
  bool dialHeld = false;

  /// where the clock is headed, or null when it's arrived and stopped
  TTime? headingFor;
  ClockPush _push = ClockPush.ease;

  /// The clock as it's being shown, which is not [now]: a real number of
  /// ticks, carrying a velocity, so that it can be sprung towards a
  /// destination instead of cutting to it. Each frame it's rounded and the
  /// world is taken to that moment. See [ClockPush].
  double _shown = 0, _shownVelocity = 0;

  /// where the clock has sprung to, and how fast it's going — in ticks and in
  /// ticks per real second
  double get shownClock => _shown;
  double get clockVelocity => _shownVelocity;

  /// Sets the clock travelling to [t], with [why] deciding how eagerly.
  ///
  /// Deliberately touches nothing but the destination. A clock already on its
  /// way somewhere and told to go somewhere else carries on from where it is
  /// at the speed it was going — the spring re-solves from the position and
  /// velocity it already has, so redirecting mid-flight bends the movement
  /// instead of restarting it. Changing [why] at the same time changes how
  /// hard it's pulled, which is a change of acceleration; the hand itself
  /// neither jumps nor stops.
  void headFor(TTime t, ClockPush why) {
    headingFor = max(t, earliestMoment);
    _push = why;
  }

  /// runs the clock until [p] has nothing left on their list. [frontierOf] is
  /// exact — walking is the only thing that takes any time and wires don't
  /// change length — so this is a moment, not a condition to keep testing.
  void playUntilIdle(Player p) => headFor(frontierOf(p), ClockPush.ease);

  /// Turns to [p] — and takes the clock with them, to the end of *their* last
  /// action rather than leaving it at the end of everyone's.
  ///
  /// Picking somebody up is saying you want to decide what they do next, and
  /// the moment to decide that in is the one where the last thing they were
  /// told to do is done. That moment is usually behind the clock: the reason
  /// you stopped playing this one is that you went off to play someone else.
  /// Leaving the clock there would show you this player's controls for a world
  /// they're an hour late for, and every tap would be a decision made after the
  /// fact.
  ///
  /// Only on an actual change of hands. Tapping the one who's already
  /// selected is a tap for the camera, and taking a wound-back clock away
  /// from someone who deliberately wound it is not what they asked for.
  void select(Player p) {
    if (p.isSameAs(selectedPlayer.peek())) return;
    selectedPlayer.value = p;
    headFor(storyEndOf(p), ClockPush.ease);
  }

  /// The one call the ticker makes, and the only place real time touches the
  /// game. Nothing below here knows that frames exist.
  void tickRealTime(double realSeconds) {
    if (phase.peek() != GamePhase.playing) return;
    // Free-running play is a rate, not a journey, so it doesn't go through the
    // mover at all — the mover's job is arriving somewhere and stopping, and
    // this never arrives. Running it through anyway would have it overshooting
    // a destination one frame away every single frame and being rescued by the
    // snap, which happens to come out right and is no way to write it down.
    //
    // Not while the dial is held: a finger on the clock outranks the clock
    // running on.
    if (!paused.peek() && !dialHeld) {
      _shown += params.realSeconds(realSeconds).toDouble();
      _shownVelocity = 0;
      headingFor = null;
      _land();
      return;
    }
    final to = headingFor;
    if (to == null) return;

    // Braking to a stop, rather than a spring relaxing towards one.
    //
    // A spring never actually arrives: it closes the remaining distance by a
    // fraction each frame, so the last little bit of a big move takes as long
    // as the first big bit, and the clock spends a second crawling the final
    // few minutes. This gets there — under constant acceleration, at a moment
    // that can be named — and stops.
    //
    // The whole of it is one line of physics. `v² = 2ad` is the fastest you
    // can be going at distance d and still stop exactly on the mark, so that's
    // the speed to aim for, and the acceleration is the limit on how fast the
    // aim can change. Steering towards it rather than jumping to it is what
    // makes the motion continuous when the destination changes mid-flight;
    // never exceeding it is what stops it overshooting, which for a clock
    // would mean sailing past the moment and re-simulating the world to come
    // back to it.
    final target = to.toDouble();
    final gap = target - _shown;
    final a = _push.accel;
    final canStopFrom = sqrt(2 * a * gap.abs()) * (gap.isNegative ? -1 : 1);
    final step = a * realSeconds;
    _shownVelocity += (canStopFrom - _shownVelocity).clamp(-step, step);
    _shown += _shownVelocity * realSeconds;

    // Arrived: either near enough that another frame would be a frame of
    // nothing, or a whole frame was long enough to carry it over the mark. The
    // second is the one a long frame produces, and is why the crossing is
    // checked rather than assumed away.
    if (gap * (target - _shown) <= 0 || (target - _shown).abs() < tickRate) {
      _shown = target;
      _shownVelocity = 0;
      headingFor = null;
    }

    _land();
  }

  /// Takes the world to wherever the clock has got to, and gives up on the
  /// journey if it wouldn't go.
  void _land() {
    final want = _shown.round();
    if (want != now) rewindTo(want);
    if (now != want) {
      // the world refused: a replay came out differently and stopped the
      // clock, or that's as far back as this level knows. Either way the
      // motion is now describing a journey that isn't happening.
      _shown = now.toDouble();
      _shownVelocity = 0;
      headingFor = null;
    }
  }

  /// The parts of the world that aren't events: things that are continuous
  /// (where a train has got to), and things that are read off the clock rather
  /// than triggered by it (the phase, the half of the day). Run once at the
  /// end of an advance, because running them per event would be running them
  /// for no reason.
  void _settle() {
    for (final tr in trains) {
      tr.syncPos(now);
    }
    if (!probing) _keepSnapshots();
    final night = timeOfDay >= gameDay ~/ 2;
    if (night != isNight.peek()) isNight.value = night;
    final ann = announcement.peek();
    if (ann != null &&
        (now < ann.$3 || now - ann.$3 > params.announcementSpan)) {
      announcement.value = null;
    }
    final want = eudaimonia.peek() >= params.eudaimoniaGoal
        ? GamePhase.won
        : timeLeft <= 0
        ? GamePhase.lost
        : GamePhase.playing;
    if (want != phase.peek()) phase.value = want;
  }

  // ── inventory helpers (eudaimonia never occupies inventory: it converts
  // straight into score the moment it's received) ──

  bool playerHas(Player p, List<Quantity> qs) {
    for (final q in mergeQuantities(qs)) {
      if (p.inventory.value.where((it) => it == q.item).length < q.n) {
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
  bool storeFromInventory(Player p, Item it) {
    final node = p.at.value;
    if (node == null) return false;
    for (final s in node.facilities.whereType<Storage>()) {
      if (!s.activeNow(this)) continue;
      if (s.contents.value.length < s.capacity) {
        final inv = [...p.inventory.value];
        if (!inv.remove(it)) return false;
        p.inventory.value = inv;
        s.contents.value = [...s.contents.value, it];
        return true;
      }
    }
    return false;
  }

  /// clicking a stored item rotates it on: to the next storage at the node
  /// with space, wrapping around to the player's inventory
  bool rotateItemOnward(Player p, Storage from, Item it) {
    final node = from.node;
    final storages = node.facilities.whereType<Storage>().toList();
    final start = storages.indexOf(from);
    for (var k = start + 1; k < storages.length; k++) {
      if (!storages[k].activeNow(this)) continue;
      if (storages[k].contents.value.length < storages[k].capacity) {
        final c = [...from.contents.value];
        if (!c.remove(it)) return false;
        from.contents.value = c;
        storages[k].contents.value = [...storages[k].contents.value, it];
        return true;
      }
    }
    if (p.at.value.isSameAs(node) &&
        p.inventory.value.length < params.inventoryCap) {
      final c = [...from.contents.value];
      if (!c.remove(it)) return false;
      from.contents.value = c;
      p.inventory.value = [...p.inventory.value, it];
      return true;
    }
    return false;
  }

  // ── moving ──

  /// Puts [p] down on [to] without their crossing anything to get there. The
  /// arrival is an ordinary arrival — the same [Facility.onPlayerEntered] runs,
  /// so a mugger on the far node robs whoever lands on it exactly as it robs
  /// whoever walks in. Any move they had planned is dropped: it was a plan for
  /// a walk out of somewhere they're no longer standing.
  void teleport(Player p, Node to) {
    final from = p.at.value;
    if (from.isSameAs(to)) return;
    if (from != null) {
      from.playersPresent.value = from.playersPresent.value
          .where((x) => !x.isSameAs(p))
          .toList();
    }
    p.at.value = to;
    to.playersPresent.value = [...to.playersPresent.value, p];
    raiseNode(to);
    // The camera has nothing to follow across — they crossed nothing — and
    // whatever pan the player put in while they were aiming was a pan relative
    // to where they used to be standing. Both are dropped and the view seeks
    // them where they've landed.
    if (!probing && p.isSameAs(selectedPlayer.value)) recenterWanted.value++;
    for (final f in List.of(to.facilities)) {
      f.onPlayerEntered(this, p);
    }
  }

  // ── move scheduling ──

  /// Resolve a move-pad drag for [p] into the wire they meant — the one whose
  /// angle is closest, and nothing at all past a right angle — and write it
  /// down as something they've decided to do.
  ///
  /// Where the drag points is resolved here, at the moment of the drag, rather
  /// than being kept as an angle: an angle is a fact about the map as it looks
  /// now, and a replay wants the decision, which is the node. Scheduling ahead
  /// is allowed now — a player mid-walk who is told to walk again queues it,
  /// and it goes when they land.
  void dragPlayerMove(Player p, double dragAngle) {
    if (!params.playersHaveMoveAction) return;
    // from where they'll be when they get round to it, not from where they
    // are: a drag while they're mid-walk means "and then from there"
    final source = frontierNodeOf(p);
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
    commit(p, MoveAction(best.other(source), notBefore: actionMoment));
  }

  /// Same drag mechanic for a train, resolved to the station it meant.
  void dragTrainMove(TrainNode train, Player by, double dragAngle) {
    final from = train.dockedAt.value;
    if (from == null) return;
    Node? best;
    var bestDist = double.infinity;
    for (final s in train.stationNodes) {
      if (s.isSameAs(from)) continue;
      final ang = offsetAngle(train.terminusFor[s]! - train.terminusFor[from]!);
      final d = shortestAngleDistance(dragAngle, ang).abs();
      if (d < bestDist) {
        bestDist = d;
        best = s;
      }
    }
    if (best == null || bestDist > pi / 2) return;
    commit(by, TrainMoveAction(train, best, notBefore: actionMoment));
  }

  /// Sends [train] to [to] on [by]'s say-so, paying whatever it asks. The
  /// checks are all here rather than at the drag, because by the time a replay
  /// gets round to running this the train may have gone somewhere else, be
  /// mid-journey, or have someone standing on its gangway.
  bool manualTrainMove(TrainNode train, Player by, Node to) {
    final from = train.dockedAt.value;
    if (from == null || from.isSameAs(to)) return false;
    if (!train.manualAllowed || train.dockEdgeBusy(this)) return false;
    if (!train.stationNodes.any((s) => s.isSameAs(to))) return false;
    final act = train.activation;
    if (act != null) {
      if (!playerHas(by, [act])) return false;
      if (train.activationConsumed) takeItems(by, [act]);
    }
    train.departTo(this, to);
    return true;
  }

  /// The dial's clock: [SyntheticClock], rebuilt whenever anything it's made
  /// of has moved.
  ///
  /// Kept here rather than in the widget because the dial reads it twice for
  /// different purposes — once to draw the segments, once to turn a finger
  /// into a moment — and those two had better be looking at the same clock.
  /// The stamp is everything it's built from: where the world is, how long
  /// each list is, and how far through it we are.
  SyntheticClock get synthetic {
    var stamp = now;
    for (final p in players) {
      stamp = stamp * 31 + p.script.actions.length;
      stamp = stamp * 31 + p.script.done;
    }
    if (_synthetic == null || stamp != _syntheticStamp) {
      _syntheticStamp = stamp;
      _synthetic = SyntheticClock.of(this);
    }
    return _synthetic!;
  }

  SyntheticClock? _synthetic;
  int _syntheticStamp = 0;
}

// ────────────────────────────── the dial's clock ──────────────────────────────

/// The least room an action takes up on the wheel, however long it took.
///
/// A wheel that showed time as time would show a level's worth of harvesting
/// and trading as nothing at all: those take no time, and most of what a
/// player *does* takes no time. So the wheel is a clock with the small things
/// made big enough to see and to catch with a thumb.
const TTime minSyntheticActionDuration = 2 * gameMinute;

/// One action's place on the wheel: when it happened, and where it sits once
/// the clock has been stretched to make room for it.
class const SyntheticSpan({
  /// index into [Game.players], which is the band it's drawn on and the tie
  /// break when two actions land on the same tick — see [Game.advanceTo]
  required final int who,

  /// the real stretch of clock it takes up; the two are equal for everything
  /// but a walk
  required final TTime from,
  required final TTime to,

  /// where it lies on the wheel. Never shorter than
  /// [minSyntheticActionDuration], and longer than [from]..[to] whenever
  /// something short happened while it was going on.
  required final double start,
  required final double end,
}) {
  double get length => end - start;
}

/// One place where the wheel's clock stands still: a real moment, and how much
/// wheel is let into it.
class const _Pad({
  required final TTime at,
  required final double width,

  /// which action's padding this is, as a position in the run order — what
  /// decides whose 10 minutes comes first when two of them are at the same
  /// moment
  required final int rank,
}) {
  bool isBefore(TTime t, int r) => at < t || (at == t && rank < r);
}

/// Time as the outer wheel tells it: real time with a stretch let into it
/// wherever an action would otherwise be too small to see.
///
/// The rule is one line — every action gets at least
/// [minSyntheticActionDuration] of wheel — and everything else here is the
/// consequences of it holding for several players at once. The stretches are
/// let in *at the moment the action ends*, so:
///
///  * two players walking the same half hour side by side share the same
///    stretch of wheel, because neither of them needed padding;
///  * something instant that happens during someone else's walk is a segment
///    sitting inside that walk's arc, and the walk's arc grows by exactly the
///    room the instant thing was given;
///  * a run of instant actions comes out as a row of equal segments in the
///    order the world ran them, which is what makes two players taking turns
///    at a standstill read as taking turns.
///
/// The map is monotonic and never goes backwards, but it is emphatically not
/// proportional. That's the point of it: what it measures out is how much
/// wheel each action is worth, both to look at and to turn past, and a turn of
/// the wheel is a number of *things*, not a number of minutes. The world
/// itself only ever stands at the ends of those things — see [dialStopAt].
class SyntheticClock {
  SyntheticClock._(this.spans, this._pads, this._cum);

  /// every action anyone has run or is going to, in the order the world runs
  /// them
  final List<SyntheticSpan> spans;

  /// where the wheel stands still, ordered the same way, with a running total
  /// alongside: `_cum[i]` is all the padding let in before `_pads[i]`
  final List<_Pad> _pads;
  final List<double> _cum;

  /// bigger than any action's place in the run order: "after everything that
  /// happens at this moment"
  static const int _afterAll = 1 << 40;

  static SyntheticClock of(Game g) {
    // What's behind us comes off the record — see [PlayerAction.ranAt] — and
    // what's ahead comes off the plan. Both are needed: the wheel winds
    // backwards as much as forwards, and a stretch let in for something that
    // has already happened has to still be there when you wind back to it, or
    // the wheel would change shape under the thumb.
    final raw = <({int who, TTime from, TTime to, int seq})>[];
    for (var w = 0; w < g.players.length; w++) {
      final p = g.players[w];
      for (var i = 0; i < p.script.done && i < p.script.actions.length; i++) {
        final a = p.script.actions[i];
        final ran = a.ranAt;
        // an action off a save: nobody wrote down when it went, and there's no
        // winding back past where the save was put down anyway
        if (ran == null) continue;
        raw.add((who: w, from: ran, to: a.ranUntil ?? ran, seq: raw.length));
      }
      g.walkPlan(
        p,
        each: (a, from, to, _) =>
            raw.add((who: w, from: from, to: to, seq: raw.length)),
      );
    }
    // the order the world runs them in, read off [Game.advanceTo]: the moment,
    // then whose turn it is, and a player's own list is already in order
    raw.sort((a, b) {
      if (a.from != b.from) return a.from - b.from;
      if (a.who != b.who) return a.who - b.who;
      return a.seq - b.seq;
    });

    final pads = <_Pad>[];
    for (var k = 0; k < raw.length; k++) {
      final short = minSyntheticActionDuration - (raw[k].to - raw[k].from);
      if (short > 0) {
        pads.add(_Pad(at: raw[k].to, width: short.toDouble(), rank: k));
      }
    }
    // A stretch is let in where its action *ends*, not where it started, so
    // these don't come out in order and have to be put in one. Rank settles
    // the ties: the pads at one instant are the several actions that happened
    // at it, in the order they ran.
    pads.sort((a, b) => a.at != b.at ? a.at - b.at : a.rank - b.rank);
    final cum = <double>[0];
    for (final pad in pads) {
      cum.add(cum.last + pad.width);
    }

    final clock = SyntheticClock._([], pads, cum);
    for (var k = 0; k < raw.length; k++) {
      final r = raw[k];
      clock.spans.add(
        SyntheticSpan(
          who: r.who,
          from: r.from,
          to: r.to,
          // its own padding is at its end and belongs to it, so it counts
          // towards where it finishes and not towards where it starts
          start: r.from + clock._before(r.from, k),
          end: r.to + clock._before(r.to, k + 1),
        ),
      );
    }
    return clock;
  }

  /// all the padding let in before the moment [t], counting only what belongs
  /// to actions that ran before [rank] among those at that very moment
  double _before(TTime t, int rank) {
    var lo = 0, hi = _pads.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_pads[mid].isBefore(t, rank)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return _cum[lo];
  }

  /// Where the wheel stands when the clock reads [t]: past everything that has
  /// already happened at that instant, since it has already happened.
  double at(TTime t) => t + _before(t, _afterAll);

  /// one player's actions, in order — the band drawn for them, and the
  /// detents the wheel clicks through when they're the one selected
  List<SyntheticSpan> bandOf(int who) => [
    for (final s in spans)
      if (s.who == who) s,
  ];
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
    final scheduleKind = weightedPick(rng, p.scheduleDistribution);
    final schedule = switch (scheduleKind) {
      TrainScheduleKind.never => const NeverSchedule(),
      TrainScheduleKind.oneWay => const OneWaySchedule(),
      // cycle trains run on a division clock interval: so many trips a day,
      // always at the same times
      TrainScheduleKind.cycle => CycleSchedule(
        _divisionInterval(
          rng,
          p.trainCycleDivisions[rng.nextInt(p.trainCycleDivisions.length)],
        ),
      ),
    };
    Quantity? activation;
    var activationConsumed = false;
    if (rng.chance(p.trainActivationProb)) {
      activationConsumed = rng.chance(p.trainActivationConsumedProb);
      // a pretty basic item, though it may be a medium one
      final tier = weightedPick(rng, [(0.6, 0), (0.3, 1), (0.5, 2)]);
      activation = Quantity(
        _pick(rng, catalog.tiers[tier]),
        rng.chance(p.trainActivationTwoProb) ? 2 : 1,
      );
    }
    final manual = schedule is NeverSchedule || schedule is OneWaySchedule;
    final train = TrainNode(
      pos: terminusFor[stationNodes.first]!,
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
    FacilityKind.outbox,
    FacilityKind.inbox,
    FacilityKind.jumpStation,
    FacilityKind.landingStation,
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
        FacilityKind.outbox => Outbox(
          logUniformInt(
            rng,
            p.outboxCapacityRange.$1,
            p.outboxCapacityRange.$2,
          ),
          secured: rng.chance(p.storageSecurep),
        ),
        FacilityKind.inbox => _generateInbox(rng, p, catalog),
        FacilityKind.jumpStation => _generateJumpStation(rng, p, catalog),
        FacilityKind.landingStation => LandingStation(),
        _ => _generateMugger(rng, p, catalog),
      });
    }
  }
  // Nothing is handed a day/night restriction: muggers used to work the night
  // and a third of everything else kept day hours, which meant half of what a
  // player had worked out about the map was inactionable at any given moment.
  // Facilities keep their schedules; they no longer keep hours. See
  // [ActivePhase].
  shuffleInPlace(rng, pool);
  var k = 0;
  for (var i = 0; i < nodes.length; i++) {
    for (var j = 0; j < bucketSizes[i] && k < pool.length; j++) {
      final f = pool[k++];
      f.node = nodes[i];
      nodes[i].facilities.add(f);
    }
  }

  _makeGoodCounterparts(nodes);

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
  // the level is finished now, and this is what winding all the way back
  // gets you — see [Game.markOrigin]
  game.markOrigin();
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
      ? ClockInterval(offset: ticksOf(rng.nextDouble() * gameDay))
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
      multiple: days,
      offset: rangeInTicks(rng, gameDay ~/ 2, gameDay),
    ),
    mitigator: mitigable ? all[rng.nextInt(all.length)] : null,
    hungry: mitigable && rng.chance(p.blightHungryp),
  );
}

Inbox _generateInbox(GameRng rng, Parameters p, ItemCatalog cat) {
  if (!rng.chance(p.inboxActivationProb)) return Inbox();
  return Inbox(
    // a basic item by preference, as the trains take
    activation: Quantity(
      _pick(rng, cat.tiers[weightedPick(rng, [(0.7, 0), (0.3, 1)])]),
      1,
    ),
    activationConsumed: rng.chance(p.inboxActivationConsumedProb),
  );
}

JumpStation _generateJumpStation(GameRng rng, Parameters p, ItemCatalog cat) {
  final freeAim = rng.chance(p.jumpFreeAimp);
  var costs = rng.chance(p.jumpCostItemp);
  var cools = rng.chance(p.jumpCooldownp);
  // A jump to anywhere at no price is a second map with no distances in it, so
  // a free-aim station that rolled neither is given the cooldown. A station
  // that can only reach landing stations is allowed to be free: the landing
  // stations are the price.
  if (freeAim && !costs && !cools) cools = true;
  Quantity? cost;
  if (costs) {
    // the trains' rule: a basic item, unless what it's buying is the expensive
    // kind of jump, in which case it may be something out of the middle
    final tier = weightedPick(rng, [
      (0.6, 0),
      (0.3, 1),
      if (freeAim) (0.5, min(2, cat.tiers.length - 1)),
    ]);
    cost = Quantity(_pick(rng, cat.tiers[tier]), 1);
  }
  return JumpStation(
    freeAim: freeAim,
    cost: cost,
    cooldown: cools
        ? roundToMinute(
            rangeInTicks(rng, p.jumpCooldownRange.$1, p.jumpCooldownRange.$2),
          )
        : 0,
  );
}

/// Hops from [from] to every node it can reach over the permanent wires. Used
/// to put a forced counterpart as far from the facility that needed it as the
/// map allows — one placed next door saves nobody a journey.
Map<Node, int> _hopsFrom(Node from) {
  final dist = <Node, int>{from: 0};
  final queue = <Node>[from];
  for (var i = 0; i < queue.length; i++) {
    final n = queue[i];
    for (final e in n.edges) {
      final other = e.other(n);
      if (dist.containsKey(other)) continue;
      dist[other] = dist[n]! + 1;
      queue.add(other);
    }
  }
  return dist;
}

/// the reachable node furthest from [from], or null if it stands alone
Node? _furthestFrom(Node from, List<Node> nodes) {
  final dist = _hopsFrom(from);
  Node? best;
  var bestD = -1;
  for (final n in nodes) {
    final d = dist[n];
    if (d == null || d <= bestD) continue;
    bestD = d;
    best = n;
  }
  return best;
}

void _place(Node n, Facility f) {
  f.node = n;
  n.facilities.add(f);
}

/// Two of the kinds do nothing on their own, so once the shuffle has strewn
/// everything the pairings are made good: an inbox with nothing to pull from,
/// or a jump station with nowhere to land, is a facility the player can read,
/// walk to, and get nothing out of.
void _makeGoodCounterparts(List<Node> nodes) {
  Iterable<T> allOf<T extends Facility>() sync* {
    for (final n in nodes) {
      yield* n.facilities.whereType<T>();
    }
  }

  final inbox = allOf<Inbox>().firstOrNull;
  if (inbox != null && allOf<Outbox>().isEmpty) {
    final at = _furthestFrom(inbox.node, nodes);
    if (at != null) {
      // a storage is the nearest thing to an outbox there is, so one of those
      // becomes the outbox where there's one to take; otherwise it's new
      final storage = at.facilities.whereType<Storage>().firstOrNull;
      if (storage != null) {
        at.facilities.remove(storage);
        _place(at, Outbox(storage.capacity, secured: storage.secured));
      } else {
        _place(at, Outbox(3));
      }
    }
  }

  final jump = allOf<JumpStation>().firstWhereOrNull((j) => !j.freeAim);
  if (jump != null && allOf<LandingStation>().isEmpty) {
    final at = _furthestFrom(jump.node, nodes);
    if (at != null) _place(at, LandingStation());
  }
}

// ────────────────────────────── shared render bits ──────────────────────────────

/// A clock schedule in english, ending in the time of day it fires at — which,
/// like every clock time the game prints, comes with its face. See
/// [clockTimeSpans].
List<InlineSpan> describeClockSpans(ClockInterval c) => [
  tipText(
    c.isDaily
        ? (c.multiple == 1 ? 'daily at ' : 'every ${c.multiple} days at ')
        : '${c.division} times a day, from ',
  ),
  ...clockTimeSpans(c),
];

/// The day/night markers. Material's light_mode/dark_mode carry too much
/// interior detail to survive being drawn at eight logical pixels, so we draw
/// our own: shapes that stay readable when they're barely bigger than the text
/// beside them.
///
/// The sun is an eight-pointed star with a round hole punched out of it, so
/// what reads at small sizes is the ring of spikes rather than a blob.
class const _SunPainter(final Color color) extends CustomPainter {
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
class const _MoonPainter(final Color color) extends CustomPainter {
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

/// A clock face: a disc with an hour hand and a fainter, longer minute hand,
/// standing at the time of day beside it.
///
/// It is emphatically not a pie, because it shares its corner with them. A pie
/// is a countdown — a wedge that drains as something comes due — and a clock
/// time is the other kind of fact, a fixed hour that comes round again, so the
/// two have to be different objects at a glance and not two ways of filling the
/// same disc. A dial with hands is about as far from a wedge as a disc gets.
///
/// The face is pale for an AM time and dark for a PM one, and stays that way
/// round under a dark scheme — which half of the day it is doesn't depend on
/// what the screen is doing. That does mean the face sometimes lands on a
/// ground its own colour, which is what the rim is for: see [_rim]. The digits
/// across it are on a 24-hour clock and say the same thing the colouring does;
/// the point of the colouring is that it survives not being read.
///
/// The colours are passed in rather than read off [paletteSignal], because
/// nothing subscribes during paint and [shouldRepaint] is where a change of
/// scheme has to be noticed.
class const _ClockFacePainter({
  required final double minutesIntoDay,

  /// the hour written out across the lower half of the face, or null on the
  /// small faces where four digits would be a smudge
  final String? digits,

  /// where the minute hand was a frame ago, if it's worth showing the ground
  /// it covered — see [_minuteSweepFade]
  final double? sweptFromMinutes,
  required final Color face,
  required final Color hand,

  /// whether the face is the same colour as the ground it's drawn on, and so
  /// needs an edge drawn round it to be a disc at all
}) extends CustomPainter {
  /// hand lengths and widths, as fractions of the radius inside the rim. The
  /// minute hand reaches nearly to the edge and the hour hand stops around
  /// halfway, which is the whole of what makes the two readable this small —
  /// their positions can't be relied on to tell them apart.
  static const _hourLength = 0.52;
  static const _hourWidth = 0.3;
  static const _minuteLength = 0.84;
  static const _minuteWidth = 0.2;

  /// how far the minute hand is let fade towards its face
  static const _minuteFade = 0.55;

  /// The edge drawn round the face, as a fraction of the radius, and how far
  /// its colour is carried towards the face's own.
  ///
  /// It's here for the half of the day whose face is the colour of the ground
  /// it sits on, where without it there's no disc at all. But it only has to
  /// close the shape, not describe it — the hands are the clock — so it's a
  /// line rather than a band, and nearly the colour of what it encloses.
  static const _rim = 0.052;
  static const _rimTowardsFace = 0.8;

  /// How much of its colour the minute hand keeps once it has smeared right
  /// round the dial. Not zero: a hand that vanishes is a hand you have to
  /// hunt for when it settles again.
  static const _minuteSweepFloor = 0.45;

  /// The written hour, as a fraction of the radius, and how much of the hands'
  /// colour it keeps. Fainter than they are on purpose: the hands are the
  /// clock and this is a second opinion, there for when the exact minute
  /// matters — a reading you go looking for rather than one that competes for
  /// the glance the hands are supposed to answer.
  static const _digitsSize = 0.23;
  static const _digitsFade = 0.42;

  /// where it sits: the middle of the lower half of the face
  static const _digitsDrop = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    final r = min(size.width, size.height) / 2;
    final c = Offset(size.width / 2, size.height / 2);

    canvas.drawCircle(c, r, Paint()..color = face);
    final rimWidth = max(0.6, r * _rim);
    canvas.drawCircle(
      c,
      r - rimWidth / 2,
      Paint()
        ..color = Color.lerp(hand, face, _rimTowardsFace)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimWidth,
    );

    final dial = r - rimWidth;

    /// A hand, and the ground it covered getting here.
    ///
    /// One shape, not a hand with something drawn behind it. The swept region
    /// is the hand's own outline dragged round the dial, so it's built as a
    /// path — out along the hand where it started, round at the tip, back to
    /// the middle — and then both filled *and* stroked with the hand's own
    /// width and round ends, in one colour. Which is what makes it read as the
    /// hand having been there rather than as a wedge sitting under it: at
    /// [sweptTurns] of nothing the path collapses to the line itself and the
    /// stroke alone draws the hand, so the two cases are the same drawing.
    void drawHand(
      double turns,
      double length,
      double width,
      Color color, {
      double sweptTurns = 0,
    }) {
      final a = -pi / 2 + turns * 2 * pi;
      final reach = dial * length;
      final paint = Paint()
        ..color = color
        ..strokeWidth = max(0.7, dial * width)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (sweptTurns.abs() < 0.0005) {
        canvas.drawLine(
          c,
          c + Offset(cos(a), sin(a)) * reach,
          paint..style = PaintingStyle.stroke,
        );
        return;
      }
      // the arc runs from where the hand was to where it is; going backwards
      // is the same ground covered the other way round
      final from = sweptTurns >= 0 ? a - sweptTurns * 2 * pi : a;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + cos(from) * reach, c.dy + sin(from) * reach)
        ..arcTo(
          Rect.fromCircle(center: c, radius: reach),
          from,
          sweptTurns.abs() * 2 * pi,
          false,
        )
        ..close();
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    }

    // How far round the minute hand went since the last frame, capped at the
    // whole turn past which it has covered everything anyway. It thins out as
    // it smears, but only down to [_minuteSweepFloor] — a spinning hand should
    // read as a faint disc, not as an absence.
    //
    // Kept as a signed count of turns rather than two times of day, so a sweep
    // across the hour is one sweep and not fifty-nine minutes the other way.
    final was = sweptFromMinutes;
    final turns = was == null ? 0.0 : (minutesIntoDay - was) / 60;
    final swept = turns.sign * min(turns.abs(), 1.0);
    final solidity = 1 - swept.abs() * (1 - _minuteSweepFloor);

    // under the hands, so a hand crossing it reads as being in front
    _paintDigits(canvas, c, dial);

    // the minute hand goes down first so the hour hand crosses over it
    drawHand(
      (minutesIntoDay % 60) / 60,
      _minuteLength,
      _minuteWidth,
      lerpColor(face, hand, _minuteFade * solidity),
      sweptTurns: swept,
    );
    drawHand(
      (minutesIntoDay % (12 * 60)) / (12 * 60),
      _hourLength,
      _hourWidth,
      hand,
    );
  }

  void _paintDigits(Canvas canvas, Offset c, double dial) {
    final text = digits;
    if (text == null) return;
    final t = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: dial * _digitsSize,
          fontWeight: FontWeight.w600,
          height: 1,
          color: hand.withValues(alpha: _digitsFade),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    t.paint(
      canvas,
      c + Offset(-t.width / 2, dial * _digitsDrop - t.height / 2),
    );
  }

  @override
  bool shouldRepaint(_ClockFacePainter old) =>
      old.digits != digits ||
      old.minutesIntoDay != minutesIntoDay ||
      old.sweptFromMinutes != sweptFromMinutes ||
      old.face != face ||
      old.hand != hand;
}

/// The face for a moment in the day, [size] across. The whole day maps onto the
/// whole 24-hour clock, exactly as [fmtTimeOfDay] reads it.
Widget clockFace(
  TTime t, {
  required double size,
  TTime? sweptFrom,
  bool digits = false,
}) {
  final minutes = (t % gameDay) / gameMinute;
  final pm = minutes >= 12 * 60;
  // the scheme's palest and its deepest; which of the two is [Palette.ground]
  // is exactly what changes between schemes
  final pale = paletteSignal.value.isDark
      ? paletteSignal.value.inkStrong
      : paletteSignal.value.ground;
  final deep = paletteSignal.value.isDark
      ? paletteSignal.value.ground
      : paletteSignal.value.inkStrong;
  final face = pm ? deep : pale;
  return CustomPaint(
    size: Size.square(size),
    painter: _ClockFacePainter(
      minutesIntoDay: minutes,
      digits: digits ? fmtTimeOfDayPadded(t) : null,
      // measured off the raw clock, not off the time of day, so a sweep that
      // crosses midnight is one sweep rather than a whole dial's worth
      sweptFromMinutes: sweptFrom == null
          ? null
          : minutes - (t - sweptFrom) / gameMinute,
      face: face,
      hand: pm ? pale : deep,
    ),
  );
}

/// A clock time as it's always given: the face, then the digits.
Widget clockTimeRow(
  TTime t, {
  required double faceSize,
  required TextStyle style,
}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    clockFace(t, size: faceSize),
    SizedBox(width: faceSize * 0.28),
    Text(fmtTimeOfDay(t), style: style),
  ],
);

/// the same pair inside tooltip prose, where the digits are ordinary text so
/// they wrap and take the tooltip's style, and only the face is a widget
List<InlineSpan> clockTimeSpans(ClockInterval c) => [
  WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.only(left: 1, right: 3),
      child: clockFace(c.timeOfDay, size: 11),
    ),
  ),
  tipText(fmtTimeOfDay(c.timeOfDay)),
];

Widget badgeText(String s) => Text(
  s,
  style: TextStyle(
    fontSize: 10,
    color: paletteSignal.value.ink,
    fontWeight: FontWeight.w500,
  ),
);

Widget badgeIcon(IconData icon, {Color? color, double size = 13}) =>
    Icon(icon, size: size, color: color ?? paletteSignal.value.ink);

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
            color: paletteSignal.value.inkStrong,
            shadows: [
              Shadow(color: paletteSignal.value.ground, blurRadius: 2),
              Shadow(color: paletteSignal.value.ground, blurRadius: 3),
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
  final fill = lozengeFill(tone ?? paletteSignal.value.node);
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
/// clock interval — face and all, see [clockTimeRow] — and with the span still
/// to run otherwise, one or the other, never both. Either way the pie is the
/// same pie: how soon is the pie's business, and at what hour is the label's.
/// Both kinds shrink. Ticks on game time via its signal — never wall clock —
/// so pausing pauses pies.
/// A wedge that empties as something finishes.
///
/// [endsAt] is a closure rather than a signal because what it wants is a
/// deadline, and a deadline is rarely a field — a tree's is its picking plus
/// its regrowth, a train's is worked out from its schedule. Called inside the
/// builder, so whatever signals it reads on the way are the ones this pie
/// rebuilds for.
///
/// It subscribes to the clock only while it's counting: a pie with nothing to
/// count returns before it looks at [Game.clock], so the badges of the idle
/// majority of the map cost nothing per frame.
class const CountdownPie({
  super.key,
  required final Game game,
  required final TTime? Function() endsAt,
  required final TTime total,
  required final bool isCooldown,

  /// set when the countdown runs on a clock interval: its time of day is the
  /// more useful label, so it's shown in place of the span
  final ClockInterval? clock,
  final double size = 11,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final end = endsAt();
        if (end == null || total <= 0) return const SizedBox.shrink();
        final r = end - game.clock.value;
        if (r <= 0) return const SizedBox.shrink();
        final pie = CustomPaint(
          size: Size.square(size),
          painter: _PiePainter(
            fraction: clampUnit(r / total),
            color: isCooldown ? paletteSignal.value.inkStrong : sage,
          ),
        );
        if (!isCooldown) return pie;
        final labelStyle = TextStyle(
          fontSize: 8,
          color: paletteSignal.value.inkStrong,
        );
        // The label is positioned rather than laid out in a row: a Positioned
        // given only a left offset is left unconstrained, so it hangs off the
        // pie's right without widening it, and the pie keeps the corner.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            pie,
            Positioned(
              left: size + 1,
              top: size / 2 - 5,
              child: clock != null
                  ? clockTimeRow(
                      clock!.timeOfDay,
                      faceSize: 9,
                      style: labelStyle,
                    )
                  : Text(fmtSpan(r), style: labelStyle),
            ),
          ],
        );
      },
    );
  }
}

class _PiePainter({required final double fraction, required final Color color})
    extends CustomPainter {
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

// ────────────────────────────── the dial ──────────────────────────────

/// how much game time one full turn of the grabbed wheel is worth. The hour
/// hand goes round twice a day, and the dial turns the hour hand, so a whole
/// turn of the inner wheel is half a day.
const TTime _dialTurn = 12 * gameHour;

/// what the rim divides that by. A drag of thirty degrees out there is six
/// game minutes — half a walk between two nodes — where the same drag on the
/// clock face is an hour. Fine control is a ring you can hook a thumb round
/// rather than a mode you have to switch into. Like dragging the minute hand,
/// except where the wheel has padded an instant action out.
const double _outerWheelGearing = 1 / 12;

/// How much of the wheel's clock one full band's worth of arc stands for.
///
/// Not a number of its own: it's what a whole turn of a thumb on the rim winds
/// the wheel by, written as that product so it can't quietly stop being. The
/// band is a ruler the thumb pushes along and the two have to agree — the arc
/// a segment is drawn at is the arc it costs to turn past. Drawing the band at
/// the whole twelve hours meant a segment five degrees wide that took fifty
/// degrees of thumb.
///
/// So [_outerWheelGearing] is the one knob. Gear it down to see further ahead
/// at the cost of a coarser thumb.
const double _wheelSpan = _dialTurn * _outerWheelGearing;

/// How far the wheel has to turn before it's turning rather than being taken
/// hold of. A thumb landing on the rim moves a pixel or two of its own accord,
/// and the first thing a turn does is jump — see [dialStopAt] — so which way
/// it went had better not be decided by a wobble.
const double _dialSnapDeadzone = 0.014;

/// The bite taken out of the end of every segment so that two of them in a row
/// read as two things and not one long one, and the most of a segment it's
/// allowed to eat. Fixed angle rather than a fraction: the gap is doing the
/// same job whatever it separates, and a proportional gap is invisible on the
/// short segments, which are most of them.
const double _segmentGap = 0.055;
const double _segmentGapMax = 0.4;

/// Where the action-history bands begin, and which way they run: down and to
/// the right of the clock, sweeping anticlockwise up over it. Which is the
/// part of the rim that's over the map rather than off the bottom or the side.
const double _dialStartAngle = pi / 2 * 0.3;
const double _dialSweepSign = -1;

/// The wheel's radius and thickness, as multiples of the clock face's
/// *diameter*, so the whole dial keeps its proportions when the face is sized
/// to the map. Note the diameter: at 0.5 the rim would sit exactly on the edge
/// of the face, and anything under that would be inside it.
///
/// How far out the rim stands is being tuned by eye. Nothing else depends on
/// it — where the wheels meet comes off the face (see [dialIsFineWheel]) and
/// what can be grabbed comes off what's drawn (see [dialTakesTouch]) — so it
/// can be moved without anything else having to be told.
const double _wheelRadiusFactor = 0.8;
const double _wheelWidthFactor = 0.23;

/// The least the rim will accept a thumb across, whatever it's drawn at. A
/// wheel is only a wheel if you can take hold of the rim, and the rim is a
/// line — the width that matters to a finger has nothing to do with the width
/// that matters to an eye.
const double _wheelTouchWidth = 52;

/// How near the middle a finger has to get before the dial stops taking it
/// literally, as a fraction of the face's radius.
///
/// An angle is a poor thing to measure a drag by when the finger is near the
/// middle: a few pixels there sweep half the dial, and a wheel that spins
/// faster the closer you get to the axle is a wheel nobody can hold still. So
/// inside this the turn is worked out as though the finger were out here —
/// same movement, less turn, which is what having leverage means.
const double _dialMinLeverage = 0.4;

/// How near the middle the dial stops taking the angle literally. Read rather
/// than written out wherever it's needed, so the tuning lives in one place.
double dialLeverageLimit(double faceSize) => faceSize / 2 * _dialMinLeverage;

/// how far the wheel reaches from the middle of the clock
double dialWheelRadius(double faceSize) => faceSize * _wheelRadiusFactor;

/// where the rim is drawn: the centre of the band, not its outside
double dialRimRadius(double faceSize) =>
    dialWheelRadius(faceSize) - faceSize * _wheelWidthFactor / 2;

/// How far the dial turns for a drag from [from] to [to], both measured from
/// the middle of the clock. Positive winds time forward, which is clockwise,
/// which is the way the hour hand goes.
///
/// It's the angle swept, which is the whole of it anywhere a hand would
/// normally be. The angle is the right measure and it's exact however far the
/// finger travelled in the frame — where working the turn out from the
/// movement would be reading the chord for the arc, and would lose a fast drag
/// most of its turn.
///
/// Inside [_dialMinLeverage] the angle stops being a sensible thing to steer
/// by: a few pixels across the middle of the clock is half the dial, and the
/// closer to the axle the worse it gets, up to a discontinuity right on it. So
/// in there — and only in there — the turn is taken from how far the finger
/// went *around*, as though it had been out at the limit the whole time. Same
/// movement, less turn, no singularity.
double dialTurnFor(double faceSize, Offset from, Offset to) {
  final reach = from.distance;
  if (reach < 0.01) return 0;
  final limit = dialLeverageLimit(faceSize);
  if (reach >= limit && to.distance >= limit) {
    return shortestAngleDistance(offsetAngle(from), offsetAngle(to));
  }
  final delta = to - from;
  // the part of the movement that went around rather than in or out. Never
  // more than the movement itself, so this can't run away as the middle is
  // approached the way an angle does.
  final around = (from.dx * delta.dy - from.dy * delta.dx) / reach;
  return around / limit;
}

/// Whether the dial takes a touch this far out from the middle of the clock:
/// on the face, or across the rim.
///
/// Everything the dial draws, it will take a drag on — that's the rule, and
/// it's the whole shape. The gap in between belongs to the map: the dial's
/// widget is a square as wide as the whole wheel, and a control that swallowed
/// everything inside it would be a control covering most of the level, so what
/// isn't drawn falls through to what is.
///
/// Both the painting and the hit test are worked out from here, which is the
/// point of it being a function rather than two sets of arithmetic: a rim you
/// can see and can't grab is exactly the bug this is guarding.
bool dialTakesTouch(double faceSize, double fromMiddle) =>
    fromMiddle <= faceSize / 2 ||
    (fromMiddle - dialRimRadius(faceSize)).abs() <= dialRimTouchBand(faceSize);

/// half the width of the rim as a thumb sees it
double dialRimTouchBand(double faceSize) =>
    max(faceSize * _wheelWidthFactor, _wheelTouchWidth) / 2;

/// Which of the two wheels a touch this far out is on.
///
/// The clock face decides it, because the clock face *is* the fast wheel —
/// there are two things drawn here and they are the two wheels, so there is
/// nothing to choose and no fraction to pick. Anywhere on the clock turns time
/// quickly; the rim, being a rim, turns it finely.
bool dialIsFineWheel(double faceSize, double fromMiddle) =>
    fromMiddle > faceSize / 2;

/// What the rim has to click through: the selected player's actions, in order,
/// each one as wide as [SyntheticClock] says it is.
List<SyntheticSpan> dialBand(Game game) =>
    game.synthetic.bandOf(game.players.indexOf(game.selectedPlayer.peek()));

/// Where the wheel stands when the world stands at [Game.now]: on the clock,
/// but never off the ends of the list.
///
/// The wheel past the last action is time nobody decided anything in, and
/// having to crank back through an hour of it to reach the thing you actually
/// wanted to unmake is not a control. So the rim's ends are the list's ends, a
/// tick either side — that tick being the room to stand before the first
/// action or after the last — and idling on past the end of a list leaves the
/// wheel sitting where a turn still means something.
double dialWoundFor(Game game) {
  final band = dialBand(game);
  final at = game.synthetic.at(game.now);
  if (band.isEmpty) return at;
  return at.clamp(band.first.start - 1, band.last.end + 1);
}

/// Where the world stands when the rim has been turned to [wound]: the far
/// side of the action the wheel is on, on the side it's being turned towards.
///
/// The whole rule is *which action the wheel is over*. Turning forward, being
/// anywhere on an action means that action has happened; turning back, being
/// anywhere on it means it hasn't. So the world clicks over the moment the
/// wheel comes onto a segment and doesn't move again until it comes onto the
/// next — one action per segment of turning, evenly, however long the actions
/// took, and nothing in between. There is no gesture here that means "half way
/// through a walk"; that's what the clock face is for.
///
/// A turn that went one too far is taken back by turning back, because [wound]
/// is the whole of the state — the wheel remembers where it is, not how it got
/// there.
///
/// Which way it's going has to be given, because it's the one thing the wheel
/// position can't say: the same place on the wheel means "that's done" to a
/// thumb pushing forward and "that hasn't happened" to one pulling back. It's
/// settled once, when the turn starts, and holds for the whole of it.
///
/// The selected player's list, not everyone's, for the same reason tapping the
/// clock uses theirs. Null when they have no list to turn through at all.
TTime? dialStopAt(Game game, double wound, bool forward) {
  final band = dialBand(game);
  if (band.isEmpty) return null;
  if (forward) {
    // before the first of them is the world with none of it done
    var best = band.first.from - 1;
    for (final s in band) {
      if (s.start > wound) break;
      best = s.to;
    }
    return best;
  }
  // and past the last, the world with all of it
  var best = band.last.to;
  for (final s in band.reversed) {
    if (s.end < wound) break;
    best = s.from - 1;
  }
  return best;
}

/// how much of the map's narrower side the clock face takes up
const double dialFaceSpan = 0.24;

/// how far the clock face is held off the corner
const double dialPadding = 10;

/// The clock, turned rather than watched.
///
/// Dragging it winds the world: the hour hand follows the finger, and the
/// world is re-simulated to wherever the hand ends up. Two wheels, because one
/// dial can't be both a way to skip a day and a way to land on a particular
/// ten minutes — the clock face is quick, the rim around it is geared right
/// down. The two things it draws are the two wheels; there's no third region
/// and no fraction to pick.
///
/// Tapping it goes to the end of the selected player's list, which is the
/// moment you almost always want: everything they've been told to do, done.
///
/// The two move in quite different ways. The face winds time: it goes where
/// the thumb goes and the world goes with it. The rim turns just as smoothly,
/// but the world clicks, an action at a time, as the wheel comes onto each of
/// them. See [dialStopAt].
///
/// It sits in the very corner, and the wheel is drawn as a circle round it
/// wider than the widget holding them both — so it hangs off the bottom and
/// the left, and what's in view is the arc over the map. Which is the honest
/// shape of the thing: a wheel you turn a few degrees of, where a few degrees
/// of a wide wheel is a long, shallow, precise arc and the same gesture on a
/// small one is a jerk of the wrist.
class const TimeDial({
  super.key,
  required final Game game,
  required final ValueNotifier<int> frame,

  /// the clock itself — the part that is actually a clock. Everything else
  /// about the dial is a multiple of it.
  required final double faceSize,
}) extends StatefulWidget {
  @override
  State<TimeDial> createState() => _TimeDialState();
}

class _TimeDialState extends State<TimeDial> {
  /// which wheel the finger came down on, decided once when it lands: a drag
  /// that started on the fine wheel stays on it even as it wanders inward,
  /// because changing gear halfway through a turn is not something a hand
  /// asked for
  bool _onOuterWheel = false;
  Offset _lastTouch = Offset.zero;

  /// Where the drag has wound to, kept as a real number so that a slow turn
  /// isn't lost to rounding a tick at a time.
  ///
  /// Which clock it's on depends on which wheel was grabbed: the face winds
  /// the world's own time, the rim winds [SyntheticClock]'s. Set once when the
  /// finger lands and read back through the same clock, so the two never meet.
  double _wound = 0;

  /// Which way this turn is going; null until the thumb has moved enough to
  /// say. See [dialStopAt]. Settled once and held, because a hand that wavers
  /// halfway through hasn't changed its mind about what it's doing.
  bool? _forward;

  /// how far the wheel has been turned while [_forward] was still undecided
  double _deciding = 0;

  /// Where the wheel itself is standing, which is not where the clock is.
  ///
  /// The clicking happens to the world, not to the wheel: under a thumb the
  /// rim goes exactly where the thumb puts it, smoothly, while the world jumps
  /// from one action to the next underneath it — so what the wheel is showing
  /// between two clicks is how much further there is to push. Let go and it
  /// settles onto the clock. Null until the first frame.
  double? _shownWheel;

  /// how quickly the wheel settles back onto the clock once it's let go — a
  /// blend a frame, like everything else here that follows something
  static const double _wheelSettle = 0.3;

  /// Where to draw the wheel this frame: exactly where the thumb has it while
  /// it's being turned, and easing back onto the clock the rest of the time.
  ///
  /// Nothing ever moves the wheel but the drag — a wheel that repositioned
  /// itself under a thumb would be the thumb losing its place, and the clicks
  /// after it would land somewhere nobody aimed at. The settling is the one
  /// exception and it happens after the finger has gone.
  ///
  /// Nothing reads any of this but the painter — where the *world* is is
  /// [Game.now] and always was.
  double _wheelNow(Game game) {
    final rest = dialWoundFor(game);
    final was = _shownWheel;
    if (_onOuterWheel && game.dialHeld) return _shownWheel = _wound;
    if (was == null) return _shownWheel = rest;
    final next = was + (rest - was) * _wheelSettle;
    // a blend never quite arrives, and a wheel that never quite settles would
    // re-lay the segments every frame for ever
    return _shownWheel = (rest - next).abs() < 1 ? rest : next;
  }

  /// what the clock read on the last frame, so the minute hand can be drawn as
  /// the ground it covered rather than as a line that jumped
  TTime? _lastShown;

  /// The widget is the whole wheel, so the middle of it is the middle of the
  /// clock — and the clock is held [TimeDial.padding] off the corner by
  /// hanging the rest of the wheel off the screen. See [_cornerOffset].
  double get _wheelRadius => widget.faceSize * _wheelRadiusFactor;
  double get _box => _wheelRadius * 2;
  Offset get _middle => Offset(_wheelRadius, _wheelRadius);

  void _down(Offset local) {
    final game = widget.game;
    _onOuterWheel = dialIsFineWheel(
      widget.faceSize,
      (local - _middle).distance,
    );
    _lastTouch = local;
    _wound = _onOuterWheel ? dialWoundFor(game) : game.now.toDouble();
    _forward = null;
    _deciding = 0;
    game.dialHeld = true;
  }

  /// One band per player: everything ahead of them, as a fraction of a band's
  /// worth of wheel from where the wheel is standing.
  ///
  /// [here] is the wheel's own position and not the clock's — see [_wheelNow].
  /// Clipped to the band rather than wrapped round it, and a segment the wheel
  /// is in the middle of is cut off at the near end, so what's drawn is what's
  /// left of it.
  static List<(List<(double, double)>, Color)> _bands(Game game, double here) {
    final clock = game.synthetic;
    return [
      for (var w = 0; w < game.players.length; w++)
        (
          [
            for (final s in clock.bandOf(w))
              if (s.end > here && s.start < here + _wheelSpan)
                (
                  max(0.0, (s.start - here) / _wheelSpan),
                  min(1.0, (s.end - here) / _wheelSpan),
                ),
          ],
          game.players[w].color,
        ),
    ];
  }

  void _drag(Offset local) {
    final game = widget.game;
    final turned = dialTurnFor(
      widget.faceSize,
      _lastTouch - _middle,
      local - _middle,
    );
    _lastTouch = local;
    if (!_onOuterWheel) {
      // The clock face is a clock, and winds time itself: smoothly, anywhere,
      // including into a future nobody has decided anything about. It's the
      // only way to wait for something — the rim can only step through things
      // that are going to happen, and waiting is the absence of one.
      _wound += turned / (2 * pi) * _dialTurn;
      // a floor and no ceiling: you can always wait, and you can never go back
      // before the level knows about
      _wound = max(_wound, game.earliestMoment.toDouble());
      game.headFor(_wound.round(), ClockPush.dial);
      return;
    }

    // The rim is a row of actions, and with nothing on the list there is
    // nothing to click through — an inert rim, rather than a rim that quietly
    // goes back to being a clock.
    final band = dialBand(game);
    if (band.isEmpty) return;

    // The wheel goes where the thumb puts it, and everything else is worked
    // out from where it ends up.
    _wound += turned / (2 * pi) * _wheelSpan;
    // and stops at the ends of the list rather than winding off into nothing
    // — see [dialWoundFor], which is the same two bounds
    _wound = _wound.clamp(band.first.start - 1, band.last.end + 1);

    // a thumb landing on the rim moves a pixel or two of its own accord, and
    // that isn't a direction. Settled once, and it holds for the turn.
    if (_forward == null) {
      _deciding += turned;
      if (_deciding.abs() < _dialSnapDeadzone) return;
      _forward = _deciding > 0;
    }
    final to = dialStopAt(game, _wound, _forward!);
    if (to != null) game.headFor(to, ClockPush.dial);
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    // NoBackSwipe for the same reason the move pad has it: a drag that starts
    // near the left edge is a drag, not a page back
    return NoBackSwipe(
      GestureDetector(
        // deferToChild, not opaque: the widget is a five-hundred-pixel square
        // and almost all of it is map. What counts as the dial is decided by
        // [_DialWheelPainter.hitTest], which is the face and the rim and
        // nothing in between.
        behavior: HitTestBehavior.deferToChild,
        // the one thing they're in the middle of, or about to start — not
        // the whole list. Tapping again takes the next one.
        onTapUp: (_) => game.headFor(
          game.nextActionEndsAt(game.selectedPlayer.peek()),
          ClockPush.ease,
        ),
        onPanDown: (d) => _down(d.localPosition),
        onPanUpdate: (d) => _drag(d.localPosition),
        onPanEnd: (_) => game.dialHeld = false,
        onPanCancel: () => game.dialHeld = false,
        child: ValueListenableBuilder(
          valueListenable: widget.frame,
          builder: (context, _, _) => CustomPaint(
            size: Size.square(_box),
            painter: _DialWheelPainter(
              // What each player has still to do, a segment per thing they're
              // going to do: the only sign on screen that there's a future to
              // wind forward into, and with everyone on the wheel it also says
              // at a glance which of them you've left behind.
              //
              // Read off [SyntheticClock], so what's drawn is exactly what a
              // thumb on the rim winds through — including the room made for
              // the instant actions, which are most of them and which a wheel
              // showing plain time would draw as nothing at all.
              ahead: _bands(game, _wheelNow(game)),
              wheel: paletteSignal.value.pad,
              width: widget.faceSize * _wheelWidthFactor,
              faceRadius: widget.faceSize / 2,
            ),
            child: SizedBox.square(
              dimension: _box,
              child: Center(
                child: Builder(
                  builder: (context) {
                    final was = _lastShown;
                    _lastShown = game.now;
                    return clockFace(
                      game.now,
                      size: widget.faceSize,
                      sweptFrom: was,
                      digits: true,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class const _DialWheelPainter({
  /// One band per player, innermost first, and what colour they are. Each band
  /// is the things that player still has to do, as (start, end) pairs of a
  /// band's worth of wheel — see [_TimeDialState._bands]. Already clipped to
  /// 0..1, already in order.
  required final List<(List<(double, double)>, Color)> ahead,
  required final Color wheel,
  required final double width,
  required final double faceRadius,
}) extends CustomPainter {
  /// What the dial will take a finger on: the clock face, and a band across
  /// the rim wide enough to grab.
  ///
  /// The widget is a square as wide as the wheel, and if it swallowed
  /// everything inside it the dial would eat most of the map — so the gap
  /// between the face and the rim is left alone, and taps there go to the map
  /// that is drawn there.
  @override
  bool hitTest(Offset position) {
    final reach = dialWheelRadius(faceRadius * 2);
    return dialTakesTouch(
      faceRadius * 2,
      (position - Offset(reach, reach)).distance,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    // the same rim the hit test uses, so what's drawn is what's grabbable
    final outer = dialRimRadius(faceRadius * 2);
    canvas.drawCircle(
      c,
      outer,
      Paint()
        ..color = wheel
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );

    // The bands share the wheel's width between them. Thin, because a hair of
    // colour along the rim is enough to say "this one still has somewhere to
    // be", which is all they're for. No end caps: a cap on a band this thin
    // is a blob, and a blob at the start of every arc reads as a mark on the
    // dial rather than as the end of something.
    final each = width / ahead.length;
    for (var i = 0; i < ahead.length; i++) {
      final (segments, color) = ahead[i];
      final r = outer - width / 2 + each * (i + 0.5);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = each * 0.4;
      for (final (from, to) in segments) {
        final sweep = (to - from) * 2 * pi;
        // Every segment gives up its last few degrees, so that a row of
        // instant actions reads as a row rather than as one long arc. Never
        // more than [_segmentGapMax] of it: a segment eaten by its own gap
        // would be a thing you did that left no mark.
        final drawn = sweep - min(_segmentGap, sweep * _segmentGapMax);
        if (drawn <= 0) continue;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          _dialStartAngle + _dialSweepSign * from * 2 * pi,
          _dialSweepSign * drawn,
          false,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DialWheelPainter old) {
    if (old.wheel != wheel ||
        old.width != width ||
        old.faceRadius != faceRadius ||
        old.ahead.length != ahead.length) {
      return true;
    }
    // by hand, because the lists inside the records are compared by identity
    // and these are built fresh every frame
    for (var i = 0; i < ahead.length; i++) {
      final (segments, color) = ahead[i];
      final (was, wasColor) = old.ahead[i];
      if (color != wasColor || segments.length != was.length) return true;
      for (var k = 0; k < segments.length; k++) {
        if (segments[k] != was[k]) return true;
      }
    }
    return false;
  }
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
          color: paletteSignal.value.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    ),
  );
}

/// An inventory-style item slot, used by the inventory row and storage
/// controls. [count] is for the one control that stands for more than what's
/// in front of it — an inbox's slots are the whole map's outboxes gathered
/// into one per item, so they carry the number the way an item icon does.
Widget slotBox({
  Item? item,
  int count = 1,
  VoidCallback? onTap,
  double dim = 26,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: dim,
      height: dim,
      decoration: BoxDecoration(
        color: paletteSignal.value.surface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: item != null
          ? Center(
              child: quantityWidget(Quantity(item, count), size: dim * 0.7),
            )
          : null,
    ),
  );
}

/// The move control: tap and drag in the direction of the wire you want.
/// Used for player moves and for scheduling trains from stations/inside.
class const DragDirectionPad({
  super.key,
  required final void Function(double angle) onAngle,
  final bool enabled = true,
  final Widget? label, // centered
  final String? cornerText, // bottom right, e.g. 'drag to move'
  final double? dimension, // null = expand
}) extends StatefulWidget {
  @override
  State<DragDirectionPad> createState() => _DragDirectionPadState();
}

/// How far the thumb has to fall below its own top speed before the pad will
/// take another step. Relative rather than an absolute speed, so it works the
/// same for someone flicking and someone dragging slowly — what it's looking
/// for is a lull, and a lull is a fraction of whatever pace they were setting.
const double _padRearmFraction = 0.4;

/// how quickly the measured speed follows the thumb: one frame of a drag is a
/// noisy thing to divide by a frame time
const double _padSpeedBlend = 0.45;

class _DragDirectionPadState extends State<DragDirectionPad> {
  Offset _acc = Offset.zero;

  /// A drag that keeps going is one gesture, not a stream of them. Sliding a
  /// thumb across the pad used to fire a step every time the accumulated
  /// distance crossed the threshold, which meant one long swipe sent a player
  /// three nodes away. So after a step the pad shuts, and only opens again
  /// once the thumb has slowed right down — one deliberate push per step.
  bool _armed = true;
  double _speed = 0, _peakSpeed = 0;
  Duration? _lastStamp;

  void _reset() {
    _acc = Offset.zero;
    _armed = true;
    _speed = 0;
    _peakSpeed = 0;
    _lastStamp = null;
  }

  void _update(DragUpdateDetails d, double threshold) {
    final stamp = d.sourceTimeStamp;
    final dt = (stamp != null && _lastStamp != null)
        ? (stamp - _lastStamp!).inMicroseconds / 1e6
        : 1 / 60;
    _lastStamp = stamp;
    _speed =
        _speed * (1 - _padSpeedBlend) +
        (dt > 0 ? d.delta.distance / dt : 0.0) * _padSpeedBlend;
    _acc += d.delta;

    if (!_armed) {
      _peakSpeed = max(_peakSpeed, _speed);
      // the lull. Whatever they were doing, they've stopped doing it
      if (_speed < _peakSpeed * _padRearmFraction) {
        _armed = true;
        _peakSpeed = 0;
        _acc = Offset.zero;
      }
      return;
    }
    if (_acc.distance <= threshold) return;
    // the first step of a gesture goes on distance alone — a slow, deliberate
    // drag from a standstill is exactly what it looks like. Every step after
    // it has a lull behind it by construction.
    widget.onAngle(offsetAngle(_acc));
    _acc = Offset.zero;
    _armed = false;
    _peakSpeed = _speed;
  }

  @override
  Widget build(BuildContext context) {
    final threshold = Thumbspan.of(context) * 0.27;
    Widget pad = Container(
      decoration: BoxDecoration(
        color: paletteSignal.value.pad,
        borderRadius: BorderRadius.circular(10),
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
                style: TextStyle(
                  fontSize: 11,
                  color: paletteSignal.value.inkFaint,
                ),
              ),
            ),
        ],
      ),
    );
    // its whole job is dragging; the page's back swipe doesn't get to take one
    pad = NoBackSwipe(
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => _update(details, threshold),
        onPanEnd: (_) => _reset(),
        onPanCancel: _reset,
        child: pad,
      ),
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
class const PlayerOrb(
  final Game game,
  final Player player, {
  super.key,
  final double orbSize = nodeIconSize * 1.4,
  final bool showName = true,
  final VoidCallback? onTap,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SignalBuilder(
        builder: (context) {
          final selected = game.selectedPlayer.value.isSameAs(player);
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
                        ? Border.all(color: paletteSignal.value.ink, width: 2)
                        : null,
                  ),
                ),
                pie: CountdownPie(
                  game: game,
                  endsAt: () => player.incapacitatedUntil.value,
                  total: game.params.muggerIncapTime,
                  isCooldown: true,
                ),
              ),
              if (showName)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: paletteSignal.value.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: player.color,
                      width: selected ? 1.6 : 0.8,
                    ),
                  ),
                  child: Text(
                    player.name,
                    style: TextStyle(
                      fontSize: 9,
                      color: paletteSignal.value.ink,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// the train's own badge, shown in its node widget
Widget trainBadge(Game g, TrainNode t, NodeZoomLevel level) {
  return SignalBuilder(
    builder: (context) {
      final inTransit = t.dockedAt.value == null;
      Widget badge = badgeRow(tone: nodeColor(t), [
        badgeIcon(Icons.train),
        if (level != NodeZoomLevel.small) ...[
          if (t.activation != null)
            quantityWidget(t.activation!, size: _facilityItemSize),
          if (t.movableFromInside) badgeIcon(Icons.swipe_right_alt),
          if (t.schedule is OneWaySchedule) badgeText('sc(o)'),
          if (t.schedule case CycleSchedule c)
            badgeText('sc(${fmtSpan(c.period)})'),
        ],
        if (inTransit)
          badgeText(fmtSpan(max(0, (t.arrivesAt.value ?? 0) - g.clock.value))),
      ]);
      // cycle trains show a countdown pie to their next departure, plus the
      // clock time their interval is pinned to
      if (t.schedule case CycleSchedule c) {
        badge = withPie(
          badge,
          pie: CountdownPie(
            game: g,
            endsAt: () => t.departsAt.value,
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
    },
  );
}

List<InlineSpan> describeTrain(TrainNode t) {
  // a Never train has nothing to say about its schedule — it just sits there
  final schedule = switch (t.schedule) {
    NeverSchedule _ => const <InlineSpan>[],
    OneWaySchedule _ => [
      tipText('; returns home on its own shortly after arriving'),
    ],
    CycleSchedule c => [
      tipText('; shuttles on its own '),
      ...describeClockSpans(c.interval),
    ],
  };
  return [
    tipText('a train'),
    ...schedule,
    if (t.activation != null) ...[
      tipText('; moving it requires holding '),
      ...quantitySpans(t.activation!),
      if (t.activationConsumed) tipText(', which it takes'),
    ],
    if (t.movableFromInside) tipText('; can be moved from inside'),
  ];
}

// ────────────────────────────── screen ──────────────────────────────

class const TrainscapeScreen({
  super.key,

  /// generate this level rather than picking up the saved one. Passing a seed
  /// is asking for a particular map, which a save would only get in the way of
  final int? seed,
  // signal-tracked: the screen is built against [paletteSignal] and has to
  // follow it
}) extends SignalStatefulWidget {
  @override
  State<TrainscapeScreen> createState() => _TrainscapeScreenState();
}

class _TrainscapeScreenState extends State<TrainscapeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// null until the saved level has been read back off disk, which is a
  /// database round trip. Everything below build's early return has a level
  Game? _game;
  Game get game => _game!;
  late int _seed;
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  Duration _last = Duration.zero;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  /// what the controls are describing, read once a frame in the ticker —
  /// see [Game.readControls]
  final ValueNotifier<PanelView?> _panel = ValueNotifier(null);
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
    WidgetsBinding.instance.addObserver(this);
    _followPlatformBrightness();
    _open();
  }

  @override
  void didChangePlatformBrightness() => _followPlatformBrightness();

  /// on hot reload too, so a scheme changed while the screen sat there open
  /// doesn't wait for the screen to be reopened
  @override
  void reassemble() {
    super.reassemble();
    _followPlatformBrightness();
  }

  /// The scheme follows the system's light/dark setting. The platform is asked
  /// directly rather than through a [MediaQuery] because every call site here
  /// is deliberately outside build: writing [paletteSignal] during a build
  /// would be dirtying the widgets subscribed to it in the middle of the frame
  /// that's building them.
  void _followPlatformBrightness() => paletteSignal.value = platformPalette();

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

  /// The one place real time enters the game. The frame's wall-clock delta is
  /// clamped first — a long frame, or coming back from the background, must
  /// not teleport the world — and handed to [Game.tickRealTime], which is the
  /// last thing in the game that knows what a real second is.
  void _tick(Duration elapsed) {
    final real = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1 / 15);
    _last = elapsed;
    game.tickRealTime(real);
    _panel.value = game.readControls();
    _frame.value++;
  }

  @override
  void dispose() {
    if (_game != null) saveLevel(game);
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle.dispose();
    _ticker.dispose();
    _frame.dispose();
    _panel.dispose();
    _recenterNudge.dispose();
    super.dispose();
  }

  void _newGame(int seed) {
    setState(() {
      _seed = seed;
      _game = generateLevel(Parameters.levelOne(_seed));
    });
  }

  /// Everything below is built against [paletteSignal], and this build is
  /// signal-tracked — see [SignalStatefulWidget] — so reading the scheme for
  /// the scaffold's own colour is what rebuilds the lot when the system flips.
  /// It's a rebuild, not a restructure: the tree keeps its shape, so the world
  /// view's state — the player's zoom and pan — rides through the change. The
  /// node widgets the map caches are the exception, and subscribe for
  /// themselves.
  @override
  Widget build(BuildContext context) {
    if (_game == null) return ColoredBox(color: paletteSignal.value.ground);
    return EscapeToPop(
      child: Scaffold(
        backgroundColor: paletteSignal.value.ground,
        body: SafeArea(
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > constraints.maxHeight;
                  // The dial is sized off the map, and the map's size is known
                  // here and nowhere further in: a [Positioned] that names only
                  // two edges hands its child unbounded constraints, so asking
                  // from down inside the stack gets infinity back.
                  final world = Expanded(
                    child: LayoutBuilder(
                      builder: (context, mapBox) {
                        // off the narrower side, so it's the same clock held
                        // the same way round in either orientation
                        final dialFace =
                            min(mapBox.maxWidth, mapBox.maxHeight) *
                            dialFaceSpan;
                        return Stack(
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
                            Positioned(
                              // less the touch area [mapButton] carries, so the
                              // button looks where it always did
                              right: mapButtonInset - mapButtonTouch,
                              bottom: mapButtonInset - mapButtonTouch,
                              child: _pauseButton(),
                            ),
                            // hard into the corner: the wheel drawn round it
                            // runs off the bottom and both sides, which is the
                            // point of it — see [TimeDial]
                            Positioned(
                              // The dial widget is the whole wheel, so it
                              // hangs off the corner by everything that isn't
                              // the clock — the face ends up sitting where it
                              // looks like it is, a little in from both edges.
                              left:
                                  dialFace / 2 +
                                  dialPadding -
                                  dialFace * _wheelRadiusFactor,
                              bottom:
                                  dialFace / 2 +
                                  dialPadding -
                                  dialFace * _wheelRadiusFactor,
                              child: TimeDial(
                                game: game,
                                frame: _frame,
                                faceSize: dialFace,
                              ),
                            ),
                            Positioned.fill(child: _announcement()),
                          ],
                        );
                      },
                    ),
                  );
                  final controls = isWide
                      ? SizedBox(
                          width: 340,
                          child: ControlsPanel(
                            game: game,
                            view: _panel,
                            recenterNudge: _recenterNudge,
                          ),
                        )
                      : SizedBox(
                          height: 210,
                          child: ControlsPanel(
                            game: game,
                            view: _panel,
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
      ),
    );
  }

  /// the big transient caps message, centered over the world
  Widget _announcement() => SignalBuilder(
    builder: (context) {
      final a = game.announcement.value;
      if (a == null) return const SizedBox.shrink();
      return IgnorePointer(
        child: Center(
          // the victims lead the message in the same orbs they're drawn with on
          // the map, so it reads as one line: <Rudy> MUGGED
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final p in a.$2)
                PlayerOrb(game, p, orbSize: nodeIconSize * 1.2),
              Text(
                a.$1,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  color: paletteSignal.value.ink,
                  shadows: [
                    Shadow(color: paletteSignal.value.ground, blurRadius: 8),
                    Shadow(color: paletteSignal.value.ground, blurRadius: 14),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  /// The bottom one of the stack in the world's bottom right corner; the zoom
  /// button the world view puts up sits directly above it.
  Widget _pauseButton() => SignalBuilder(
    builder: (context) {
      final paused = game.paused.value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => game.paused.value = !paused,
        child: mapButton(paused ? Icons.play_arrow : Icons.pause),
      );
    },
  );

  Widget _hud() {
    return SignalBuilder(
      builder: (context) {
        // The standing orders, and nothing else. The hour used to lead this
        // line as well, back when the dial was a sixteen-pixel token up here
        // — but the clock is a great dial in the corner now with the time
        // written across its own face, and a second reading of it in the
        // opposite corner is one more thing to check against.
        //
        // The days left are still read off [Game.now], which is a plain field,
        // so this is what subscribes the line to it — it used to come for free
        // from a timeLeft signal, back when the level counted its remaining
        // time down instead of working it out; see [Game.timeLeft].
        game.clock.value;
        final hudStyle = TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: paletteSignal.value.ink,
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
                child: Icon(
                  Icons.arrow_back,
                  size: 20,
                  color: paletteSignal.value.ink,
                ),
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
      },
    );
  }

  Widget _phaseOverlay() {
    return SignalBuilder(
      builder: (context) {
        final phase = game.phase.value;
        if (phase == GamePhase.playing) return const SizedBox.shrink();
        final won = phase == GamePhase.won;
        return Positioned.fill(
          child: ColoredBox(
            color: paletteSignal.value.scrim,
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
                      color: paletteSignal.value.ink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // these are the only Material-styled things on the screen, and
                  // the surrounding app's theme follows the device rather than
                  // the time of day in here, so they're told what ink to use
                  TextButtonTheme(
                    data: TextButtonThemeData(
                      style: TextButton.styleFrom(
                        foregroundColor: paletteSignal.value.ink,
                      ),
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
      },
    );
  }
}

// ────────────────────────────── controls panel ──────────────────────────────

/// The world as the controls are describing it — a moment that is usually now
/// and sometimes a little way off; see [Game.readControls].
///
/// Plain values and already-built widgets, read once in the ticker. It exists
/// because the panel can't ask the world questions itself: the answers it
/// wants are from a moment the world isn't at, and getting there and back
/// means writing to every signal in the level, which is not something to do
/// halfway through a build.
class const PanelView({
  required final TTime at,
  required final Node? node,
  required final List<Item> inventory,
  required final bool canMove,
  required final bool hasStorage,
  required final List<Widget> actions,
});

class const ControlsPanel({
  super.key,
  required final Game game,
  required final ValueNotifier<PanelView?> view,
  required final ValueNotifier<int> recenterNudge,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: paletteSignal.value.panel,
      padding: const EdgeInsets.all(6),
      child: ValueListenableBuilder(
        valueListenable: view,
        builder: (context, v, _) {
          if (v == null) return const SizedBox.shrink();
          final sel = game.selectedPlayer.peek();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _inventoryRow(sel, v),
                    const SizedBox(height: 6),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: v.actions,
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
                    enabled: v.canMove,
                    onAngle: (a) => game.dragPlayerMove(sel, a),
                    // the instruction at the bottom right, the move icon in the
                    // center
                    label: Icon(
                      Icons.swipe_right_alt,
                      color: paletteSignal.value.inkFaint,
                      size: 28,
                    ),
                    cornerText: 'drag to move',
                  ),
                ),
              const SizedBox(width: 6),
              SizedBox(width: 64, child: _roster()),
            ],
          );
        },
      ),
    );
  }

  /// The hand as it will be when the player can next act on it, out of
  /// [PanelView] — but the red flash of being robbed comes off the live clock,
  /// because that's a thing that just happened rather than a thing about to.
  Widget _inventoryRow(Player p, PanelView v) {
    final inv = v.inventory;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < game.params.inventoryCap; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          slotBox(
            item: i < inv.length ? inv[i] : null,
            onTap: v.hasStorage && i < inv.length
                ? () => game.commit(
                    p,
                    StoreAction(inv[i], notBefore: game.actionMoment),
                  )
                : null,
          ),
        ],
      ],
    );
    return SignalBuilder(
      builder: (context) {
        final redness = p.flash.flashingAt(game.now, game.params.redFlashSpan)
            ? p.flash.rednessAt(game.clock.value, game.params.redFlashSpan)
            : 0.0;
        if (redness <= 0) return row;
        return Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.55 * redness),
            borderRadius: BorderRadius.circular(8),
          ),
          child: row,
        );
      },
    );
  }

  Widget _roster() {
    return SignalBuilder(
      builder: (context) {
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
                    game.select(p);
                    recenterNudge.value++;
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

// ────────────────────────────── world view ──────────────────────────────

/// The face of one of the buttons stacked in the world's bottom right corner,
/// against the map rather than the HUD line: it wears the controls' panel
/// colour so it reads as a control and not as one more thing drawn on the
/// ground. The caller supplies the gesture handling.
/// The padding outside the decoration is not spacing — the caller's positions
/// are pulled in by the same amount to cancel it — it's touch area. A button
/// this size is a small thing to hit with a thumb, and the space around it was
/// doing nothing.
Widget mapButton(IconData icon) => Padding(
  padding: const EdgeInsets.all(mapButtonTouch),
  child: Container(
    padding: const EdgeInsets.all(mapButtonPad),
    decoration: BoxDecoration(
      color: paletteSignal.value.panel,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(icon, size: mapButtonIcon, color: paletteSignal.value.ink),
  ),
);

class const WorldView({
  super.key,
  required final Game game,
  required final Listenable frame,
  required final ValueNotifier<int> recenterNudge,
}) extends StatefulWidget {
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
  double get _camElapsed => _camClock.elapsedMicroseconds / 1e6 - _camSegStart;

  /// where the camera has got to, without asking it to go anywhere new
  Offset get _camNow {
    final t = _camElapsed;
    return Offset(_camX.x(t), _camY.x(t));
  }

  Offset _seekCam(Offset follow) {
    if (_camFollow != follow) {
      final t = _camElapsed;
      _camX.target(follow.dx + _userPan.dx, time: t);
      _camY.target(follow.dy + _userPan.dy, time: t);
      _camSegStart = _camClock.elapsedMicroseconds / 1e6;
      _camFollow = follow;
    }
    return _camNow;
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

  /// the last [Game.recenterWanted] this view has acted on
  int _recenterSeen = 0;

  /// Drops the user's pan and seeks the followed point again. The follow point
  /// itself hasn't moved, so [_seekCam] wouldn't notice on its own — clearing
  /// it is what asks for the new segments. Also drops any zoom button's claim
  /// on where the camera looks — a recenter always means "follow the selected
  /// player" again, which is what asked for it.
  void _recenter() {
    _userPan = Offset.zero;
    _camFollow = null;
    _forcedCamTarget = null;
  }

  /// Set by [_cycleZoom] when it lands on the whole-map stop, so the camera
  /// looks at the map's center instead of following the selected player —
  /// otherwise the player's position within the map, not the map itself,
  /// would decide what's on screen. Cleared by any other stop, and by
  /// [_recenter].
  Offset? _forcedCamTarget;

  /// The one way the zoom is set outside the pinch, which owns its own
  /// clamping: everything the button does goes through here.
  void _setZoom(Game game, double zoom) {
    _zoom = zoom.clamp(game.zoomMin, game.zoomMax).toDouble();
    _updateFarZoom();
  }

  /// The button's three stops, from closest in to furthest out. The last is the
  /// whole map — as much of it as the view can hold at once — which is why
  /// these are worked out against the live size rather than being constants:
  /// what fits depends on the level's bounds and the shape of the screen.
  List<double> _zoomStops(Game game, Size size) {
    final viewShort = min(size.width, size.height);
    final fullMap = min(
      size.width / _worldRect.width,
      size.height / _worldRect.height,
    );
    return [
      viewShort / zoomHighSpan,
      viewShort / zoomMediumSpan,
      fullMap,
    ].map((z) => z.clamp(game.zoomMin, game.zoomMax).toDouble()).toList();
  }

  /// A tap advances one step from wherever the view actually is, rather than
  /// off a count of its own: it finds the stop closest to the current zoom —
  /// in log space, since zoom is a ratio, not a distance — and moves to the
  /// one after it, wrapping past the far stop back to the near one. That way a
  /// pinch or a drag that's left the stops behind still gets a sensible next
  /// step, wherever it landed, rather than a jump decided by which side of a
  /// threshold it happened to be on.
  void _cycleZoom(Game game, Size size) {
    final stops = _zoomStops(game, size);
    final logZoom = log(_zoom!);
    var nearest = 0;
    var nearestDist = double.infinity;
    for (var i = 0; i < stops.length; i++) {
      final dist = (log(stops[i]) - logZoom).abs();
      if (dist < nearestDist) {
        nearestDist = dist;
        nearest = i;
      }
    }
    final next = (nearest + 1) % stops.length;
    _setZoom(game, stops[next]);
    // the last stop is however much zoom fits the whole map, so landing on it
    // is asking to see the whole thing — centered on it, not on wherever the
    // selected player happens to be standing within it
    if (next == stops.length - 1) {
      _forcedCamTarget = _worldRect.center;
    } else {
      _forcedCamTarget = null;
    }
  }

  /// dy accumulated over the drag in flight, so the zoom is always a factor on
  /// what it was when the finger went down: a drag that runs into the far end
  /// of the range and comes back gives back exactly what it took.
  double _zoomDragDy = 0;

  Widget _zoomButton(Game game, Size size) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _cycleZoom(game, size),
    onVerticalDragStart: (_) {
      _zoomAtGestureStart = _zoom!;
      _zoomDragDy = 0;
    },
    onVerticalDragUpdate: (d) {
      _zoomDragDy += d.primaryDelta ?? 0;
      _setZoom(game, _zoomAtGestureStart * exp(_zoomDragDy * zoomDragPerPixel));
    },
    child: mapButton(Icons.zoom_out_map),
  );

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
        // the pan is the map's; there's the HUD's back arrow for leaving
        return NoBackSwipe(
          Stack(
            children: [
              Positioned.fill(child: _map(game, size)),
              // one gap above the pause button, which the screen puts at the
              // same inset in the corner this view fills
              Positioned(
                right: mapButtonInset - mapButtonTouch,
                bottom:
                    mapButtonInset +
                    mapButtonExtent +
                    mapButtonGap -
                    mapButtonTouch,
                child: _zoomButton(game, size),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _map(Game game, Size size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _tapWorld(game, d.localPosition, size),
      onScaleStart: (d) => _zoomAtGestureStart = _zoom!,
      onScaleUpdate: (d) {
        // both gestures amplified 3x: pans move three times as far,
        // pinches zoom as scale cubed (about the view center for now)
        _panCam(-d.focalPointDelta * 3 / _zoom!);
        // a pinch or a manual pan on the map itself is the player taking the
        // camera back from whatever the zoom button asked for
        _forcedCamTarget = null;
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
            // moving to, rather than tracking them along the wire. While a
            // jump is being aimed it stops following altogether: the
            // player is deliberately looking somewhere else on the map,
            // and a camera that pulled them back to their own feet would
            // be arguing with them about it.
            final sel = game.selectedPlayer.value;
            final aiming = game.jumping.value != null;
            final wanted = game.recenterWanted.peek();
            if (_recenterSeen != wanted) {
              _recenterSeen = wanted;
              _recenter();
            }
            // The camera only chases someone it can already see. Once the
            // clock can be wound, the selected player is often somewhere the
            // user isn't looking — replaying a walk from ten minutes ago
            // across the far side of the map — and a view that leapt after
            // every step of theirs would be dragging the user away from
            // whatever they were reading. Being asked outright to recentre
            // (a jump, the whole-map view) still counts; that isn't a step.
            final zoom = _zoom!;
            final where = sel.worldPos(game.now) - _camNow;
            final watching =
                _camFollow == null ||
                max((where.dx * zoom).abs(), (where.dy * zoom).abs()) <
                    size.shortestSide / 2;
            final follow =
                _forcedCamTarget ??
                (watching
                    ? (sel.traversalTarget?.pos ?? sel.worldPos(game.now))
                    : _camFollow!);
            final cam = aiming
                ? Offset(_camX.endValue, _camY.endValue)
                : _seekCam(follow);
            _lastCam = cam;
            final viewCenter = size.center(Offset.zero);
            Offset project(Offset world) => (world - cam) * zoom + viewCenter;
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
            Offset inLayer(Offset world) => (world - _worldRect.topLeft) * zoom;

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
                      cullRect.contains(project(p.worldPos(game.now))))
                    _positioned(
                      project(p.worldPos(game.now)),
                      PlayerOrb(game, p),
                    ),
                if (tip != null && cullRect.contains(project(tip.$2.pos)))
                  _tooltipBubble(project(tip.$2.pos), tip.$3, tip.$2),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Where the camera was left the last time a frame was laid out, so that a
  /// tap can be turned back into a place on the map. The projection lives
  /// inside the frame builder, which a gesture callback isn't inside.
  Offset _lastCam = Offset.zero;

  /// A tap on the world. Ordinarily it just dismisses the tooltip; while a jump
  /// is being aimed it's the aim itself — the nearest node under the finger, if
  /// it's one this station can reach, and otherwise a tap that backs out. The
  /// node's dot is what's being hit here; a tap that landed on a badge went
  /// through [Game.toggleTooltip] instead and never reached this.
  void _tapWorld(Game game, Offset local, Size size) {
    if (game.jumping.peek() == null) {
      game.tooltip.value = null;
      return;
    }
    final zoom = _zoom!;
    final world = (local - size.center(Offset.zero)) / zoom + _lastCam;
    Node? nearest;
    var bestPx = _jumpTapRadius;
    for (final n in game.nodes) {
      final px = (n.pos - world).distance * zoom;
      if (px < bestPx) {
        bestPx = px;
        nearest = n;
      }
    }
    if (nearest == null || !game.tryJumpTo(nearest)) game.cancelJump();
  }

  /// how close to a node's dot a tap has to land to count as aiming at it
  static const double _jumpTapRadius = 28;

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
                  border: Border.all(
                    color: paletteSignal.value.outlineStrong,
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(color: paletteSignal.value.shadow, blurRadius: 6),
                  ],
                ),
                child: Text.rich(
                  TextSpan(
                    children: spans,
                    style: TextStyle(
                      fontSize: 11,
                      color: paletteSignal.value.ink,
                    ),
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

class _WorldPainter({
  required final Game game,
  required final Offset cam,
  required final double zoom,
  required final Offset viewCenter,

  /// non-null only when the zoomed-out overlay is going to want a copy
  final GraphRecording? recording,
}) extends CustomPainter {
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

  /// While a jump is being aimed, the nodes it can't reach wash most of the way
  /// out to the background and the ones it can keep their colour, so the choice
  /// reads off the map itself rather than out of something drawn over it. Like
  /// the blight's dormant states, it recedes by mixing towards the ground: a
  /// graph that went transparent instead would tint whatever it was over.
  Color _nodeColor(Node n) {
    final base = nodeColor(n);
    final j = game.jumping.peek();
    if (j == null || j.$1.isTarget(n, j.$2)) return base;
    return Color.lerp(base, paletteSignal.value.ground, _aimWash)!;
  }

  static const double _aimWash = 0.72;

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
      paletteSignal.value.ground,
      paletteSignal.value.blightWash,
    )!;
    for (final b in game.blights) {
      final color = b.flash.flashingAt(game.now, game.params.redFlashSpan)
          ? Color.lerp(blightBase, Colors.red, 0.5)!
          : b.dormant
          ? Color.lerp(blightBase, paletteSignal.value.ground, 0.55)!
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
      trainEdgePaint.color = _nodeColor(t);
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
        [_nodeColor(e.a), _nodeColor(e.b)],
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
      nodePaint.color = _nodeColor(n);
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
class _OverGraphPainter(final GraphRecording recording, final double opacity)
    extends CustomPainter {
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

/// The facilities packed into a block left of the node's dot and the players
/// present in a column right of it — but only while both are there to straddle
/// it; alone, either sits on the dot. Straddling rather than centring one wide
/// row keeps each side's inner edge anchored to the dot regardless of what the
/// other side is doing. Rerenders via the playersPresent signal.
class const NodeContentWidget({
  super.key,
  required final Game game,
  required final Node node,
  required final Signal<bool> farZoom,

  // Signal-tracked rather than plain, and not for the sake of tidiness: these
  // widgets are cached by node and handed back to the stack as the same
  // instance every frame, so a rebuild from above passes them by. Everything
  // this build reads — who's standing here, the zoom level, and the scheme the
  // badges under it are coloured from — it has to subscribe to itself.
}) extends SignalWidget {
  @override
  Widget build(BuildContext context) {
    final players = node.playersPresent.value;
    final level = farZoom.value ? NodeZoomLevel.small : NodeZoomLevel.normal;
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
    // Packed rather than stacked in a column: badge widths vary by a lot —
    // a landing station is one icon wide and a stocked trader is a row of
    // half a dozen — so a column of them is as wide as the widest badge, as
    // tall as all of them put together, and mostly empty. [PackedBox] fits
    // them into the smallest roughly-square box it can find instead, which
    // for a node carrying more than two facilities is a fraction of the area.
    //
    // Right-aligned while a player column is beside it, so the badges' right
    // edges line up on the dot and the ragged edge faces away from it; with
    // the node to themselves the whole box is centred on the dot anyway, so
    // the packer's own left-alignment is the tidier way round.
    final facilityCluster = facilityBadges.isEmpty
        ? null
        : PackedBox(
            gap: 2,
            rightAligned: players.isNotEmpty,
            children: facilityBadges,
          );
    final playerColumn = players.isEmpty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in players)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: PlayerOrb(game, p, onTap: () => game.select(p)),
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
    final content = facilityCluster == null || playerColumn == null
        ? facilityCluster ?? playerColumn ?? const SizedBox.shrink()
        : Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                widthFactor: 2,
                child: Padding(
                  padding: const EdgeInsets.only(right: _nodeSplitGap),
                  child: facilityCluster,
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
  }
}
