// trainscape's boilerplate: the parts of it with no design in them. The
// sampling utilities level generation draws through, the number formatting the
// UI reads out, and the level's save format — a few hundred lines of "write
// each field down, then read each field back", which in a language with
// reflection or codegen wouldn't be handwritten at all (type_help.dart says
// the same thing about the timer side of the app). It's here so that
// trainscape.dart can be about the game.
//
// A part rather than a library of its own: writing a level down means reaching
// into the private state of the things being written — which repetition a tree
// was picked in, where a train is between two stations — and that state has no
// business being public just because the file it's serialized in is a
// different one.

part of 'trainscape.dart';

// ────────────────────────────── rng & generation utilities ──────────────────────────────

/// Our own PRNG (mulberry32) rather than dart:math's Random, so that level
/// generation is reproducible bit-for-bit on any platform (including web,
/// where ints are doubles — all math here stays under 2^53).
class GameRng {
  int _state;
  GameRng(int seed) : _state = seed & 0xffffffff;

  /// 32-bit multiply without overflowing double precision (the imul trick).
  static int _mul32(int a, int b) =>
      (((a & 0xffff) * b) + ((((a >>> 16) * b) & 0xffff) << 16)) & 0xffffffff;

  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & 0xffffffff;
    int t = _state;
    t = _mul32(t ^ (t >>> 15), t | 1);
    t = (t ^ (t + _mul32(t ^ (t >>> 7), t | 61))) & 0xffffffff;
    return (t ^ (t >>> 14)) & 0xffffffff;
  }

  /// in [0, 1)
  double nextDouble() => nextUint32() / 4294967296.0;

  int nextInt(int max) =>
      max <= 0 ? 0 : min((nextDouble() * max).floor(), max - 1);

  bool chance(double p) => nextDouble() < p;
}

double rangeIn(GameRng rng, double low, double high) =>
    low + rng.nextDouble() * (high - low);

/// [rangeIn] onto the tick grid. One rng draw, same as the double version, so
/// swapping one for the other doesn't shift the generation stream.
TTime rangeInTicks(GameRng rng, TTime low, TTime high) =>
    low + ticksOf(rng.nextDouble() * (high - low));

/// log-distributed int in [low, high]
int logUniformInt(GameRng rng, int low, int high) =>
    exp(rangeIn(rng, log(low.toDouble()), log(high.toDouble())))
        .round()
        .clamp(low, high);

/// Rolled durations land on a whole game minute. A tick is far finer than
/// anything the player can perceive or that a readout shows, so leaving them
/// unquantised would only mean two nominally identical traders resting for
/// imperceptibly different spans.
TTime roundToMinute(TTime v) => (v / gameMinute).round() * gameMinute;

T weightedPick<T>(GameRng rng, List<(double, T)> options) {
  final total = options.fold(0.0, (a, o) => a + o.$1);
  var roll = rng.nextDouble() * total;
  for (final (w, v) in options) {
    roll -= w;
    if (roll <= 0) return v;
  }
  return options.last.$2;
}

void shuffleInPlace<T>(GameRng rng, List<T> list) {
  for (var i = list.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final t = list[i];
    list[i] = list[j];
    list[j] = t;
  }
}

List<T> shuffledClone<T>(GameRng rng, List<T> list) {
  final c = List<T>.of(list);
  shuffleInPlace(rng, c);
  return c;
}

/// Draws from a shuffled bag, refilling and reshuffling once it runs dry — so
/// everything comes up once before anything comes up twice.
class _Bag<T>(final GameRng _rng, final List<T> _source) {
  List<T> _left = [];
  T draw() {
    if (_left.isEmpty) _left = shuffledClone(_rng, _source);
    return _left.removeLast();
  }
}

extension PopOrNull<T> on List<T> {
  T? popOrNull() => isEmpty ? null : removeLast();
}

/// Splits [total] into counts proportional to [weights], deviating from the
/// exact proportions as little as possible (largest-remainder apportionment) —
/// the distribution is well controlled even for small totals, rather than
/// being independently sampled.
List<int> apportionCounts(List<double> weights, int total) {
  final wsum = weights.fold(0.0, (a, b) => a + b);
  final exact = [for (final w in weights) w / wsum * total];
  final counts = [for (final e in exact) e.floor()];
  var remaining = total - counts.fold(0, (a, b) => a + b);
  final order = List.generate(weights.length, (i) => i)
    ..sort(
      (a, b) =>
          (exact[b] - exact[b].floor()).compareTo(exact[a] - exact[a].floor()),
    );
  for (var k = 0; k < remaining; k++) {
    counts[order[k % order.length]] += 1;
  }
  return counts;
}

// ────────────────────────────── number formatting ──────────────────────────────

String fmt1(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// A span of game time, in whichever of the game's units carries it: minutes
/// under an hour, hours under a day, days above that. Never rounds down to
/// nothing — a real span that reads as zero is indistinguishable from no span
/// at all.
String fmtSpan(TTime t) {
  final mins = max(1, (t / gameMinute).ceil());
  if (mins < 60) return '${mins}m';
  String rounded(double v) => fmt1((v * 10).roundToDouble() / 10);
  return t < gameDay ? '${rounded(t / gameHour)}h' : '${rounded(t / gameDay)}d';
}

/// a moment in the day as a 24-hour clock time
String fmtTimeOfDay(TTime t) {
  final mins = ((t % gameDay) / gameMinute).floor();
  return '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}';
}

/// The same, with the hour padded out — `07:05`, never `7:05`.
///
/// For the one place the time is read off a face rather than out of a
/// sentence: it's a fixed four digits that don't shuffle sideways as the hour
/// rolls over from nine to ten, which matters when it's sitting still under a
/// pair of moving hands.
String fmtTimeOfDayPadded(TTime t) {
  final mins = ((t % gameDay) / gameMinute).floor();
  return '${(mins ~/ 60).toString().padLeft(2, '0')}:'
      '${(mins % 60).toString().padLeft(2, '0')}';
}

// ────────────────────────────── snapshots ──────────────────────────────

/// The mutable half of a level, lifted out so the clock can be put back.
///
/// Not the save format. A save is a whole world written down as text, most of
/// it the parts that never change — the graph, the item catalogue, every icon
/// it composed — and it costs about 100KB and a parse. This is only what a
/// moment of play can alter: a few thousand fields, held as themselves rather
/// than as JSON, and restored into the very objects they came out of. Which is
/// what makes it cheap enough to keep a ring of them and what keeps
/// [identical] meaning something afterwards — no object in the level is
/// replaced by a snapshot, only refilled.
///
/// What's deliberately not in here is anything that belongs to the person
/// playing rather than to the world: which player is selected, what the camera
/// is doing, which node was last raised to the top of the pile. Winding the
/// clock back is meant to undo what happened, not to undo where they were
/// looking.
class GameSnapshot {
  final List<Object?> _cells;
  const GameSnapshot._(this._cells);

  /// how far in this was taken, for choosing which one to wind back to
  TTime get at => _cells[0] as TTime;

  /// how many fields it holds — for the test that keeps an eye on the size
  int get cellCountForTest => _cells.length;
}

/// Reads or writes one field, depending on which way round it was made.
///
/// One cursor for both directions on purpose: capture and restore are the same
/// list of fields in the same order, and the only way to be sure they stay
/// that way is for there to be one list. Two functions that had to be kept in
/// step would drift the first time a field was added to one of them, and the
/// symptom would be a rewind that silently puts one number into another
/// number's slot.
class _Cursor {
  final List<Object?> cells;
  final bool writing;
  int _i = 0;

  _Cursor.capturing() : cells = [], writing = true;
  _Cursor.restoring(this.cells) : writing = false;

  /// hands back [v] while capturing, or what was captured while restoring —
  /// so `x = c.io(x)` is a write on the way out and a read on the way in
  T io<T>(T v) {
    if (writing) {
      cells.add(v);
      return v;
    }
    return cells[_i++] as T;
  }

  /// the same for a signal. While capturing this assigns the value it just
  /// read, which signals treats as no change and doesn't announce.
  void sig<T>(Signal<T> s) => s.value = io(s.peek());
}

/// Takes down everything a moment of play can have changed.
GameSnapshot captureState(Game g) {
  final c = _Cursor.capturing();
  _syncState(c, g);
  return GameSnapshot._(c.cells);
}

/// Puts [s] back into [g]. Afterwards the level is the level it was when the
/// snapshot was taken, down to which wires exist, and [Game.advanceTo] can be
/// asked to play the same stretch again.
void restoreState(Game g, GameSnapshot s) =>
    _syncState(_Cursor.restoring(s._cells), g);

/// The field list, walked in one direction or the other. Order is the whole
/// contract; anything added has to be added in one place, which is the point.
void _syncState(_Cursor c, Game g) {
  g.now = c.io(g.now);
  g.clock.value = g.now;
  c.sig(g.eudaimonia);
  c.sig(g.phase);
  c.sig(g.isNight);
  c.sig(g.announcement);

  // Trains before players: a player halfway onto a train is halfway along a
  // wire that only exists while that train is docked, so the gangway has to be
  // back before anyone can be put on it.
  for (final t in g.trains) {
    t.pos = c.io(t.pos);
    t.departedAt = c.io(t.departedAt);
    t._fromPos = c.io(t._fromPos);
    t._toPos = c.io(t._toPos);
    t._toStation = c.io(t._toStation);
    c.sig(t.arrivesAt);
    c.sig(t.departsAt);
    final docked = c.io(t.dockedAt.peek());
    if (!c.writing) {
      // the gangway is rebuilt rather than assigned — it's an object that
      // exists or doesn't, and the level's edge list has to agree
      if (!docked.isSameAs(t.dockedAt.peek()) || docked == null) {
        t.detachDock(g);
        if (docked != null) t.attachDock(g, docked);
      }
      t.dockedAt.value = docked;
    }
  }

  for (final p in g.players) {
    c.sig(p.inventory);
    c.sig(p.incapacitatedUntil);
    c.sig(p.flash.startedAt);
    c.sig(p.at);
    p.traversalTarget = c.io(p.traversalTarget);
    p.departedAt = c.io(p.departedAt);
    p.arrivesAt = c.io(p.arrivesAt);
    // the wire itself isn't kept: a dock edge is a different object after the
    // trains above have been rebuilt, so which one they're on is worked out
    // again from the two ends
    final from = c.io(
      p.traversing?.other(p.traversalTarget ?? p.traversing!.a),
    );
    if (!c.writing) {
      final target = p.traversalTarget;
      p.traversing = (from == null || target == null)
          ? null
          : from.edges.firstWhereOrNull((e) => e.other(from).isSameAs(target));
      // a wire that isn't there any more can't be walked; put them at the end
      // they were making for, which is what loading a save does too
      if (p.traversing == null && target != null) {
        p.traversalTarget = null;
        p.at.value = target;
      }
    }
    // How far through their list they've got, and not the list itself. What a
    // player has decided to do is the input to the simulation rather than one
    // of its results — moving the clock changes how much of it has happened,
    // never what it says. See [PlayerScript].
    p.script.done = c.io(p.script.done);
  }

  // who is standing where, rebuilt from the players rather than carried, so
  // the two can't disagree. Only written when it's actually changed: these
  // lists are what the node widgets watch.
  if (!c.writing) {
    for (final n in g.nodes) {
      final here = [
        for (final p in g.players)
          if (p.at.peek().isSameAs(n)) p,
      ];
      final was = n.playersPresent.peek();
      if (here.length != was.length ||
          !here.every((p) => was.any((q) => p.isSameAs(q)))) {
        n.playersPresent.value = here;
      }
    }
  }

  for (final n in g.nodes) {
    for (final f in n.facilities) {
      switch (f) {
        case Tree t:
          c.sig(t.pickedAt);
        case Trader t:
          c.sig(t.workEndsAt);
          c.sig(t.cooldownEndsAt);
          c.sig(t.pendingOutput);
          t._worker = c.io(t._worker);
        case Storage s: // an Outbox is one of these too
          c.sig(s.contents);
        case JumpStation j:
          c.sig(j.cooldownEndsAt);
        case Blight b:
          c.sig(b.satiated);
          c.sig(b.flash.startedAt);
        case Mugger m:
          c.sig(m.flash.startedAt);
        default:
          break; // stations, inboxes and landing pads hold nothing that moves
      }
    }
  }
}

// ────────────────────────────── saving & loading ──────────────────────────────

/// A level goes to disk in full rather than as the seed it grew from. A seed
/// only names a level for as long as the generator is left alone, and the
/// generator is the part of the game most under construction — a saved game
/// that dissolves the next time a probability is tuned isn't saved at all. So
/// what's written out is the world itself: the graph, the facilities strewn
/// over it, the item catalogue with the icons it composed, and where everyone
/// is standing and what they're carrying.
///
/// The [Parameters] ride along with it, all but
/// [Parameters.traderGeneratorsPerTier], which is closures. Those are only
/// consulted while a level is being generated and never afterwards, so a
/// loaded level is handed the current defaults for them and is none the wiser.
///
/// The [TypeHelp]s here are the parser combinators the rest of the app
/// persists through (mobj.dart), so a level goes into the same key-value store
/// as everything else — see [saveLevel]. The general ones (enums, colours,
/// offsets, pairs) carry no game knowledge and could move to type_help.dart if
/// anything else wants them.
///
/// One thing deliberately isn't in the format: nothing carries an object
/// identity of its own. Items are named by where they sit in the catalogue and
/// nodes by where they sit in the level's node list, which is why loading goes
/// in passes — every node exists before anything is allowed to point at one.

Map<String, dynamic> _jsonMap(Object? json, String what) {
  if (json is Map<String, dynamic>) return json;
  throw ArgumentError('Cannot convert $json to $what');
}

List<dynamic> _jsonList(Object? json, String what) {
  if (json is List) return json;
  throw ArgumentError('Cannot convert $json to $what');
}

/// An enum written by name, so that reordering a declaration doesn't silently
/// reinterpret every save that came before it.
class EnumType<T extends Enum>(final String name, final List<T> values)
    extends TypeHelp<T> {
  this : super(['enum', name]);

  @override
  T fromJsonValue(Object? json) {
    final n = StringType().fromJson(json);
    final v = values.firstWhereOrNull((v) => v.name == n);
    if (v == null) throw ArgumentError('$name has no value named $n');
    return v;
  }

  @override
  Object? toJsonValue(T object) => object.name;
}

class ColorType extends TypeHelp<Color> {
  ColorType() : super('color');

  @override
  Color fromJsonValue(Object? json) => Color(IntType().fromJson(json));

  @override
  Object? toJsonValue(Color object) => object.toARGB32();
}

class OffsetType extends TypeHelp<Offset> {
  OffsetType() : super('offset');

  @override
  Offset fromJsonValue(Object? json) {
    final l = _jsonList(json, 'Offset');
    return Offset(DoubleType().fromJson(l[0]), DoubleType().fromJson(l[1]));
  }

  @override
  Object? toJsonValue(Offset object) => [object.dx, object.dy];
}

/// A two-field record. The weighted lists and the (low, high) ranges in
/// [Parameters] are all this shape.
class PairType<A, B>(final TypeHelp<A> first, final TypeHelp<B> second)
    extends TypeHelp<(A, B)> {
  this : super(['pair', first.typeDescription, second.typeDescription]);

  @override
  (A, B) fromJsonValue(Object? json) {
    final l = _jsonList(json, 'pair');
    return (first.fromJson(l[0]), second.fromJson(l[1]));
  }

  @override
  Object? toJsonValue((A, B) object) => [
    first.toJson(object.$1),
    second.toJson(object.$2),
  ];
}

/// the `List<(double, T)>` shape every "how often does this come up" parameter
/// is written in
ListType<(double, T)> weightsType<T>(TypeHelp<T> of) =>
    ListType(PairType(DoubleType(), of));

final _facilityKindType = EnumType('FacilityKind', FacilityKind.values);
final _activePhaseType = EnumType('ActivePhase', ActivePhase.values);
final _muggerKindType = EnumType('MuggerKind', MuggerKind.values);
final _trainScheduleKindType = EnumType(
  'TrainScheduleKind',
  TrainScheduleKind.values,
);
final _stationControlType = EnumType('StationControl', StationControl.values);
final _nodeToneType = EnumType('NodeTone', NodeTone.values);
final _basicShapeType = EnumType('BasicShape', BasicShape.values);

// ── items & icons ──

class IconPlacementType extends TypeHelp<IconPlacement> {
  IconPlacementType() : super('iconPlacement');

  @override
  IconPlacement fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'IconPlacement');
    return IconPlacement(
      CoordType().fromJson(j['pos']),
      CoordType().fromJson(j['footprint']),
      BoolType().fromJson(j['tilted']),
      ItemIconType().fromJson(j['icon']),
    );
  }

  @override
  Object? toJsonValue(IconPlacement object) => {
    'pos': CoordType().toJson(object.pos),
    'footprint': CoordType().toJson(object.footprint),
    'tilted': object.tilted,
    'icon': ItemIconType().toJson(object.icon),
  };
}

class ItemIconType extends TypeHelp<ItemIcon> {
  ItemIconType() : super('itemIcon');

  @override
  ItemIcon fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'ItemIcon');
    final kind = StringType().fromJson(j['kind']);
    switch (kind) {
      case 'basic':
        return BasicIcon(
          _basicShapeType.fromJson(j['shape']),
          ColorType().fromJson(j['color']),
        );
      case 'heart':
        return const HeartIcon();
      case 'nesting':
        return NestingIcon(
          fromJson(j['container']) as BasicIcon,
          CoordType().fromJson(j['dims']),
          ListType(IconPlacementType()).fromJson(j['children']),
          mayEmbedLarge: BoolType().fromJson(j['mayEmbedLarge']),
        );
      case 'grid':
        return RootGridIcon(
          CoordType().fromJson(j['dims']),
          ListType(IconPlacementType()).fromJson(j['children']),
        );
    }
    throw ArgumentError('unknown icon kind $kind');
  }

  @override
  Object? toJsonValue(ItemIcon object) => switch (object) {
    BasicIcon b => {
      'kind': 'basic',
      'shape': _basicShapeType.toJson(b.shape),
      'color': ColorType().toJson(b.color),
    },
    HeartIcon _ => {'kind': 'heart'},
    NestingIcon n => {
      'kind': 'nesting',
      'container': toJson(n.container),
      'dims': CoordType().toJson(n.dims),
      'mayEmbedLarge': n.mayEmbedLarge,
      'children': ListType(IconPlacementType()).toJson(n.children),
    },
    RootGridIcon r => {
      'kind': 'grid',
      'dims': CoordType().toJson(r.dims),
      'children': ListType(IconPlacementType()).toJson(r.children),
    },
  };
}

/// The catalogue is written as its icons: an item is nothing but its slot and
/// the mark that stands for it, and the slot is where it sits in here.
class ItemCatalogType extends TypeHelp<ItemCatalog> {
  ItemCatalogType() : super('itemCatalog');

  @override
  ItemCatalog fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'ItemCatalog');
    final tiersJson = _jsonList(j['tiers'], 'tiers');
    final tiers = <List<Item>>[];
    for (var t = 0; t < tiersJson.length; t++) {
      final icons = ListType(ItemIconType()).fromJson(tiersJson[t]);
      tiers.add([
        for (var i = 0; i < icons.length; i++) Item(t, i)..icon = icons[i],
      ]);
    }
    return ItemCatalog(
      tiers,
      Item(tiers.length, 0, isEudaimonia: true)
        ..icon = ItemIconType().fromJson(j['eudaimonia']),
    );
  }

  @override
  Object? toJsonValue(ItemCatalog object) => {
    'tiers': [
      for (final tier in object.tiers)
        ListType(ItemIconType()).toJson([for (final it in tier) it.icon]),
    ],
    'eudaimonia': ItemIconType().toJson(object.eudaimonia.icon),
  };
}

/// Items are interned per level, so everything holding one writes down which
/// slot it is — (tier, index) — rather than a copy of it. Eudaimonia sits one
/// tier above the last, which is exactly what its own [Item.tier] says.
class ItemRefType(final ItemCatalog catalog) extends TypeHelp<Item> {
  this : super('itemRef');

  @override
  Item fromJsonValue(Object? json) {
    final l = _jsonList(json, 'Item');
    final tier = IntType().fromJson(l[0]);
    if (tier >= catalog.tiers.length) return catalog.eudaimonia;
    return catalog.tiers[tier][IntType().fromJson(l[1])];
  }

  @override
  Object? toJsonValue(Item object) => [object.tier, object.iInTier];
}

class QuantityType(ItemCatalog catalog) extends TypeHelp<Quantity> {
  final ItemRefType item;
  this : item = ItemRefType(catalog), super('quantity');

  @override
  Quantity fromJsonValue(Object? json) {
    final l = _jsonList(json, 'Quantity');
    return Quantity(item.fromJson(l[0]), IntType().fromJson(l[1]));
  }

  @override
  Object? toJsonValue(Quantity object) => [item.toJson(object.item), object.n];
}

class IntervalType extends TypeHelp<Interval> {
  IntervalType() : super('interval');

  @override
  Interval fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'Interval');
    if (StringType().fromJson(j['kind']) == 'clock') {
      return ClockInterval(
        multiple: IntType().fromJson(j['multiple']),
        division: IntType().fromJson(j['division']),
        offset: IntType().fromJson(j['offset']),
      );
    }
    return ArbitraryInterval(IntType().fromJson(j['period']));
  }

  @override
  Object? toJsonValue(Interval object) => switch (object) {
    ClockInterval c => {
      'kind': 'clock',
      'multiple': c.multiple,
      'division': c.division,
      'offset': c.offset,
    },
    ArbitraryInterval a => {'kind': 'arbitrary', 'period': a.period},
  };
}

// ── parameters ──

class ParametersType extends TypeHelp<Parameters> {
  ParametersType() : super('trainscapeParameters');

  @override
  Parameters fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'Parameters');
    final tierCount = ListType(IntType()).fromJson(j['tierCount']);
    return Parameters(
      // the generators aren't in the format (they're closures), and a level
      // that's already been generated never consults them again, so a loaded
      // level is handed the live table whatever it grew from
      traderGeneratorsPerTier: levelOneTraders(tierCount.length),
      tierCount: tierCount,
      seed: IntType().fromJson(j['seed']),
      globalTime: IntType().fromJson(j['globalTime']),
      eudaimoniaGoal: IntType().fromJson(j['eudaimoniaGoal']),
      dayRealSeconds: DoubleType().fromJson(j['dayRealSeconds']),
      nPlayers: IntType().fromJson(j['nPlayers']),
      inventoryCap: IntType().fromJson(j['inventoryCap']),
      playerSpeed: DoubleType().fromJson(j['playerSpeed']),
      playersHaveMoveAction: BoolType().fromJson(j['playersHaveMoveAction']),
      gridSizeN: IntType().fromJson(j['gridSizeN']),
      gridSpacing: DoubleType().fromJson(j['gridSpacing']),
      gridSizeDistortionCountStartp: DoubleType().fromJson(
        j['gridSizeDistortionCountStartp'],
      ),
      gridSizeDistortionCountVariancep: DoubleType().fromJson(
        j['gridSizeDistortionCountVariancep'],
      ),
      gridSizeDistortionp: DoubleType().fromJson(j['gridSizeDistortionp']),
      lineRemovalProb: DoubleType().fromJson(j['lineRemovalProb']),
      pointRemovalProb: DoubleType().fromJson(j['pointRemovalProb']),
      middleNodeProb: DoubleType().fromJson(j['middleNodeProb']),
      splitNodeMinDistance: DoubleType().fromJson(j['splitNodeMinDistance']),
      itemColors: ListType(ColorType()).fromJson(j['itemColors']),
      iconNestingp: DoubleType().fromJson(j['iconNestingp']),
      squircleTryEmbeddingLargep: DoubleType().fromJson(
        j['squircleTryEmbeddingLargep'],
      ),
      iconGridPlacementBigp: DoubleType().fromJson(j['iconGridPlacementBigp']),
      farZoomThreshold: DoubleType().fromJson(j['farZoomThreshold']),
      bucketSizeWeights: ListType(DoubleType())
          .fromJson(j['bucketSizeWeights']),
      nonTraderWeights: MapType(
        _facilityKindType,
        DoubleType(),
      ).fromJson(j['nonTraderWeights']),
      nodeToneWeights: weightsType(_nodeToneType)
          .fromJson(j['nodeToneWeights']),
      treeRegenTime: IntType().fromJson(j['treeRegenTime']),
      treeClockIntervalp: DoubleType().fromJson(j['treeClockIntervalp']),
      treeSecondItemProb: DoubleType().fromJson(j['treeSecondItemProb']),
      treeTier1Prob: DoubleType().fromJson(j['treeTier1Prob']),
      traderInstantProb: DoubleType().fromJson(j['traderInstantProb']),
      tradeDurationRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['tradeDurationRange']),
      traderCooldownProb: DoubleType().fromJson(j['traderCooldownProb']),
      traderCooldownRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['traderCooldownRange']),
      muggerIncapTime: IntType().fromJson(j['muggerIncapTime']),
      muggerKindWeights: weightsType(_muggerKindType)
          .fromJson(j['muggerKindWeights']),
      storageCapacityRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['storageCapacityRange']),
      storageSecurep: DoubleType().fromJson(j['storageSecurep']),
      outboxCapacityRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['outboxCapacityRange']),
      inboxActivationProb: DoubleType().fromJson(j['inboxActivationProb']),
      inboxActivationConsumedProb: DoubleType().fromJson(
        j['inboxActivationConsumedProb'],
      ),
      jumpFreeAimp: DoubleType().fromJson(j['jumpFreeAimp']),
      jumpCostItemp: DoubleType().fromJson(j['jumpCostItemp']),
      jumpCooldownp: DoubleType().fromJson(j['jumpCooldownp']),
      jumpCooldownRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['jumpCooldownRange']),
      blightRadii: ListType(DoubleType()).fromJson(j['blightRadii']),
      blightMitigablep: DoubleType().fromJson(j['blightMitigablep']),
      blightHungryp: DoubleType().fromJson(j['blightHungryp']),
      blightDaysRange: PairType(
        IntType(),
        IntType(),
      ).fromJson(j['blightDaysRange']),
      nTrains: IntType().fromJson(j['nTrains']),
      stationsPerTrain: IntType().fromJson(j['stationsPerTrain']),
      trainSpeed: DoubleType().fromJson(j['trainSpeed']),
      trainActivationProb: DoubleType().fromJson(j['trainActivationProb']),
      trainActivationConsumedProb: DoubleType().fromJson(
        j['trainActivationConsumedProb'],
      ),
      trainActivationTwoProb: DoubleType().fromJson(
        j['trainActivationTwoProb'],
      ),
      scheduleDistribution: weightsType(_trainScheduleKindType)
          .fromJson(j['scheduleDistribution']),
      trainCycleDivisions: ListType(IntType())
          .fromJson(j['trainCycleDivisions']),
      movableFromInsideProb: DoubleType().fromJson(j['movableFromInsideProb']),
      stationControlWeights: weightsType(_stationControlType)
          .fromJson(j['stationControlWeights']),
      trainTerminusDistance: DoubleType().fromJson(j['trainTerminusDistance']),
      oneWayReturnDelay: IntType().fromJson(j['oneWayReturnDelay']),
    );
  }

  @override
  Object? toJsonValue(Parameters p) => {
    'seed': p.seed,
    'globalTime': p.globalTime,
    'eudaimoniaGoal': p.eudaimoniaGoal,
    'dayRealSeconds': p.dayRealSeconds,
    'nPlayers': p.nPlayers,
    'inventoryCap': p.inventoryCap,
    'playerSpeed': p.playerSpeed,
    'playersHaveMoveAction': p.playersHaveMoveAction,
    'gridSizeN': p.gridSizeN,
    'gridSpacing': p.gridSpacing,
    'gridSizeDistortionCountStartp': p.gridSizeDistortionCountStartp,
    'gridSizeDistortionCountVariancep': p.gridSizeDistortionCountVariancep,
    'gridSizeDistortionp': p.gridSizeDistortionp,
    'lineRemovalProb': p.lineRemovalProb,
    'pointRemovalProb': p.pointRemovalProb,
    'middleNodeProb': p.middleNodeProb,
    'splitNodeMinDistance': p.splitNodeMinDistance,
    'itemColors': ListType(ColorType()).toJson(p.itemColors),
    'tierCount': p.tierCount,
    'iconNestingp': p.iconNestingp,
    'squircleTryEmbeddingLargep': p.squircleTryEmbeddingLargep,
    'iconGridPlacementBigp': p.iconGridPlacementBigp,
    'farZoomThreshold': p.farZoomThreshold,
    'bucketSizeWeights': p.bucketSizeWeights,
    'nonTraderWeights': MapType(
      _facilityKindType,
      DoubleType(),
    ).toJson(p.nonTraderWeights),
    'nodeToneWeights': weightsType(_nodeToneType).toJson(p.nodeToneWeights),
    'treeRegenTime': p.treeRegenTime,
    'treeClockIntervalp': p.treeClockIntervalp,
    'treeSecondItemProb': p.treeSecondItemProb,
    'treeTier1Prob': p.treeTier1Prob,
    'traderInstantProb': p.traderInstantProb,
    'tradeDurationRange': PairType(
      IntType(),
      IntType(),
    ).toJson(p.tradeDurationRange),
    'traderCooldownProb': p.traderCooldownProb,
    'traderCooldownRange': PairType(
      IntType(),
      IntType(),
    ).toJson(p.traderCooldownRange),
    'muggerIncapTime': p.muggerIncapTime,
    'muggerKindWeights': weightsType(_muggerKindType)
        .toJson(p.muggerKindWeights),
    'storageCapacityRange': PairType(
      IntType(),
      IntType(),
    ).toJson(p.storageCapacityRange),
    'storageSecurep': p.storageSecurep,
    'outboxCapacityRange': PairType(
      IntType(),
      IntType(),
    ).toJson(p.outboxCapacityRange),
    'inboxActivationProb': p.inboxActivationProb,
    'inboxActivationConsumedProb': p.inboxActivationConsumedProb,
    'jumpFreeAimp': p.jumpFreeAimp,
    'jumpCostItemp': p.jumpCostItemp,
    'jumpCooldownp': p.jumpCooldownp,
    'jumpCooldownRange': PairType(
      IntType(),
      IntType(),
    ).toJson(p.jumpCooldownRange),
    'blightRadii': p.blightRadii,
    'blightMitigablep': p.blightMitigablep,
    'blightHungryp': p.blightHungryp,
    'blightDaysRange': PairType(IntType(), IntType()).toJson(p.blightDaysRange),
    'nTrains': p.nTrains,
    'stationsPerTrain': p.stationsPerTrain,
    'trainSpeed': p.trainSpeed,
    'trainActivationProb': p.trainActivationProb,
    'trainActivationConsumedProb': p.trainActivationConsumedProb,
    'trainActivationTwoProb': p.trainActivationTwoProb,
    'scheduleDistribution': weightsType(_trainScheduleKindType)
        .toJson(p.scheduleDistribution),
    'trainCycleDivisions': p.trainCycleDivisions,
    'movableFromInsideProb': p.movableFromInsideProb,
    'stationControlWeights': weightsType(_stationControlType)
        .toJson(p.stationControlWeights),
    'trainTerminusDistance': p.trainTerminusDistance,
    'oneWayReturnDelay': p.oneWayReturnDelay,
  };
}

// ── the level ──

/// What the parts of a level call each other by. Items are named by their
/// catalogue slot and nodes by their index in the level's node list; this
/// holds both directions, since saving needs object → index and loading needs
/// index → object.
class LevelRefs(
  final ItemCatalog catalog,

  /// grows as a level is read; complete before anything is asked to resolve a
  /// node reference
  final List<Node> nodes,
) {
  late final ItemRefType item = ItemRefType(catalog);
  late final QuantityType quantity = QuantityType(catalog);
  final Map<Node, int> _index = {};

  this {
    reindex();
  }

  void reindex() {
    _index.clear();
    for (var i = 0; i < nodes.length; i++) {
      _index[nodes[i]] = i;
    }
  }

  int indexOf(Node n) => _index[n]!;
  Node node(Object? json) => nodes[IntType().fromJson(json)];

  /// A facility named the way everything else here is named: by where it sits.
  /// Its node, then its place among that node's own. [Facility.id] would be
  /// shorter, but a level is read back in passes and the ids aren't handed out
  /// until the [Game] is standing, which is after the facilities need to be
  /// findable.
  List<int> facilityRef(Facility f) => [
    indexOf(f.node),
    f.node.facilities.indexOf(f),
  ];

  Facility facility(Object? json) {
    final r = _jsonList(json, 'facility');
    return nodes[IntType().fromJson(r[0])].facilities[IntType().fromJson(r[1])];
  }
}

class FacilityType(final LevelRefs refs) extends TypeHelp<Facility> {
  this : super('trainscapeFacility');

  @override
  Facility fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'Facility');
    final f = switch (_facilityKindType.fromJson(j['kind'])) {
      FacilityKind.station => Station(
        refs.node(j['train']) as TrainNode,
        _stationControlType.fromJson(j['control']),
      ),
      FacilityKind.tree => _tree(j),
      FacilityKind.trader => _trader(j),
      FacilityKind.mugger => Mugger(
        refs.item.fromJson(j['item']),
        _muggerKindType.fromJson(j['muggerKind']),
      ),
      FacilityKind.storage => _storage(j),
      FacilityKind.blight => _blight(j),
      FacilityKind.outbox => _outbox(j),
      FacilityKind.inbox => Inbox(
        activation: Nullable(refs.quantity).fromJson(j['activation']),
        activationConsumed: BoolType().fromJson(j['activationConsumed']),
      ),
      FacilityKind.jumpStation => _jumpStation(j),
      FacilityKind.landingStation => LandingStation(),
    };
    f.activePhase = _activePhaseType.fromJson(j['activePhase']);
    return f;
  }

  Tree _tree(Map<String, dynamic> j) => Tree(
    ListType(refs.quantity).fromJson(j['produces']),
    IntervalType().fromJson(j['regen']),
  )..pickedAt.value = Nullable(IntType()).fromJson(j['pickedAt']);

  /// Who a trade in progress belongs to isn't written down. [Trader._worker]
  /// only exists so the goods can be put straight into the hands of whoever
  /// started the trade, and a trade that finishes with nobody assigned leaves
  /// its output in [Trader.pendingOutput] to be collected — one tap, in
  /// exchange for a facility never having to name a player.
  Trader _trader(Map<String, dynamic> j) =>
      Trader(
          ListType(refs.quantity).fromJson(j['takes']),
          ListType(refs.quantity).fromJson(j['gives']),
        )
        ..duration = IntType().fromJson(j['duration'])
        ..cooldown = IntType().fromJson(j['cooldown'])
        ..workEndsAt.value = Nullable(IntType()).fromJson(j['workEndsAt'])
        ..cooldownEndsAt.value = Nullable(IntType())
            .fromJson(j['cooldownEndsAt'])
        ..pendingOutput.value = ListType(refs.quantity)
            .fromJson(j['pendingOutput']);

  Storage _storage(Map<String, dynamic> j) => Storage(
    IntType().fromJson(j['capacity']),
    secured: BoolType().fromJson(j['secured']),
  )..contents.value = ListType(refs.item).fromJson(j['contents']);

  Outbox _outbox(Map<String, dynamic> j) => Outbox(
    IntType().fromJson(j['capacity']),
    secured: BoolType().fromJson(j['secured']),
  )..contents.value = ListType(refs.item).fromJson(j['contents']);

  JumpStation _jumpStation(Map<String, dynamic> j) => JumpStation(
    freeAim: BoolType().fromJson(j['freeAim']),
    cost: Nullable(refs.quantity).fromJson(j['cost']),
    cooldown: IntType().fromJson(j['cooldown']),
  )..cooldownEndsAt.value = Nullable(IntType()).fromJson(j['cooldownEndsAt']);

  Blight _blight(Map<String, dynamic> j) => Blight(
    radius: DoubleType().fromJson(j['radius']),
    interval: IntervalType().fromJson(j['interval']) as ClockInterval,
    mitigator: Nullable(refs.item).fromJson(j['mitigator']),
    hungry: BoolType().fromJson(j['hungry']),
  )..satiated.value = BoolType().fromJson(j['satiated']);

  Map<String, Object?> _head(Facility f, FacilityKind kind) => {
    'kind': _facilityKindType.toJson(kind),
    'activePhase': _activePhaseType.toJson(f.activePhase),
  };

  @override
  Object? toJsonValue(Facility f) => switch (f) {
    Station s => {
      ..._head(f, FacilityKind.station),
      'train': refs.indexOf(s.train),
      'control': _stationControlType.toJson(s.control),
    },
    Tree t => {
      ..._head(f, FacilityKind.tree),
      'produces': ListType(refs.quantity).toJson(t.produces),
      'regen': IntervalType().toJson(t.regen),
      'pickedAt': Nullable(IntType()).toJson(t.pickedAt.peek()),
    },
    Trader t => {
      ..._head(f, FacilityKind.trader),
      'takes': ListType(refs.quantity).toJson(t.takes),
      'gives': ListType(refs.quantity).toJson(t.gives),
      'duration': t.duration,
      'cooldown': t.cooldown,
      'workEndsAt': Nullable(IntType()).toJson(t.workEndsAt.peek()),
      'cooldownEndsAt': Nullable(IntType()).toJson(t.cooldownEndsAt.peek()),
      'pendingOutput': ListType(refs.quantity).toJson(t.pendingOutput.peek()),
    },
    Mugger m => {
      ..._head(f, FacilityKind.mugger),
      'item': refs.item.toJson(m.item),
      'muggerKind': _muggerKindType.toJson(m.kind),
    },
    // before Storage: an outbox is one, as far as the type system and every
    // storage flow in the game are concerned, and the first matching pattern
    // is the one that writes it down
    Outbox o => {
      ..._head(f, FacilityKind.outbox),
      'capacity': o.capacity,
      'secured': o.secured,
      'contents': ListType(refs.item).toJson(o.contents.peek()),
    },
    Storage s => {
      ..._head(f, FacilityKind.storage),
      'capacity': s.capacity,
      'secured': s.secured,
      'contents': ListType(refs.item).toJson(s.contents.peek()),
    },
    Inbox i => {
      ..._head(f, FacilityKind.inbox),
      'activation': Nullable(refs.quantity).toJson(i.activation),
      'activationConsumed': i.activationConsumed,
    },
    JumpStation js => {
      ..._head(f, FacilityKind.jumpStation),
      'freeAim': js.freeAim,
      'cost': Nullable(refs.quantity).toJson(js.cost),
      'cooldown': js.cooldown,
      'cooldownEndsAt': Nullable(IntType()).toJson(js.cooldownEndsAt.peek()),
    },
    LandingStation _ => _head(f, FacilityKind.landingStation),
    Blight b => {
      ..._head(f, FacilityKind.blight),
      'radius': b.radius,
      'interval': IntervalType().toJson(b.interval),
      'mitigator': Nullable(refs.item).toJson(b.mitigator),
      'hungry': b.hungry,
      'satiated': b.satiated.peek(),
    },
    _ => throw ArgumentError('no way to write down a ${f.runtimeType}'),
  };
}

TrainSchedule _scheduleFromJson(Object? json) {
  final j = _jsonMap(json, 'TrainSchedule');
  return switch (_trainScheduleKindType.fromJson(j['kind'])) {
    TrainScheduleKind.never => const NeverSchedule(),
    TrainScheduleKind.oneWay => const OneWaySchedule(),
    TrainScheduleKind.cycle => CycleSchedule(
      IntervalType().fromJson(j['interval']) as ClockInterval,
    ),
  };
}

Object? _scheduleToJson(TrainSchedule s) => switch (s) {
  NeverSchedule _ => {
    'kind': _trainScheduleKindType.toJson(TrainScheduleKind.never),
  },
  OneWaySchedule _ => {
    'kind': _trainScheduleKindType.toJson(TrainScheduleKind.oneWay),
  },
  CycleSchedule c => {
    'kind': _trainScheduleKindType.toJson(TrainScheduleKind.cycle),
    'interval': IntervalType().toJson(c.interval),
  },
};

class NodeType(final LevelRefs refs) extends TypeHelp<Node> {
  this : super('trainscapeNode');

  /// Reads the node itself and nothing that points elsewhere: its facilities,
  /// and the stations a train serves, are references to other nodes, so they
  /// go on in [link] once every node in the level exists.
  @override
  Node fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'Node');
    final pos = OffsetType().fromJson(j['pos']);
    final train = j['train'];
    final n = train == null
        ? Node(pos)
        : _trainShell(pos, _jsonMap(train, 'train'));
    n.tone = _nodeToneType.fromJson(j['tone']);
    n.tint = ColorType().fromJson(j['tint']);
    n.stackRank = IntType().fromJson(j['stackRank']);
    return n;
  }

  TrainNode _trainShell(Offset pos, Map<String, dynamic> j) => TrainNode(
    pos: pos,
    activation: Nullable(refs.quantity).fromJson(j['activation']),
    activationConsumed: BoolType().fromJson(j['activationConsumed']),
    movableFromInside: BoolType().fromJson(j['movableFromInside']),
    schedule: _scheduleFromJson(j['schedule']),
    stationNodes: [],
    terminusFor: {},
  );

  /// second pass: everything that names another node
  void link(Node n, Object? json) {
    final j = _jsonMap(json, 'Node');
    for (final fj in _jsonList(j['facilities'], 'facilities')) {
      final f = FacilityType(refs).fromJson(fj);
      f.node = n;
      n.facilities.add(f);
    }
    if (n is TrainNode) {
      final tj = _jsonMap(j['train'], 'train');
      final termini = ListType(OffsetType()).fromJson(tj['termini']);
      final stations = [
        for (final s in _jsonList(tj['stations'], 'stations')) refs.node(s),
      ];
      n.stationNodes.addAll(stations);
      for (var i = 0; i < stations.length; i++) {
        n.terminusFor[stations[i]] = termini[i];
      }
    }
  }

  /// third pass: where the train actually is. Docking hangs a boarding wire
  /// off the station, and that's an edge in the game's own list, so this waits
  /// until the [Game] is standing.
  void restoreMotion(TrainNode t, Object? json, Game g) {
    final j = _jsonMap(_jsonMap(json, 'Node')['train'], 'train');
    // the last leg it ran is still lying around in these while it's docked;
    // they're carried across so that a level and the level read back out of it
    // are the same level down to the dead state
    t._fromPos = OffsetType().fromJson(j['fromPos']);
    t._toPos = OffsetType().fromJson(j['toPos']);
    t._toStation = j['toStation'] == null ? null : refs.node(j['toStation']);
    t.departedAt = IntType().fromJson(j['departedAt']);
    t.arrivesAt.value = Nullable(IntType()).fromJson(j['arrivesAt']);
    final docked = j['dockedAt'];
    if (docked != null) t.dock(g, refs.node(docked));
    // dock() works out a fresh departure off the schedule, and clears the
    // transit bracket; both of the saved ones are what was really running
    t.departsAt.value = Nullable(IntType()).fromJson(j['departsAt']);
    if (docked == null) {
      t._toStation = j['toStation'] == null ? null : refs.node(j['toStation']);
      t.arrivesAt.value = Nullable(IntType()).fromJson(j['arrivesAt']);
    }
  }

  @override
  Object? toJsonValue(Node n) => {
    'pos': OffsetType().toJson(n.pos),
    'tone': _nodeToneType.toJson(n.tone),
    'tint': ColorType().toJson(n.tint),
    'stackRank': n.stackRank,
    'facilities': [for (final f in n.facilities) FacilityType(refs).toJson(f)],
    if (n is TrainNode) 'train': _trainToJson(n),
  };

  Object? _trainToJson(TrainNode t) {
    final docked = t.dockedAt.peek();
    return {
      'activation': Nullable(refs.quantity).toJson(t.activation),
      'activationConsumed': t.activationConsumed,
      'movableFromInside': t.movableFromInside,
      'schedule': _scheduleToJson(t.schedule),
      'stations': [for (final s in t.stationNodes) refs.indexOf(s)],
      'termini': [
        for (final s in t.stationNodes) OffsetType().toJson(t.terminusFor[s]!),
      ],
      'dockedAt': docked == null ? null : refs.indexOf(docked),
      'toStation': t._toStation == null ? null : refs.indexOf(t._toStation!),
      'fromPos': OffsetType().toJson(t._fromPos),
      'toPos': OffsetType().toJson(t._toPos),
      'departedAt': t.departedAt,
      'arrivesAt': Nullable(IntType()).toJson(t.arrivesAt.peek()),
      'departsAt': Nullable(IntType()).toJson(t.departsAt.peek()),
    };
  }
}

/// A player's history, which goes to disk along with everything else: the
/// clock can be wound back into a session played yesterday, and it can only do
/// that if what everyone decided to do is still written down.
///
/// [PlayerAction.recorded] rides along too. Without it a reloaded level would
/// treat every replayed action as though it were happening for the first time,
/// quietly re-recording whatever came out instead of noticing it had come out
/// differently — the divergence alert would work until you quit the app and
/// then never again.
class ActionType(final LevelRefs refs) extends TypeHelp<PlayerAction> {
  this : super('trainscapeAction');

  ActionResult? _result(Object? json) {
    if (json == null) return null;
    final j = _jsonMap(json, 'result');
    final at = j['at'];
    return ActionResult(
      ListType(refs.item).fromJson(j['holding']),
      at == null ? null : refs.node(at),
    );
  }

  Object? _resultJson(ActionResult? r) => r == null
      ? null
      : {
          'holding': ListType(refs.item).toJson(r.holding),
          'at': r.at == null ? null : refs.indexOf(r.at!),
        };

  @override
  PlayerAction fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'PlayerAction');
    final at = IntType().fromJson(j['notBefore']);
    final a = switch (StringType().fromJson(j['kind'])) {
      'move' => MoveAction(refs.node(j['to']), notBefore: at),
      'harvest' => HarvestAction(refs.facility(j['at']) as Tree, notBefore: at),
      'trade' => TradeAction(refs.facility(j['at']) as Trader, notBefore: at),
      'collect' => CollectAction(
        refs.facility(j['at']) as Trader,
        notBefore: at,
      ),
      'feed' => FeedAction(refs.facility(j['at']) as Blight, notBefore: at),
      'pull' => PullAction(
        refs.facility(j['at']) as Inbox,
        refs.item.fromJson(j['item']),
        notBefore: at,
      ),
      'jump' => JumpAction(
        refs.facility(j['at']) as JumpStation,
        refs.node(j['to']),
        notBefore: at,
      ),
      'store' => StoreAction(refs.item.fromJson(j['item']), notBefore: at),
      'rotate' => RotateAction(
        refs.facility(j['at']) as Storage,
        refs.item.fromJson(j['item']),
        notBefore: at,
      ),
      'train' => TrainMoveAction(
        refs.node(j['train']) as TrainNode,
        refs.node(j['to']),
        notBefore: at,
      ),
      final k => throw ArgumentError('no action called $k'),
    };
    a.recorded = _result(j['recorded']);
    return a;
  }

  @override
  Object? toJsonValue(PlayerAction a) => {
    'notBefore': a.notBefore,
    'recorded': _resultJson(a.recorded),
    ...switch (a) {
      MoveAction m => {'kind': 'move', 'to': refs.indexOf(m.to)},
      HarvestAction h => {'kind': 'harvest', 'at': refs.facilityRef(h.tree)},
      TradeAction t => {'kind': 'trade', 'at': refs.facilityRef(t.trader)},
      CollectAction t => {'kind': 'collect', 'at': refs.facilityRef(t.trader)},
      FeedAction f => {'kind': 'feed', 'at': refs.facilityRef(f.blight)},
      PullAction p => {
        'kind': 'pull',
        'at': refs.facilityRef(p.inbox),
        'item': refs.item.toJson(p.item),
      },
      JumpAction j => {
        'kind': 'jump',
        'at': refs.facilityRef(j.station),
        'to': refs.indexOf(j.to),
      },
      StoreAction s => {'kind': 'store', 'item': refs.item.toJson(s.item)},
      RotateAction r => {
        'kind': 'rotate',
        'at': refs.facilityRef(r.from),
        'item': refs.item.toJson(r.item),
      },
      TrainMoveAction t => {
        'kind': 'train',
        'train': refs.indexOf(t.train),
        'to': refs.indexOf(t.to),
      },
    },
  };
}

class PlayerType(final LevelRefs refs) extends TypeHelp<Player> {
  this : super('trainscapePlayer');

  @override
  Player fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'Player');
    final p = Player(
      StringType().fromJson(j['name']),
      ColorType().fromJson(j['color']),
    );
    p.inventory.value = ListType(refs.item).fromJson(j['inventory']);
    p.incapacitatedUntil.value = Nullable(IntType())
        .fromJson(j['incapacitatedUntil']);
    final at = j['at'];
    if (at != null) p.at.value = refs.node(at);
    return p;
  }

  /// The script names facilities, and facilities are hung on their nodes in a
  /// later pass than the one that makes the nodes — so like the wire a walker
  /// is halfway along, it waits until the level is standing.
  void restoreScript(Player p, Object? json) {
    final j = _jsonMap(json, 'Player');
    p.script.actions.addAll(ListType(ActionType(refs)).fromJson(j['script']));
    p.script.done = IntType().fromJson(j['scriptDone']);
  }

  /// The wire a player is halfway along can only be found once the trains have
  /// docked and their boarding edges are back, so [LevelType] calls this after
  /// the game is standing.
  void restoreTraversal(Player p, Object? json) {
    final t = _jsonMap(json, 'Player')['traversing'];
    if (t == null) return;
    final j = _jsonMap(t, 'traversal');
    final from = refs.node(j['from']);
    final to = refs.node(j['to']);
    final edge = from.edges.firstWhereOrNull((e) => e.other(from).isSameAs(to));
    if (edge == null) {
      // the wire is gone — a train they were boarding left without them. Put
      // them down at the end they were walking towards rather than nowhere
      p.at.value = to;
      return;
    }
    p.traversing = edge;
    p.traversalTarget = to;
    p.departedAt = IntType().fromJson(j['departedAt']);
    p.arrivesAt = IntType().fromJson(j['arrivesAt']);
  }

  @override
  Object? toJsonValue(Player p) {
    final traversing = p.traversing;
    final at = p.at.peek();
    return {
      'name': p.name,
      'color': ColorType().toJson(p.color),
      'inventory': ListType(refs.item).toJson(p.inventory.peek()),
      'incapacitatedUntil': Nullable(IntType())
          .toJson(p.incapacitatedUntil.peek()),
      'at': at == null ? null : refs.indexOf(at),
      'script': ListType(ActionType(refs)).toJson(p.script.actions),
      'scriptDone': p.script.done,
      'traversing': traversing == null
          ? null
          : {
              'from': refs.indexOf(traversing.other(p.traversalTarget!)),
              'to': refs.indexOf(p.traversalTarget!),
              'departedAt': p.departedAt,
              'arrivesAt': p.arrivesAt,
            },
    };
  }
}

/// A whole level, and the clock it was left running at. The version in the
/// type description is what stops a save written by an older build from being
/// read as though it were this one — a mismatch simply means no saved level,
/// and a fresh one is generated. Bump it whenever the shape below changes.
class LevelType extends TypeHelp<Game> {
  LevelType() : super('trainscapeLevel/7');

  @override
  Game fromJsonValue(Object? json) {
    final j = _jsonMap(json, 'level');
    final params = ParametersType().fromJson(j['params']);
    final catalog = ItemCatalogType().fromJson(j['catalog']);
    final refs = LevelRefs(catalog, []);
    final nodeType = NodeType(refs);

    // 1 ── the nodes themselves, so that references have something to land on
    final nodesJson = _jsonList(j['nodes'], 'nodes');
    for (final nj in nodesJson) {
      refs.nodes.add(nodeType.fromJson(nj));
    }

    // 2 ── the permanent wires. The temporary station↔train ones aren't
    // written down; they come back with the trains that own them.
    final edges = <Edge>[];
    for (final ej in _jsonList(j['edges'], 'edges')) {
      final pair = _jsonList(ej, 'edge');
      final a = refs.node(pair[0]), b = refs.node(pair[1]);
      final e = Edge(a, b);
      a.edges.add(e);
      b.edges.add(e);
      edges.add(e);
    }

    // 3 ── facilities and train↔station links
    for (var i = 0; i < nodesJson.length; i++) {
      nodeType.link(refs.nodes[i], nodesJson[i]);
    }

    final playerType = PlayerType(refs);
    final playersJson = _jsonList(j['players'], 'players');
    final players = [for (final pj in playersJson) playerType.fromJson(pj)];

    final game = Game(
      params: params,
      catalog: catalog,
      nodes: refs.nodes,
      edges: edges,
      players: players,
      trains: refs.nodes.whereType<TrainNode>().toList(),
    );

    // 4 ── where the trains are, then where the walkers are: a player mid-way
    // onto a train needs that train's boarding wire to exist first
    for (var i = 0; i < nodesJson.length; i++) {
      final n = refs.nodes[i];
      if (n is TrainNode) nodeType.restoreMotion(n, nodesJson[i], game);
    }
    for (var i = 0; i < playersJson.length; i++) {
      playerType.restoreTraversal(players[i], playersJson[i]);
      playerType.restoreScript(players[i], playersJson[i]);
    }
    for (final p in players) {
      final at = p.at.peek();
      if (at != null) {
        at.playersPresent.value = [...at.playersPresent.peek(), p];
      }
    }

    // 5 ── the score and the settings, then the clock
    game.eudaimonia.value = IntType().fromJson(j['eudaimonia']);
    game.paused.value = BoolType().fromJson(j['paused']);
    game.selectedPlayer.value =
        players[IntType().fromJson(j['selectedPlayer'])];
    game._stackTop = IntType().fromJson(j['stackTop']);

    // Everything above is the level as it *began*, so this is the beginning,
    // and it's as far back as winding can go — which is all the way.
    game.now = IntType().fromJson(j['originAt']);
    game.clock.value = game.now;
    game.isNight.value = game.timeOfDay >= gameDay ~/ 2;
    game.markOrigin();

    // and then it's played, which is what puts it back where it was left. The
    // histories are loaded, so this is the same replay the clock does when
    // it's wound forwards, and it lands in the same place for the same reason.
    game.advanceTo(IntType().fromJson(j['now']));
    return game;
  }

  @override
  /// Written from the level's beginning rather than from where it has got to.
  ///
  /// A middle can't be wound back through — that's what a saved game used to
  /// be, and it's why picking one up left the clock nailed to the floor. A
  /// beginning plus everyone's history can be wound back through completely,
  /// because it's the same pair the running game replays from every time the
  /// dial moves. The clock reading is written alongside and played back to on
  /// the way in, so nothing about being reloaded is a special case.
  ///
  /// It's a smaller file, too: one world instead of one world and a ladder of
  /// moments. The price is that a save is now reproduced rather than recorded
  /// — change what the simulation *does* and an old save replays into a
  /// different world — so the version above has to move whenever behaviour
  /// does, not only when this format does.
  @override
  Object? toJsonValue(Game g) {
    // Wound back to the beginning to be written down, and put back
    // afterwards. The histories aren't part of a snapshot, so they're the same
    // either way, and the score is (it's re-earned by the replay on the way
    // in, so what goes to disk is the nothing it started with).
    //
    // This does write to every signal in the level, twice, netting out at no
    // change. It's the one place outside the ticker that does, and it's safe
    // in both places a save happens: leaving the screen unmounts the widgets
    // below before this runs, and backgrounding costs one wasted rebuild of a
    // screen nobody is looking at.
    final here = captureState(g);
    final at = g.now;
    restoreState(g, g._origin);

    final refs = LevelRefs(g.catalog, g.nodes);
    final nodeType = NodeType(refs);
    final playerType = PlayerType(refs);
    final out = {
      'params': ParametersType().toJson(g.params),
      'catalog': ItemCatalogType().toJson(g.catalog),
      'nodes': [for (final n in g.nodes) nodeType.toJson(n)],
      'edges': [
        for (final e in g.edges)
          if (e.dockTrain == null) [refs.indexOf(e.a), refs.indexOf(e.b)],
      ],
      'players': [for (final p in g.players) playerType.toJson(p)],
      'originAt': g.now,
      'now': at,
      'eudaimonia': g.eudaimonia.peek(),
      'paused': g.paused.peek(),
      'selectedPlayer': g.players.indexOf(g.selectedPlayer.peek()),
      'stackTop': g._stackTop,
    };

    restoreState(g, here);
    return out;
  }
}

/// the level as json text, for eyeballing it or keeping one by hand
String levelToJson(Game g) => jsonEncode(LevelType().toJson(g));
Game levelFromJson(String s) => LevelType().fromJson(jsonDecode(s));

/// Puts [game] down as the level the next run picks up: one row of the app's
/// little key-value store, written whole each time, about 100KB for a level of
/// the current size.
///
/// Written through [Mobj.write] rather than held in a Mobj. A Mobj is a signal
/// and a game mutates in place, so there'd be nothing for the signal to notify
/// anyone about — every save would be a forced write through a cache that
/// never told anyone anything.
void saveLevel(Game game) {
  if (!MobjRegistry.isInitialized) return;
  Mobj.write(savedTrainscapeLevelID, game, LevelType());
}

/// The level [saveLevel] last put down, or null if there isn't one, or it was
/// written by a build whose format this one can't read — in which case the
/// caller generates a fresh level and the unreadable save is overwritten the
/// next time the game is left.
Future<Game?> loadSavedLevel() async {
  if (!MobjRegistry.isInitialized) return null;
  try {
    return await Mobj.read(savedTrainscapeLevelID, LevelType());
  } catch (e) {
    debugPrint('trainscape: discarding an unreadable saved level: $e');
    return null;
  }
}
