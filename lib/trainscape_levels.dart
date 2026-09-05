part of 'trainscape.dart';

class TrainscapeLevel {
  const TrainscapeLevel({
    required this.id,
    required this.name,
    required this.build,
  });

  final String id;
  final String name;
  final Game Function() build;
}

class TrainscapeSection {
  const TrainscapeSection({
    required this.name,
    required this.levelsRequiredToWin,
    this.levels = const [],
    this.worlds,
    this.text,
  });

  final String name;
  final int levelsRequiredToWin;
  final List<TrainscapeLevel> levels;
  final TrainscapeWorlds? worlds;
  final String? text;

  List<TrainscapeLevel> availableLevels(Map<String, int> progress) =>
      worlds?.variants(progress) ?? levels;

  int completedCount(Map<String, int> progress) {
    if (worlds == null) {
      return levels.where((level) => _isCompleted(level, progress)).length;
    }
    return progress.entries
        .where(
          (entry) =>
              entry.value > 0 &&
              (entry.key.startsWith('completed/') ||
                  entry.key.startsWith('wins/')),
        )
        .map(
          (entry) => entry.key.replaceFirst(RegExp(r'^(completed|wins)/'), ''),
        )
        .where((id) => worlds!.contains(id))
        .toSet()
        .length;
  }
}

class TrainscapeWorlds {
  const TrainscapeWorlds(this.id, this.name, this.seedOffset, this.tiers);

  final String id;
  final String name;
  final int seedOffset;
  final List<List<int>> tiers;

  bool contains(String levelId) =>
      levelId.startsWith('$id/') &&
      int.tryParse(levelId.substring(id.length + 1)) != null;

  List<TrainscapeLevel> variants(Map<String, int> progress) {
    final result = <TrainscapeLevel>[];
    for (var index = 0; result.length < 3; index++) {
      final variant = index;
      final level = TrainscapeLevel(
        id: '$id/$variant',
        name: '$name · ${variant + 1}',
        build: () {
          final defaults = Parameters.levelOne(seedOffset + variant);
          if (tiers.isEmpty) return generateLevel(defaults);
          final json = Map<String, Object?>.of(
            jsonDecode(jsonEncode(ParametersType().toJson(defaults)))
                as Map<String, dynamic>,
          );
          json['tierCount'] = tiers[variant % tiers.length];
          return generateLevel(ParametersType().fromJson(json));
        },
      );
      if (!_isCompleted(level, progress)) result.add(level);
    }
    return result;
  }
}

class TrainscapeLevelCatalog {
  const TrainscapeLevelCatalog(this.sections);

  final List<TrainscapeSection> sections;

  Iterable<TrainscapeLevel> get all =>
      sections.expand((section) => section.availableLevels(const {}));
}

Map<String, int> _progress() => Map.of(
  Mobj.getAlreadyLoaded(
        trainscapeProgressID,
        MapType(StringType(), IntType()),
      ).value ??
      const {},
);

int _wonLevelCount(TrainscapeSection section, Map<String, int> progress) =>
    section.completedCount(progress);

bool _isCompleted(TrainscapeLevel level, Map<String, int> progress) =>
    (progress['completed/${level.id}'] ?? 0) > 0 ||
    (progress['wins/${level.id}'] ?? 0) > 0;

bool _isSectionUnlocked(int index, Map<String, int> progress) =>
    index == 0 ||
    _wonLevelCount(trainscapeLevels.sections[index - 1], progress) >=
        trainscapeLevels.sections[index - 1].levelsRequiredToWin;

bool _isUnlocked(TrainscapeLevel level, Map<String, int> progress) {
  final index = trainscapeLevels.sections.indexWhere(
    (section) =>
        section.levels.contains(level) ||
        (section.worlds?.contains(level.id) ?? false),
  );
  return index >= 0 && _isSectionUnlocked(index, progress);
}

void recordTrainscapeWin(TrainscapeLevel level) {
  final mobj = Mobj.getAlreadyLoaded(
    trainscapeProgressID,
    MapType(StringType(), IntType()),
  );
  final before = _progress();
  final after = Map<String, int>.of(before);
  after['wins/${level.id}'] = (after['wins/${level.id}'] ?? 0) + 1;
  after['completed/${level.id}'] = 1;
  final previousIds = {
    for (final section in trainscapeLevels.sections)
      for (final candidate in section.availableLevels(before)) candidate.id,
  };
  for (final candidate in trainscapeLevels.sections.expand(
    (section) => section.availableLevels(after),
  )) {
    if ((!previousIds.contains(candidate.id) ||
            !_isUnlocked(candidate, before)) &&
        _isUnlocked(candidate, after)) {
      after['new/${candidate.id}'] = 1;
    }
  }
  mobj.value = after;
}

void _markPlayed(TrainscapeLevel level) {
  final mobj = Mobj.getAlreadyLoaded(
    trainscapeProgressID,
    MapType(StringType(), IntType()),
  );
  final next = _progress()..removeWhere((key, _) => key.startsWith('new/'));
  next['played/${level.id}'] = 1;
  mobj.value = next;
}

class TrainscapeLevelScreen extends StatefulWidget {
  const TrainscapeLevelScreen({super.key});

  @override
  State<TrainscapeLevelScreen> createState() => _TrainscapeLevelScreenState();
}

class _TrainscapeLevelScreenState extends State<TrainscapeLevelScreen> {
  final _scroll = ScrollController();
  final Signal<Set<String>> _savedLevels = signal({});

  @override
  void initState() {
    super.initState();
    _readSaves();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _readSaves() async {
    final results = await Future.wait([
      for (final level in trainscapeLevels.sections.expand(
        (section) => section.availableLevels(_progress()),
      ))
        hasSavedLevel(level.id).then((saved) => (level.id, saved)),
    ]);
    if (!mounted) return;
    _savedLevels.value = {
      for (final (id, saved) in results)
        if (saved) id,
    };
  }

  Future<void> _askToReset(TrainscapeLevel level) async {
    final reset = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cancel',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) {
        final theme = Theme.of(dialogContext);
        final mako = OurThemeData.fromTheme(theme);
        const dialogMargin = EdgeInsets.all(24);
        const dialogPadding = 16.0;
        const dialogRadius = 32.0;
        final actionRadius = dialogRadius - dialogPadding;
        Widget action(String label, bool result) => InkButton(
          backgroundColor: Colors.transparent,
          borderRadius: BorderRadius.circular(actionRadius),
          onTap: () => Navigator.of(dialogContext).pop(result),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Text(label, style: theme.textTheme.bodyLarge),
          ),
        );
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: RoundedSection(
              color: mako.menuSurfaceFore,
              radius: dialogRadius,
              margin: dialogMargin,
              padding: const EdgeInsets.all(dialogPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reset the save data for this level?',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [action('Cancel', false), action('Reset', true)],
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(animation),
          child: child,
        ),
      ),
    );
    if (reset != true) return;
    await deleteSavedLevel(level.id);
    if (mounted) {
      _savedLevels.value = Set.of(_savedLevels.peek())..remove(level.id);
    }
  }

  Future<void> _play(TrainscapeLevel level) async {
    _markPlayed(level);
    await Navigator.of(context).push(
      OurPageRoute(
        builder: (_) => TrainscapeScreen(
          level: level,
          levelScreenBelow: true,
          onSaveChanged: (saved) {
            if (!mounted) return;
            _savedLevels.value = Set.of(_savedLevels.peek())
              ..remove(level.id)
              ..addAll(saved ? [level.id] : const []);
          },
        ),
      ),
    );
    await _readSaves();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mako = OurThemeData.fromTheme(theme);
    final contentBackground = mako.menuSurfaceFore;
    final headingBackground = mako.menuSurfaceBack;
    return EscapeToPop(
      child: Scaffold(
        backgroundColor: headingBackground,
        body: SignalBuilder(
          builder: (context) {
            final progress = _progress();
            final sections = trainscapeLevels.sections.indexed
                .where((entry) => _isSectionUnlocked(entry.$1, progress))
                .map((entry) => entry.$2)
                .toList();
            final savedLevels = _savedLevels.value;
            final right =
                Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).value ??
                true;
            final lastUnlockedSection = sections.last;
            final levelsStillRequired =
                lastUnlockedSection.levelsRequiredToWin -
                _wonLevelCount(lastUnlockedSection, progress);
            final requirement = <Widget>[
              const Icon(Icons.lock, size: 16),
              const SizedBox(width: 5),
              Text('$levelsStillRequired'),
              const SizedBox(width: 4),
              CustomPaint(
                size: const Size.square(15),
                painter: ItemIconPainter(const HeartIcon()),
              ),
            ];
            return CustomScrollView(
              controller: _scroll,
              slivers: [
                for (final (index, section) in sections.indexed) ...[
                  if (index == 0)
                    SliverToBoxAdapter(
                      child: _levelHeadingBand(
                        theme,
                        headingBackground,
                        MediaQuery.sizeOf(context).height / 2,
                        Text(section.name),
                      ),
                    )
                  else
                    SliverToBoxAdapter(
                      child: _levelHeadingBand(
                        theme,
                        headingBackground,
                        38,
                        Text(section.name),
                      ),
                    ),
                  RoundedSectionSliver(
                    color: contentBackground,
                    padding: EdgeInsets.zero,
                    child: EvenPadColumn(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (section.text != null)
                          MenuTile(
                            title: Text(
                              'Habitat',
                              style: theme.textTheme.bodyLarge,
                            ),
                            onTap: () => Navigator.of(context).push(
                              OurPageRoute(
                                builder: (_) => _HabitatScreen(section.text!),
                              ),
                            ),
                          ),
                        for (final level in section.availableLevels(progress))
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: MenuTile(
                                    title: Opacity(
                                      opacity: _isCompleted(level, progress)
                                          ? 0.5
                                          : 1,
                                      child: Text(
                                        level.name,
                                        style: theme.textTheme.bodyLarge,
                                      ),
                                    ),
                                    onTap: () => _play(level),
                                  ),
                                ),
                                if (savedLevels.contains(level.id))
                                  InkButton(
                                    backgroundColor: Colors.transparent,
                                    borderRadius: BorderRadius.zero,
                                    onTap: () => _askToReset(level),
                                    child: EvenPadding(
                                      all:
                                          MenuTile.defaultPaddingTotal -
                                          MenuTile.defaultPaddingInside,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minWidth: MenuTile.trailingSlotSpan,
                                          minHeight: MenuTile.trailingSlotSpan,
                                        ),
                                        child: Center(
                                          child: Opacity(
                                            opacity:
                                                _isCompleted(level, progress)
                                                ? 0.5
                                                : 1,
                                            child: const Icon(Icons.save),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (progress['new/${level.id}'] == 1)
                                  EvenPadding(
                                    all:
                                        MenuTile.defaultPaddingTotal -
                                        MenuTile.defaultPaddingInside,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: MenuTile.trailingSlotSpan,
                                        minHeight: MenuTile.trailingSlotSpan,
                                      ),
                                      child: Center(
                                        child: Transform.scale(
                                          scale: 0.4,
                                          child: Icon(
                                            Icons.circle,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (sections.length < trainscapeLevels.sections.length &&
                    levelsStillRequired > 0) ...[
                  SliverToBoxAdapter(
                    child: SizedBox(height: MenuTile.defaultPaddingTotal),
                  ),
                  SliverToBoxAdapter(
                    child: Align(
                      alignment: right
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: RoundedSection(
                        color: contentBackground,
                        margin: const EdgeInsets.symmetric(horizontal: 15),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: requirement,
                        ),
                      ),
                    ),
                  ),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 72 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    _savedLevels.dispose();
    super.dispose();
  }
}

Widget _levelHeadingBand(
  ThemeData theme,
  Color background,
  double height,
  Widget label,
) => Container(
  width: double.infinity,
  height: height,
  color: background,
  alignment: Alignment.bottomLeft,
  padding: const EdgeInsets.only(
    left: RoundedSectionSliver.defaultMargin + MenuTile.defaultPaddingTotal,
    bottom: 6,
  ),
  child: DefaultTextStyle(
    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
    child: label,
  ),
);

final trainscapeLevels = TrainscapeLevelCatalog([
  TrainscapeSection(
    name: trainscapeName,
    levelsRequiredToWin: 1,
    levels: [TrainscapeLevel(id: 'locks', name: 'locks', build: _locksLevel)],
  ),
  TrainscapeSection(
    name: 'Suite 1',
    levelsRequiredToWin: 2,
    levels: [
      TrainscapeLevel(id: 'trains', name: 'trains', build: _trainsLevel),
      TrainscapeLevel(id: 'time', name: 'time', build: () => _timeLevel(6)),
      TrainscapeLevel(
        id: 'perfect-time',
        name: 'perfect time',
        build: () => _timeLevel(9),
      ),
    ],
  ),
  TrainscapeSection(
    name: 'Suite 2',
    levelsRequiredToWin: 1,
    levels: [
      TrainscapeLevel(
        id: 'fjelniurn',
        name: 'fjelniurn',
        build: _fjelniurnLevel,
      ),
    ],
  ),
  const TrainscapeSection(
    name: 'Suite 3',
    levelsRequiredToWin: 2,
    worlds: TrainscapeWorlds('known-way', 'known way (world)', 31000, [
      [2, 3, 2],
      [13, 10],
      [3, 2, 3],
    ]),
  ),
  const TrainscapeSection(
    name: 'Suite 4',
    levelsRequiredToWin: 2,
    worlds: TrainscapeWorlds(
      'alternate-way',
      'alternate way (world)',
      41000,
      [],
    ),
  ),
  const TrainscapeSection(
    name: 'Suite 5',
    levelsRequiredToWin: 2,
    worlds: TrainscapeWorlds('true-way', 'true way (world)', 51000, [
      [13, 10, 6, 4],
    ]),
  ),
  const TrainscapeSection(
    name: 'Terminus',
    levelsRequiredToWin: 0,
    text: _habitat,
  ),
]);

Parameters _scenarioParameters({
  required int hearts,
  required TTime timeLimit,
  int seed = 1,
  List<int>? tierCount,
  int? trains,
}) {
  final json = Map<String, Object?>.of(
    jsonDecode(jsonEncode(ParametersType().toJson(Parameters.levelOne(seed))))
        as Map<String, dynamic>,
  );
  json['globalTime'] = timeLimit;
  json['eudaimoniaGoal'] = hearts;
  json['nPlayers'] = 1;
  if (tierCount != null) {
    json['tierCount'] = tierCount;
  }
  if (trains != null) {
    json['nTrains'] = trains;
  }
  return ParametersType().fromJson(json);
}

class _HandLevel {
  _HandLevel({required int hearts, required TTime timeLimit, int seed = 1})
    : params = _scenarioParameters(
        hearts: hearts,
        timeLimit: timeLimit,
        seed: seed,
        tierCount: const [4],
        trains: 0,
      ),
      rng = GameRng(seed) {
    catalog = ItemCatalog.generate(rng, params);
  }

  final Parameters params;
  final GameRng rng;
  late final ItemCatalog catalog;
  final nodes = <Node>[];
  final edges = <Edge>[];
  final trains = <TrainNode>[];

  Item item(int n) => catalog.tiers[0][n - 1];
  Quantity q(int n, [int count = 1]) => Quantity(item(n), count);
  Quantity get heart => Quantity(catalog.eudaimonia, 1);

  Node node(Offset at) {
    final result = Node(at);
    nodes.add(result);
    return result;
  }

  Node relative(Offset offset, {Node? from}) {
    final origin = from ?? nodes.last;
    final result = node(origin.pos + offset);
    connect(origin, result);
    return result;
  }

  Edge connect(Node a, Node b) {
    final edge = Edge(a, b);
    a.edges.add(edge);
    b.edges.add(edge);
    edges.add(edge);
    return edge;
  }

  T facility<T extends Facility>(Node node, T facility) {
    facility.node = node;
    node.facilities.add(facility);
    return facility;
  }

  TrainNode train((Node, double) a, (Node, double) b, {Quantity? cost}) {
    final (aNode, aAngle) = a;
    final (bNode, bAngle) = b;
    final termini = {
      aNode: aNode.pos + angleToOffset(aAngle) * params.trainTerminusDistance,
      bNode: bNode.pos + angleToOffset(bAngle) * params.trainTerminusDistance,
    };
    final train = TrainNode(
      pos: termini[aNode]!,
      activation: cost,
      activationConsumed: cost != null,
      movableFromInside: true,
      schedule: const NeverSchedule(),
      stationNodes: [aNode, bNode],
      terminusFor: termini,
    );
    nodes.add(train);
    trains.add(train);
    facility(aNode, Station(train, StationControl.remote));
    facility(bNode, Station(train, StationControl.remote));
    return train;
  }

  Game finish(Node start) {
    final player = Player(
      playerNames.first,
      HSLuvColor.fromHSL(40, 70, 55).toColor(),
    );
    player.at.value = start;
    start.playersPresent.value = [player];
    final game = Game(
      params: params,
      catalog: catalog,
      nodes: nodes,
      edges: edges,
      players: [player],
      trains: trains,
    );
    game.raiseNode(start);
    for (final train in trains) {
      train.dock(game, train.homeStation);
    }
    game.markOrigin();
    return game;
  }
}

Game _locksLevel() {
  final l = _HandLevel(hearts: 1, timeLimit: 3 * gameDay);
  final start = l.node(Offset.zero);
  final plantDuration = 1 * gameHour;
  l.relative(Offset(0, -2));
  final trade = l.relative(const Offset(0, -2));
  l.facility(trade, Trader([l.q(1), l.q(2)], [l.heart]));
  final a1 = l.relative(const Offset(-2, 0), from: start);
  l.facility(a1, Mugger(l.item(3), MuggerKind.r));
  final a1d = l.relative(Offset(-2.4, 0));
  l.facility(a1d, Tree([l.q(1)], ArbitraryInterval(plantDuration)));
  final a2 = l.relative(const Offset(2, 0), from: start);
  l.facility(a2, Mugger(l.item(1), MuggerKind.r));
  final a2d = l.relative(Offset(2.4, 0));
  l.facility(a2d, Tree([l.q(2)], ArbitraryInterval(plantDuration)));
  final downerer = l.relative(Offset(0, 2), from: start);
  final a3 = l.relative(Offset(2, 0));
  l.facility(a3, Mugger(l.item(2), MuggerKind.r));
  final a3d = l.relative(Offset(2, 0));
  l.facility(a3d, Tree([l.q(3)], ArbitraryInterval(plantDuration)));
  l.relative(Offset(0, 2), from: downerer);
  l.relative(Offset(0, 2.3));
  l.relative(Offset(0, 2.7));
  final fp = l.relative(Offset(0, 4));
  l.facility(fp, Tree([l.q(3)], ArbitraryInterval(plantDuration)));
  return l.finish(start);
}

Game _trainsLevel() {
  final l = _HandLevel(hearts: 1, timeLimit: 1 * gameDay);
  final nc = l.node(Offset.zero);
  // node separation
  final ns = 3;
  final triu = ns * sqrt(3 / 4) / 3;
  final n12 = l.relative(Offset(-ns / 2, triu), from: nc);
  final n13 = l.relative(Offset(ns / 2, triu), from: nc);
  final n11 = l.relative(Offset(0, -ns * sqrt(3 / 4) * 2 / 3), from: nc);
  l.connect(n11, n12);
  l.connect(n12, n13);
  l.connect(n13, n11);
  l.facility(n12, Tree([l.q(2)], ArbitraryInterval(3 * gameHour)));
  l.facility(n13, Tree([l.q(3)], ArbitraryInterval(3 * gameHour)));
  l.facility(n11, Trader([l.q(1)], [l.heart]));
  final n21 = l.node(const Offset(-1, 14));
  l.train((n13, pi / 2), (n21, -pi / 2));
  var chain = n21;
  for (var i = 0; i < 8; i++) {
    chain = l.relative(
      Offset(0, ns + l.rng.nextDouble() * ns * 0.2),
      from: chain,
    );
    if (i == 3) {
      l.facility(chain, Mugger(l.item(2), MuggerKind.rc));
    }
    if (i == 5) {
      l.facility(chain, Tree([l.q(4)], ArbitraryInterval(3 * gameHour)));
    }
  }
  final n29 = chain;
  l.facility(n29, Trader([l.q(3)], [l.q(1)]));

  final n22 = l.relative(const Offset(2.3, 0), from: n21);
  final n23 = l.relative(angleToOffset(pi / 3) * 2.3, from: n22);
  l.facility(n23, Storage(4));
  l.facility(n23, Tree([l.q(4)], ArbitraryInterval(3 * gameHour)));
  l.train((n22, 2 * pi / 3), (n29, pi), cost: l.q(4));
  return l.finish(nc);
}

Game _timeLevel(int hearts) {
  final l = _HandLevel(hearts: hearts, timeLimit: 1 * gameDay);
  final grid = <List<Node?>>[];
  for (var y = 0; y < 5; y++) {
    grid.add([]);
    for (var x = 0; x < 6; x++) {
      grid[y].add(
        (x == 0 || x == 5 || y == 0 || y == 4)
            ? l.node(Offset(x * 3.0, y * 3.0))
            : null,
      );
    }
  }
  final ring = [for (final row in grid) ...row.whereType<Node>()];
  for (var y = 0; y < grid.length; y++) {
    for (var x = 0; x < grid[y].length; x++) {
      final node = grid[y][x];
      if (node == null) continue;
      if (x + 1 < grid[y].length && grid[y][x + 1] != null) {
        l.connect(node, grid[y][x + 1]!);
      }
      if (y + 1 < grid.length && grid[y + 1][x] != null) {
        l.connect(node, grid[y + 1][x]!);
      }
    }
  }
  l.facility(ring[0], Tree([l.q(1)], ArbitraryInterval(3 * gameHour)));
  l.facility(ring[1], Tree([l.q(2)], ArbitraryInterval(3 * gameHour)));
  l.facility(ring[3], Trader([l.q(3)], [l.q(1), l.q(2)]));
  l.facility(ring[5], Trader([l.q(1, 4)], [l.q(3)]));
  l.facility(ring[8], Trader([l.q(1)], [l.heart]));
  l.facility(ring[11], Trader([l.q(2)], [l.heart]));
  l.facility(ring[13], JumpStation(cost: l.q(3)));
  l.facility(ring[2], LandingStation());
  return l.finish(ring.first);
}

Game _fjelniurnLevel() => generateLevel(
  _scenarioParameters(hearts: 3, timeLimit: 3 * gameDay, seed: 24763),
);

class _HabitatScreen extends StatelessWidget {
  const _HabitatScreen(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => InfoScaffold(
    title: const Text('Habitat'),
    slivers: [markdownPageSliver(Theme.of(context), text, selectable: false)],
  );
}

const _habitat = '''We wouldn't recognize our home.

Modern pitcher plants promise echoes matching the shape of our wounds and many of us die in them. Others dwindle as fresh plague bubbles over our feet.

Humanity's home shore is shattering and sinking.
There are many habitable places, but all varying degrees of abyssal. There's nowhere left on the shore. There must be one place of minimal compromise where the most humanlike remaining things still defiantly flourish, reachable only by those with absolute courage that is tempered with inerrent wisdom. Dismally, you'll think that's you. But you are not among those people. Your place will be further down.
As you descend, as you're embedded in your abyssal cell, you will hear the screams of the humans who couldn't or wouldn't sink as deep as you did as they're dashed and swallowed by monsters older than you. You will feel guilty when you are spared. They will spare you because you no longer taste good.
One day, long after your descent, you will learn of a place closer to the shore, a place of lesser compromise. You will learn how you could have kept your hair or your smooth scaleless skin, but you were too fearful, or too stupid, to find that place, you casted it all away. You might shudder in grief. Or, now an abyssal thing, you may not grieve at all, you may chuckle ruefully, for that thing you grew from, who cared, is dead, their memories dissolve in your maw.
Look the other way, downwards, you will only see greater older monsters, chuckling ruefully about how you kept your brown eyes, or your flat face, and how pathetic you are for doing that.

But you aren't an abyssal thing, yet.
The sooner you accept that your shore is soon to shatter and sink, the lesser the compromise you will need to enact.
Your vision is going to need to improve. We know that it is inhuman to see like us, but we don't believe there is any place of lesser compromise than ours. You don't believe us, yet? You don't have much time.''';
