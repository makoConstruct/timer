import 'dart:math';
import 'dart:async';

import 'package:animated_to/animated_to.dart';
import 'package:improved_wrap/improved_wrap.dart';
// imported as because there's a name collision with Column, lmao
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hsluv/extensions.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/boring.dart' as boring;
import 'package:makos_timer/database.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:uuid/v4.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) {
    switch (task) {
      case 'wait_for_timer':
        {
          final timer = inputData?['timer'];
        }
    }
    return Future.value(true);
  });
}

final MobjID timerListID = '0afc1e39-9ed7-4174-8d72-e9319224d6e8';
final MobjID transientTimerListID = '0c02ee9a-6618-4231-a8c9-36f145970a4c';
final MobjID dbVersionID = '87012e13-974b-45f6-b0d7-ea8d1a3127ed';
// some spares
// cd813df3-bb7b-4b69-a238-89b4971198ef
// baa10d03-aa7f-4cc6-bd58-0c62bdaa9757

Future<void> torchDatabase(TheDatabase db) async {
  print('CRITICAL ERROR: Clearing all data from the database!');
  await db.kVs.deleteAll();
}

Future<void> initializeDatabase() async {
  final db = TheDatabase();
  // await torchDatabase(db);
  // the db will be accessed via this singleton from then on
  // initialize version one of the db
  await MobjRegistry.initialize(db);
  final fversion = Mobj.getOrCreate(dbVersionID,
      type: const IntType(), initial: () => 0, debugLabel: "version");
  await Future.wait([
    // we know that the data required for the app is minimal enough that we should wait until it's loaded before showing anything... idk not sure I believe this
    Mobj.getOrCreate(timerListID,
        type: ListType(const StringType()),
        initial: () => <MobjID>[],
        debugLabel: "pinned timers"),
    Mobj.getOrCreate(transientTimerListID,
        type: ListType(const StringType()),
        initial: () => <MobjID>[],
        debugLabel: "transient timers"),
    fversion,
  ]);
}

void main() async {
  await initializeDatabase();
  runApp(const TimersApp());
}

// List<Widget> diffRetainingOrder(List<Widget> old, List<Widget> current) {
//   List<Widget> ret = [];
//   HashSet<Widget> oldSet = HashSet.from(old);
//   HashSet<Widget> oldKeys = HashSet.from(old.map((w) => w.key));
//   for (var c in current) {
//     if (oldSet.contains(c)) {
// }

/// the angleTime is a set of milestones, points where, when the dial is rotated to that point, the time will be that milestone's time in seconds, and between milestones, the time is interpolated. Milestones will also be shown on the dial as space becomes available (which is going to be complicated to code).
// or it used to be, we decided to disable that in favor of differen dials with different gearings, which commenting out most of the milestones effectively achieves (the last milestone just gets extrapolated)
final List<(double, double)> angleTimeSeconds = [
  (0, 0),
  (pi, 60),
  // (2 * pi, 2 * 60),
  // (3 * pi, 10 * 60),
  // (4 * pi, 60 * 60),
  // (5 * pi, 2 * 60 * 60),
  // (6 * pi, 3 * 60 * 60),
  // (7 * pi, 4 * 60 * 60),
  // (8 * pi, 5 * 60 * 60),
  // (9 * pi, 6 * 60 * 60),
  // (10 * pi, 12 * 60 * 60),
  // (11 * pi, 24 * 60 * 60),
  // (12 * pi, 48 * 60 * 60),
  // (13 * pi, 7 * 24 * 60 * 60),
  // (14 * pi, 365 * 24 * 60 * 60),
  // (15 * pi, 2 * 365 * 24 * 60 * 60),
  // (16 * pi, 5 * 365 * 24 * 60 * 60),
  // (17 * pi, 10 * 365 * 24 * 60 * 60),
  // (18 * pi, 20 * 365 * 24 * 60 * 60),
  // (19 * pi, 40 * 365 * 24 * 60 * 60),
  // (20 * pi, 100 * 365 * 24 * 60 * 60),
  // (21 * pi, 200 * 365 * 24 * 60 * 60),
];

const double numeralDragDistanceTs = 0.5;
const double standardLineWidth = 6;
const double standardButtonSizeMM = 13;
const double timerPaddingr = 6;

final List<(double, double)> angleTimeMinutes = [(0, 0), (tau, 6 * 60)];

/// basically just linearly interpolates the relevant angleTime segment
double angleToTimeSeconds(double angle) {
  return angleToTime(angle, angleTimeSeconds);
}

/// basically just linearly interpolates the relevant angleTime segment
double angleToTimeMinutes(double angle) {
  return angleToTime(angle, angleTimeMinutes);
}

double angleToTime(double angle, List<(double, double)> angleTimeSeconds) {
  final sign = angle.sign;
  angle = angle.abs();
  var lower = angleTimeSeconds[0];
  for (int i = 1; i < angleTimeSeconds.length; i++) {
    final upper = angleTimeSeconds[i];
    if (angle < upper.$1) {
      return lerp(lower.$2, upper.$2, unlerpUnit(lower.$1, upper.$1, angle));
    }
    lower = upper;
  }
  final lp = angleTimeSeconds.last;
  double lastad = lp.$1 - angleTimeSeconds[angleTimeSeconds.length - 2].$1;
  double lasttd = lp.$2 - angleTimeSeconds[angleTimeSeconds.length - 2].$2;
  return sign * (lp.$2 + (angle - lp.$1) / lastad * lasttd);
}

class Thumbspan {
  /// measured in logical pixels
  double thumbspan;
  Thumbspan(this.thumbspan);
  static double of(BuildContext context, {bool listen = false}) {
    return Provider.of<Thumbspan>(context, listen: listen).thumbspan;
  }
}

class TimersApp extends StatefulWidget {
  const TimersApp({super.key});

  @override
  State<TimersApp> createState() => _TimersAppState();
}

class _TimersAppState extends State<TimersApp> {
  late Future<JukeBox> jukeBox;
  _TimersAppState() {
    WidgetsFlutterBinding.ensureInitialized();
    jukeBox = JukeBox.create();
  }
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'timer',
      theme: ThemeData(
        useMaterial3: true,
      ),
      home: MultiProvider(
          providers: [
            Provider<Thumbspan>(
                create: (context) => Thumbspan(lpixPerThumbspan(context))),
            Provider<Future<JukeBox>>(create: (_) => jukeBox),
          ],
          child: FutureAssumer<List<Mobj>>(
              // awaiting the list and also all of the timers
              future: Mobj.getOrCreate<List<String>>(timerListID,
                      type: ListType(const StringType()),
                      initial: () => [],
                      debugLabel: "list")
                  .then((v) {
                return Future.wait(<Future<Mobj>>[Future.value(v)] +
                    v.value!
                        .map(
                            (ti) => Mobj.fetch(ti, type: const TimerDataType()))
                        .toList());
              }),
              builder: (context, v) {
                final ml = v[0] as Mobj<List<MobjID>>;
                return Timerscreen(
                  timerList: ml,
                  timers: Map.fromEntries(
                      v.sublist(1, v.length).map((mt) => MapEntry(
                          mt.id,
                          Timer(
                            key: GlobalKey(),
                            owningList: ml.id,
                            mobj: mt as Mobj<TimerData>,
                            animateIn: false,
                          )))),
                  selectLastTimer: true,
                );
              })),
    );
  }
}

/// Timer widget, contrast with Timer row from the database orm
class Timer extends StatefulWidget {
  final Mobj<TimerData> mobj;
  final bool animateIn;
  final MobjID? owningList;
  const Timer({
    required GlobalKey<TimerState> key,
    required this.mobj,
    this.animateIn = true,
    required this.owningList,
  }) : super(key: key);

  @override
  State<Timer> createState() => TimerState();
}

class TimerState extends State<Timer>
    with SignalsMixin, TickerProviderStateMixin {
  // peek mobj data
  TimerData get p => widget.mobj.peek()!;

  late Ticker _ticker;
  // in seconds
  double currentTime = 0;
  late AnimationController _runningAnimation;
  final GlobalKey _clockKey = GlobalKey();
  final GlobalKey animatedToKey = GlobalKey();
  final previousSize = ValueNotifier<Size?>(null);
  final transferrableKey = GlobalKey();

  /// kept so that drag handlers will know to remove it from the lsit
  late MobjID? owningList;

  // maybe I should just use an animated_to like approach. I'm pretty sure the current approach (AnimatedContainers) wont work because when we transfer between two containers a remove will play that will mount the same globalkey twice. Terrible.
  // /// set at the end of a drag animation with the position of the drag item relative to the parent
  // Offset? comingHomeFrom;

  set selected(bool v) {
    widget.mobj.value = p.withChanges(selected: v);
  }

  // not sure we use this
  // set duration(double d) {
  //   final digits = durationToDigits(d);
  //   if (currentTime >= d) {
  //     currentTime = d;
  //     isCompleted = true;
  //   } else {
  //     isCompleted = false;
  //   }
  // }

  double get duration {
    return durationToSeconds(digitsToDuration(p.digits));
  }

  set digits(List<int> value) {
    widget.mobj.value = p.withChanges(digits: value);
  }

  static Color backgroundColor(double hue) =>
      hpluvToRGBColor([hue * 360, 100, 90]);
  static Color primaryColor(double hue) =>
      hpluvToRGBColor([hue * 360, 100, 30]);

  // the timerID should never change, we don't respond to widget updates
  // @override
  // void didUpdateWidget(Timer oldWidget) {
  //   super.didUpdateWidget(oldWidget);
  //   if (widget.hue != oldWidget.hue) {
  //     setState(() {
  //       hue = widget.hue;
  //     });
  //   }
  // }

  @override
  void initState() {
    owningList = widget.owningList;
    super.initState();
    _runningAnimation = AnimationController(
        duration: const Duration(milliseconds: 80), vsync: this);
    _ticker = createTicker((d) {
      setTime(durationToSeconds(DateTime.now().difference(p.startTime)));
    });
    TimerData? prev;
    createEffect(() {
      TimerData d = widget.mobj.value!;
      _updateRunning(from: prev, to: d);
      prev = d;
    });
  }

  @override
  dispose() {
    _runningAnimation.dispose();
    _ticker.dispose();
    previousSize.dispose();
    // timers aren't deloaded so don't ref down I guess
    // widget.mobj.dispose();
    super.dispose();
  }

  void setTime(double nd) {
    if (currentTime == nd) {
      return;
    }
    final d = p;
    setState(() {
      currentTime = nd;
      if (d.isRunning &&
          nd >= durationToSeconds(digitsToDuration(d.digits)) &&
          !d.isCompleted) {
        // [todo] after background tasks, let the background task set off the timer instead of doing it here?
        triggerAlert();
      }
    });
  }

  void triggerAlert() {
    JukeBox.jarringSound(context);
    _runningAnimation.reverse();
    _ticker.stop();
    setTime(0);
    widget.mobj.value = p.withChanges(
      runningState: 2,
      // here to note that we don't have this feature (prolonged alarms) in
      isGoingOff: false,
    );

    //todo: check to see whether the timer is visible in the list view. If not, do a push notification alert. Otherwise just make it do an animation and play a brief sound. Don't require an interaction, the user knows.
  }

  void _updateRunning({required TimerData? from, required TimerData to}) {
    if (from != null && from.isRunning == to.isRunning) {
      return;
    }
    if (to.isRunning) {
      _runningAnimation.forward();
      _ticker.start();
    } else {
      _runningAnimation.reverse();
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = watchSignal(context, widget.mobj)!;
    final theme = Theme.of(context);
    final mover = 0.1;
    final thumbSpan = Thumbspan.of(context);

    final dd = durationToSeconds(
        digitsToDuration(watchSignal(context, widget.mobj)!.digits));
    double pieCompletion = dd == 0 ? 0 : clampUnit(currentTime / dd);
    final durationDigits = d.digits;
    final timeDigits = durationToDigits(currentTime,
        padLevel: padLevelFor(durationDigits.length));

    List<int> withDigitsReplacedWith(List<int> v, int d) =>
        List.filled(v.length, d);

    final Widget timeText = DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: AnimatedBuilder(
          animation: _runningAnimation,
          builder: (context, child) {
            final v = Curves.easeInCubic.transform(_runningAnimation.value);
            return FractionalTranslation(
                translation: Offset(0, lerp(-mover, mover, v)),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // adding a second layer underneath the top text so that if the width of the numerals changes the width of the timer doesn't. We assume that 0 is the widest digit, because it was on mako's machine. If this fails to hold, we can precalculate which is the widest digit.
                      Stack(children: [
                        Opacity(
                            opacity: 0,
                            child: Text(boring.formatTime(
                                withDigitsReplacedWith(timeDigits, 0)))),
                        Transform.scale(
                            alignment: Alignment.bottomLeft,
                            scale: lerp(0.6, 1, v),
                            child: Text(boring.formatTime(timeDigits)))
                      ]),
                      Transform.scale(
                          alignment: Alignment.topLeft,
                          scale: lerp(1, 0.6, v),
                          child: Text(boring.formatTime(durationDigits))),
                    ]));
          },
        ));

    final expandingHindCircle = AnimatedBuilder(
        animation: _runningAnimation,
        builder: (context, child) => Visibility(
            visible: _runningAnimation.value != 0,
            maintainSize: true,
            maintainState: true,
            maintainAnimation: true,
            child: Transform.scale(
              scale: 1 + _runningAnimation.value * 3,
              child: Container(
                  decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerLowest,
              )),
            )));

    Widget clockDial(Key? key, Widget? expandingHindCircle) {
      return AnimatedBuilder(
          key: key,
          animation: _runningAnimation,
          builder: (context, child) => Container(
                padding: EdgeInsets.all(
                    (1 - _runningAnimation.value) * timerPaddingr),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surfaceContainerLowest,
                ),
                constraints: BoxConstraints(maxHeight: 49, maxWidth: 49),
                child: child,
              ),
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              if (expandingHindCircle != null) expandingHindCircle,
              // there's a very strange bug where the pie doesn't repaint when the timer is being dragged. Every other animation still works. I checked, and although build is being called, shouldRepaint isn't. I'm gonna ignore it for now.
              // oh! and I notice the numbers don't update either!
              Pie(
                backgroundColor: backgroundColor(d.hue),
                color: primaryColor(d.hue),
                value: pieCompletion,
              ),
            ],
          ));
    }

    Widget result = GestureDetector(
      onTap: () {
        context
            .findAncestorStateOfType<TimerScreenState>()
            ?.takeActionOn(widget.mobj.id);
        // toggleRunning();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(timerPaddingr),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            clockDial(_clockKey, expandingHindCircle),
            SizedBox(width: timerPaddingr),
            timeText,
          ],
        ),
      ),
    );

    result = AnimatedBuilder(
      animation: _runningAnimation,
      builder: (context, child) => Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
              shape: BoxShape.rectangle,
              // the animation is mostly conveyed by the expanding circle, so only turn on as a contingency in case the circle doesn't fill it
              color: _runningAnimation.value == 1
                  ? theme.colorScheme.surfaceContainerLowest
                  : theme.colorScheme.surfaceContainerLowest.withAlpha(0)),
          child: child),
      child: result,
    );

    result = AnimatedTo.spring(globalKey: animatedToKey, child: result);

    result = SizeReporter(
        key: transferrableKey, previousSize: previousSize, child: result);

    return DraggableWidget<GlobalKey<TimerState>>(
        data: widget.key as GlobalKey<TimerState>, child: result);

    // return result;
  }
}

class DraggableFeedbackPositionBox {
  Offset begin = Offset.zero;
}

class FadingDial extends AnimatedWidget {
  final double angle;
  final double radius;
  final Color topColor;
  final Color bottomColor;
  final double holeRadius;
  const FadingDial({
    super.key,
    required super.listenable,
    required this.angle,
    required this.radius,
    required this.topColor,
    required this.bottomColor,
    this.holeRadius = 0,
  });

  Animation<double> get visibility => listenable as Animation<double>;
  @override
  Widget build(BuildContext context) {
    final vv = visibility.value;
    return FractionalTranslation(
        translation: Offset(-0.5, -0.5),
        child: Transform.rotate(
            angle: angle,
            child: Opacity(
                opacity: vv,
                child: AnimatedScale(
                    scale: lerp(0.9, 1.0, vv),
                    duration: Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    child: CustomPaint(
                      size: Size.square(radius * 2),
                      painter: SweepGradientCirclePainter(topColor, bottomColor,
                          holeRadius: holeRadius),
                    )))));
  }
}

// I don't think this works right. It needs to diff children and *also* maintain a separate stateful stack, or have no children at all, or maybe just one.
// /// something that self-removing widgets can seek and remove themselves from. Example of such a widget: Animated ones that need to be removed when their timer runs down.
// class RemovalHost extends StatefulWidget {
//   /// if a new widget is identified with this one that has a different initialChildren, it will be ignored. RemovalHosts manage their children statefully.
//   final List<Widget> initialChildren;
//   final Widget Function(BuildContext context, List<Widget> children) builder;
//   const RemovalHost(
//       {super.key, required this.initialChildren, required this.builder});
//   @override
//   State<RemovalHost> createState() => RemovalHostState();

//   static RemovalHostState? of(BuildContext context) {
//     return context.findAncestorStateOfType<RemovalHostState>()!;
//   }
// }

// class RemovalHostState extends State<RemovalHost> {
//   List<Widget> children = [];
//   @override
//   void initState() {
//     super.initState();
//     children = List.from(widget.initialChildren);
//   }

//   add(Widget w) {
//     setState(() {
//       children.add(w);
//     });
//   }

//   remove(GlobalKey key) {
//     setState(() {
//       children.removeWhere((w) => w.key == key);
//     });
//   }

//   // I notice I kinda wanna animate removals, but no, ImplicitlyAnimatedList can't do that, it really has to be a list.
//   @override
//   void didUpdateWidget(RemovalHost oldWidget) {
//     super.didUpdateWidget(oldWidget);
//     if (widget.initialChildren != oldWidget.initialChildren) {
//       setState(() {
//         children = List.from(widget.initialChildren);
//       });
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return widget.builder(context, children);
//   }
// }

// class RemovalStack extends RemovalHost {
//   RemovalStack({super.key, required super.initialChildren})
//       : super(builder: (context, children) => Stack(children: children));
// }

final timerListType = ListType(StringType());

/// A widget that displays a sequence of timers with drag and drop functionality.
/// Can optionally be displayed within a scrollview.
class TimerTray extends StatefulWidget {
  /// The Mobj that stores the timer data list. Replacing this with a MobjID wouldn't be a big deal
  final Mobj<List<MobjID<TimerData>>> mobj;

  /// Background color for the sequence container
  final Color backgroundColor;

  /// Icon widget that displays above the sequence
  final Widget icon;

  /// Whether this sequence should render within a scrollview
  final bool useScrollView;

  /// Callback for when a timer is dropped into this sequence
  final Function(MobjID<TimerData> timerId)? onTimerDropped;

  const TimerTray({
    super.key,
    required this.mobj,
    required this.backgroundColor,
    required this.icon,
    this.useScrollView = true,
    this.onTimerDropped,
  });

  @override
  State<TimerTray> createState() => _TimerTrayState();
}

typedef TimerWidgets = Map<MobjID<TimerData>, Timer>;

class _TimerTrayState extends State<TimerTray> with SignalsMixin {
  late final GlobalKey wrapKey;
  late final Computed<TimerWidgets> timerWidgets;

  @override
  void initState() {
    super.initState();
    wrapKey = GlobalKey();

    TimerWidgets? prev;
    timerWidgets = createComputed(() {
      TimerWidgets next = {};
      for (MobjID t in widget.mobj.value!) {
        next[t] = (prev != null ? prev![t] : null) ??
            Timer(
                key: GlobalKey(),
                mobj: Mobj.getAlreadyLoaded(t, TimerDataType()),
                animateIn: false,
                owningList: widget.mobj.id);
      }
      prev = next;
      return next;
    });
  }

  List<MobjID<TimerData>> get p => widget.mobj.peek()!;

  @override
  Widget build(BuildContext context) {
    final timerWidgetsValue = timerWidgets.value;
    final timersWrapWidget = IWrap(
      key: wrapKey,
      textDirection: TextDirection.ltr,
      clipBehavior: Clip.none,
      verticalDirection: VerticalDirection.down,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.end,
      runAlignment: WrapAlignment.end,
      children: watchSignal(context, widget.mobj)!
          .map((ki) => timerWidgetsValue[ki]!)
          .toList(),
    );

    final columnContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Icon at the top
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: widget.icon,
        ),
        timersWrapWidget,
      ],
    );

    Widget res = Container(
        // constraints: BoxConstraints(maxheight: double.infinity)
        child: widget.useScrollView
            ? SingleChildScrollView(
                reverse: true,
                child: columnContent,
              )
            : columnContent);

    return DragTarget<GlobalKey<TimerState>>(
      builder: (context, candidateData, rejectedData) => res,
      onMove: (DragTargetDetails<GlobalKey<TimerState>> details) {
        // Could add visual feedback here if needed
      },
      onAcceptWithDetails: (details) {
        final insertion = insertionOf(wrapKey, details.offset);
        final tkey = details.data;
        final timerId = (tkey.currentWidget! as Timer).mobj.id;
        final currentIndex = p.indexWhere((t) => t == timerId);

        TimerState cs = details.data.currentState!;
        doInsertion(int at) {
          widget.mobj.value = p.toList()..insert(at, cs.widget.mobj.id);
        }

        //transaction start
        if (cs.owningList == null) {
          doInsertion(insertion.midwayInsertionIndex());
        } else {
          Mobj<List<MobjID>> oldList =
              Mobj.getAlreadyLoaded(cs.owningList!, timerListType);
          simpleRemove() {
            oldList.value = oldList.peek()!.toList()..removeAt(currentIndex);
          }

          if (cs.owningList == widget.mobj.id) {
            assert(currentIndex != -1,
                "item wasn't found inside of its owningList");
            final (operative, at) =
                insertion.cleverInsertionIndexFor(currentIndex, p.length);
            if (operative) {
              widget.mobj.value = p.toList()
                ..insert(at, cs.widget.mobj.id)
                ..removeAt(currentIndex > at ? currentIndex + 1 : currentIndex);
            }
          } else {
            doInsertion(insertion.midwayInsertionIndex());
            simpleRemove();
          }
        }
        cs.owningList = widget.mobj.id;

        bool noDuplicates<T>(List<T> v) {
          for (int i = 0; i < v.length; ++i) {
            for (int j = i + 1; j < v.length; ++j) {
              if (v[i] == v[j]) {
                return false;
              }
            }
          }
          return true;
        }

        assert(noDuplicates(p));

        widget.onTimerDropped?.call(timerId);
        //transaction end
      },
    );
  }
}

class Timerscreen extends StatefulWidget {
  final bool selectLastTimer;
  // we require an exposed Mobj because this has complex state and we really don't want to have to then everything on a future
  final Mobj<List<MobjID<TimerData>>> timerList;

  /// you have to pass these in because we want to ensure they're pre-loaded as well.
  final Map<MobjID, Timer> timers;

  const Timerscreen(
      {super.key,
      required this.timerList,
      required this.timers,
      this.selectLastTimer = true});

  @override
  State<Timerscreen> createState() => TimerScreenState();
}

/// a circle of colors sampled from a uniform circle in the hsluv space at lightness 70
/// for some reason like none of the hsluv apis provide polar coordinates, so you can't get perceptually uniform saturation. I refuse to implement polar coordinates, so I just copied some points at constant saturation from the hsluv site.
const List<HSLuvColor> colorCircle = [
  HSLuvColor.fromHSL(0, 67, 70),
  HSLuvColor.fromHSL(26.7, 54, 70),
  HSLuvColor.fromHSL(48.1, 58, 70),
  HSLuvColor.fromHSL(81, 72, 70),
  HSLuvColor.fromHSL(111, 63, 70),
  HSLuvColor.fromHSL(134, 60, 70),
  HSLuvColor.fromHSL(158, 88, 70),
  HSLuvColor.fromHSL(180, 100, 70),
  HSLuvColor.fromHSL(205, 94, 70),
  HSLuvColor.fromHSL(234, 67, 70),
  HSLuvColor.fromHSL(262, 69, 70),
  HSLuvColor.fromHSL(294, 61, 70),
  HSLuvColor.fromHSL(326, 63, 70),
  HSLuvColor.fromHSL(346, 68, 70),
];

/// hue is in degrees
/// we might not need this, hpluv is pretty good.
HSLuvColor interpolateHuePoints(double hue, List<HSLuvColor> colorCircle) {
  assert(hue >= 0 && hue <= 360);
  hue = hue % 360;
  // then move iHint so that it's lower than or equal tohue
  int iHint = (hue / 360 * colorCircle.length).floor();
  while (colorCircle[iHint].hue > hue) {
    if (iHint == 0) {
      break;
    }
    iHint -= 1;
  }
  // but that it's the highest allowable hue
  while (iHint < colorCircle.length - 1 && colorCircle[iHint + 1].hue <= hue) {
    iHint += 1;
  }
  // now interpolate between the two colors
  final lower = colorCircle[iHint];
  final upper = colorCircle[(iHint + 1) % colorCircle.length];
  final hueDiff = iHint < colorCircle.length - 1
      ? upper.hue - lower.hue
      : 360 - lower.hue + upper.hue;
  final t = (hue - lower.hue) / hueDiff;
  return HSLuvColor.fromHSL(
      lerp(lower.hue, upper.hue, t),
      lerp(lower.saturation, upper.saturation, t),
      lerp(lower.lightness, upper.lightness, t));
}

class TimerScreenState extends State<Timerscreen>
    with SignalsMixin, TickerProviderStateMixin {
  MobjID<TimerData>? selectedTimer;

  bool isRightHanded = true;
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => widget.timerList.value!;
  List<MobjID<TimerData>> peekTimers() => widget.timerList.peek()!;

  GlobalKey controlPadKey = GlobalKey();
  Offset numeralDragStart = Offset.zero;
  late final AnimationController numeralDragIndicator;
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());
  // a lime green default as the first color
  double nextHue = 0.252;

  @override
  void initState() {
    super.initState();
    numeralDragIndicator =
        AnimationController(vsync: this, duration: Duration(milliseconds: 70));
  }

  @override
  void dispose() {
    super.dispose();
    numeralDragIndicator.dispose();
  }

  void takeActionOn(MobjID<TimerData> timerID) {
    //todo: take whichever action is currently highlighted
    toggleRunning(timerID, reset: false);
  }

  double nextRandomHue() {
    final ret = nextHue;
    final increment = 0.15 + Random().nextDouble() * 0.08;
    nextHue += increment;
    return (ret * 360) % 360;
  }

  void numeralPressed(List<int> number, {bool viaKeyboard = false}) {
    if (selectedTimer == null) {
      addNewTimer(
        selected: true,
        digits: stripZeroes(number),
      );
    } else {
      final mt = Mobj.getAlreadyLoaded(selectedTimer!, TimerDataType());
      List<int> ct = List.from(mt.peek()!.digits);
      for (int n in number) {
        ct.add(n);
      }
      mt.value = mt.peek()!.withChanges(digits: ct);
    }
    if (viaKeyboard) {
      final flashAnimation = numeralKeys[number.first].currentState?.longFlash;
      if (flashAnimation != null) {
        flashAnimation.forward(from: 0);
      }
    }
  }

  // Add new method to handle key events
  void _handleKeyPress(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return;
    }
    // Handle number keys 0-9
    int? kn = recognizeDigitPress(event.logicalKey);
    if (kn != null) {
      numeralPressed([kn], viaKeyboard: true);
    } else {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.backspace:
          _backspace();
          break;
        case LogicalKeyboardKey.keyP:
        case LogicalKeyboardKey.space:
        case LogicalKeyboardKey.enter:
          pausePlaySelected();
          break;
        case LogicalKeyboardKey.keyN:
          addNewTimer(selected: true);
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // todo: trying to determine the physical dimensions of the screen so that we know how many logical pixels to assign to ergonomic controls
    const int falcrumAnimationDurationMs = 140;

    double lpixPerMM = boring.lpixPerMM(context);

    ThemeData theme = Theme.of(context);

    //buttons
    var configButton = TimersButton(
        label: Icon(Icons.edit_rounded),
        onPanDown: (_) {
          JukeBox.jarringSound(context);
        });

    //buttons
    var selectButton = TimersButton(
        // label: Icon(Icons.select_all),
        // label: Icon(Icons.border_outer_rounded),
        label: Icon(Icons.center_focus_strong),
        onPanDown: (_) {
          JukeBox.jarringSound(context);
        });

    var backspaceButton = TimersButton(
        label: Icon(Icons.backspace),
        onPanDown: (_) {
          _backspace();
        });

    final addButton = TimersButton(
        label: Icon(Icons.add_circle),
        onPanDown: (_) {
          addNewTimer(selected: true);
        });

    // todo: animate the play icon out when playing
    Widget playIcon(Icon otherIcon) {
      // todo: measure the width of the icons to make this precise
      double dispf = 0.3;
      return Stack(children: [
        FractionalTranslation(translation: Offset(-dispf, 0), child: otherIcon),
        Transform.scale(
            scale: 0.8,
            child: FractionalTranslation(
                translation: Offset(dispf, 0),
                child: Icon(Icons.play_arrow_rounded)))
      ]);
    }

    final pausePlayButton = TimersButton(
        label: playIcon(Icon(Icons.pause_rounded)),
        onPanDown: (_) {
          pausePlaySelected();
        });
    final stopPlayButton = TimersButton(
        label: playIcon(Icon(Icons.restart_alt_rounded)),
        onPanDown: (_) {
          pausePlaySelected(true);
        });

    final doubleZeroButton = NumberButton(digits: [0, 0]);
    final zeroButton =
        NumberButton(digits: [0], timerButtonKey: numeralKeys[0]);

    List<Widget> controlPadWidgets(bool isRightHanded) {
      /// the number pad isn't flipped for lefthanded mode
      Widget pad(int column, int row) {
        row = isRightHanded ? row : 2 - row;
        final n = row * 3 + column + 1;
        return NumberButton(digits: [n], timerButtonKey: numeralKeys[n]);
      }

      return reverseIfNot(isRightHanded, [
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(child: backspaceButton),
              Flexible(child: configButton),
              Flexible(child: stopPlayButton),
              Flexible(child: pausePlayButton),
            ],
          ),
        ),
        Flexible(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(child: pad(0, 0)),
            Flexible(child: pad(0, 1)),
            Flexible(child: pad(0, 2)),
            Flexible(child: doubleZeroButton),
          ],
        )),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(child: pad(1, 0)),
              Flexible(child: pad(1, 1)),
              Flexible(child: pad(1, 2)),
              Flexible(child: zeroButton),
            ],
          ),
        ),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(child: pad(2, 0)),
              Flexible(child: pad(2, 1)),
              Flexible(child: pad(2, 2)),
            ],
          ),
        ),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(child: addButton),
              Flexible(child: selectButton),
            ],
          ),
        ),
      ]);
    }

    final thumbSpan = Thumbspan.of(context);
    final buttonSpan = thumbSpan * 0.7;

    // the lower part of the screen
    final controls = Container(
      clipBehavior: Clip.hardEdge,
      decoration:
          BoxDecoration(color: theme.colorScheme.surfaceContainerLowest),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              alignment: Alignment.bottomRight,
              children: [
                Container(
                  key: controlPadKey,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: isRightHanded
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: controlPadWidgets(isRightHanded),
                  ),
                )
              ]),
          Container(
            constraints: BoxConstraints(maxHeight: thumbSpan * 0.3),
          )
        ],
      ),
    );

    final numeralDragIndicatorWidget = AnimatedBuilder(
      animation: Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(
        parent: numeralDragIndicator,
        curve: Curves.easeInCubic,
      )),
      builder: (context, child) => Positioned(
        left: numeralDragStart.dx,
        top:
            numeralDragStart.dy - numeralDragDistanceTs * Thumbspan.of(context),
        child: CustomPaint(
          painter: DragIndicatorPainter(
            color: theme.colorScheme.primary,
            radius: Curves.easeIn.transform(numeralDragIndicator.value) *
                thumbSpan *
                0.15,
          ),
        ),
      ),
    );

    final timersWidget = Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // pinned timers
          Flexible(
            flex: 1,
            child: Container(
                constraints: BoxConstraints.expand(),
                child: TimerTray(
                  mobj: widget.timerList,
                  backgroundColor: theme.colorScheme.surfaceContainerHigh,
                  icon: Icon(Icons.push_pin), // You can customize this icon
                  useScrollView: true,
                )),
          ),
          // unpinned timers (will be another TimerSequence later)
          Container(
              constraints:
                  BoxConstraints(minHeight: double.infinity, minWidth: 100),
              child: TimerTray(
                  backgroundColor: theme.colorScheme.surfaceContainer,
                  mobj: Mobj.getAlreadyLoaded(
                      transientTimerListID, timerListType),
                  icon: Icon(Icons.delete),
                  useScrollView: false))
        ],
      ),
    );

    return Scaffold(
      body: Focus(
        autofocus: true, // Automatically request focus when built
        onKeyEvent: (_, event) {
          _handleKeyPress(event);
          return KeyEventResult.handled; // Prevent event from propagating
        },
        child: Stack(children: [
          Column(
            children: [
              timersWidget,
              Container(
                constraints: BoxConstraints(minWidth: double.infinity),
                // the lower part of the screen
                child: controls,
              )
            ],
          ),
          numeralDragIndicatorWidget
        ]),
      ),
    );
  }

  void toggleStopPlay() {
    final p = selectedOrLastTimerState();
    if (p != null) {
      toggleRunningOnMobj(p, reset: true);
    }
  }

  bool toggleRunning(MobjID timer, {bool reset = false}) {
    final mt = Mobj.getAlreadyLoaded(timer, TimerDataType());
    return toggleRunningOnMobj(mt, reset: reset);
  }

  bool toggleRunningOnMobj(Mobj<TimerData> timer, {bool reset = false}) {
    bool wasRunning = timer.peek()!.isRunning;
    timer.value = timer.peek()!.toggleRunning(reset: reset);
    return !wasRunning;
  }

  void pausePlaySelected([bool reset = false]) {
    if (selectedTimer != null) {
      if (toggleRunning(selectedTimer!, reset: reset)) {
        _selectTimer(null);
      }
      final last = timers().lastOrNull;
      if (last != null) {
        toggleRunning(last, reset: reset);
      }
    }
  }

  void addNewTimer({
    int? runningState,
    bool? selected,
    List<int>? digits,
  }) {
    final ntid = UuidV4().generate();

    bool selecting = selected ?? false;

    // we leak this. By not deleting it, it will stay in the db and registry as a root object
    Mobj<TimerData>.clobberCreate(
      ntid,
      type: const TimerDataType(),
      initial: () => TimerData(
        startTime: null,
        runningState: runningState ?? TimerData.paused,
        hue: nextRandomHue(),
        selected: selecting,
        digits: digits ?? const [],
        ranTime: Duration.zero,
        isGoingOff: false,
      ),
    );

    widget.timerList.value = timers().toList()..add(ntid);
    if (selecting) {
      _selectTimer(ntid);
    }
  }

  void _selectTimer(MobjID<TimerData>? timerID) {
    if (selectedTimer != null) {
      final oldMobj = Mobj.getAlreadyLoaded(selectedTimer!, TimerDataType());
      oldMobj.value = oldMobj.peek()!.withChanges(selected: false);
    }
    selectedTimer = timerID;
    if (timerID != null) {
      final newMobj = Mobj.getAlreadyLoaded(timerID, TimerDataType());
      newMobj.value = newMobj.peek()!.withChanges(selected: true);
    }
  }

  void _backspace() {
    if (selectedTimer != null) {
      final mobj = Mobj.getAlreadyLoaded(selectedTimer!, TimerDataType());
      List<int> digits = List.from(mobj.peek()!.digits);

      if (digits.isEmpty) {
        removeTimer(selectedTimer!);
      } else {
        digits.removeLast();
        mobj.value = mobj.peek()!.withChanges(digits: digits);
      }
    } else {
      if (timers().isNotEmpty) {
        removeTimer(timers().last);
      }
    }
  }

  void removeTimer(MobjID ki) {
    // Check if timer exists in the list
    if (!peekTimers().contains(ki)) {
      return;
    }

    widget.timerList.value = peekTimers().toList()
      ..removeWhere((timer) => timer == ki);

    if (selectedTimer == ki) {
      _selectTimer(null);
    }
  }

  Mobj<TimerData>? selectedOrLastTimerState() {
    if (selectedTimer != null) {
      return Mobj.getAlreadyLoaded(selectedTimer!, TimerDataType());
    } else {
      final lt = peekTimers().lastOrNull;
      if (lt != null) {
        return Mobj.getAlreadyLoaded(lt, TimerDataType());
      }
      return null;
    }
  }
}

class NumberButton extends StatefulWidget {
  final List<int> digits;
  final GlobalKey<TimersButtonState>? timerButtonKey;
  const NumberButton({super.key, required this.digits, this.timerButtonKey});
  @override
  State<NumberButton> createState() => _NumberButtonState();
}

class _NumberButtonState extends State<NumberButton>
    with TickerProviderStateMixin {
  late AnimationController _dragIndicator;
  Offset _startDrag = Offset.zero;
  bool hasTriggered = false;
  @override
  void initState() {
    super.initState();
    _dragIndicator =
        AnimationController(vsync: this, duration: Duration(milliseconds: 140));
  }

  @override
  void dispose() {
    _dragIndicator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TimersButton(
      key: widget.timerButtonKey,
      label: widget.digits.join(),
      onPanDown: (Offset p) {
        hasTriggered = false;
        _startDrag = p;
        final tss = context.findAncestorStateOfType<TimerScreenState>();
        tss?.numeralPressed(widget.digits);
        tss?.numeralDragStart = _startDrag;
        tss?.numeralDragIndicator.forward();
      },
      onPanUpdate: (Offset p) {
        if ((p - _startDrag).dy <=
                -numeralDragDistanceTs * Thumbspan.of(context) &&
            !hasTriggered) {
          final tss = context.findAncestorStateOfType<TimerScreenState>();
          tss?.pausePlaySelected();
          tss?.numeralDragIndicator.reverse();
          hasTriggered = true;
        }
      },
      onPanEnd: () {
        final tss = context.findAncestorStateOfType<TimerScreenState>();
        tss?.numeralDragIndicator.reverse();
      },
    );
  }
}

class TimersButton extends StatefulWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback? onPressed;
  final bool accented;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final Animation<double>? dialBloomAnimation;

  const TimersButton(
      {super.key,
      required this.label,
      this.onPressed,
      this.accented = false,
      this.onPanDown,
      this.onPanUpdate,
      this.onPanEnd,
      this.dialBloomAnimation});

  @override
  State<TimersButton> createState() => TimersButtonState();
}

class TimersButtonState extends State<TimersButton>
    with TickerProviderStateMixin {
  late AnimationController shortFlash;
  late AnimationController longFlash;
  @override
  initState() {
    super.initState();
    shortFlash =
        AnimationController(vsync: this, duration: Duration(milliseconds: 450))
          ..value = 1;
    longFlash =
        AnimationController(vsync: this, duration: Duration(milliseconds: 800))
          ..value = 1;
  }

  @override
  void dispose() {
    shortFlash.dispose();
    longFlash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final buttonSpan = 0.7 * Thumbspan.of(context);
    return GestureDetector(
      // we make sure to pass null if they're null because having a non-null value massively lowers the slopping radius
      onPanDown: (details) {
        if (widget.onPanDown != null) {
          widget.onPanDown?.call(details.globalPosition);
          shortFlash.forward(from: 0);
        }
      },
      onPanUpdate: widget.onPanUpdate != null
          ? (details) => widget.onPanUpdate?.call(details.globalPosition)
          : null,
      onPanCancel:
          widget.onPanEnd != null ? () => widget.onPanEnd?.call() : null,
      onPanEnd:
          widget.onPanEnd != null ? (details) => widget.onPanEnd?.call() : null,
      child: Container(
        // todo: this is wrong, we shouldn't be setting the size here, unfortunately there's a layout overflow behavior with rows that I don't understand
        constraints:
            BoxConstraints(maxWidth: buttonSpan, maxHeight: buttonSpan),
        child: InkWell(
            onTap: widget.onPressed,
            splashColor: widget.accented ? Colors.transparent : null,
            highlightColor: widget.accented ? Colors.transparent : null,
            hoverColor: widget.accented ? Colors.transparent : null,
            focusColor: widget.accented ? Colors.transparent : null,
            // overlayColor: WidgetStateColor.resolveWith((_) => Colors.white),
            child: AnimatedBuilder(
                animation: Listenable.merge([shortFlash, longFlash]),
                builder: (context, child) {
                  double flash = max(
                      (1 - Curves.easeIn.transform(shortFlash.value)),
                      (1 - Curves.easeInOutCubic.transform(longFlash.value)));
                  Color? textColor =
                      widget.accented ? theme.colorScheme.primary : null;
                  final backingColor = lerpColor(
                      widget.accented
                          ? theme.colorScheme.primary
                          : Colors.white.withAlpha(0),
                      Colors.white,
                      flash);
                  final backing = Container(
                      decoration: BoxDecoration(
                    color: backingColor,
                    border: Border.all(
                      width: standardLineWidth,
                      color: widget.accented
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                    ),
                    // borderRadius: BorderRadius.circular(9)
                  ));
                  final Widget labelWidget;
                  if (widget.label is String) {
                    labelWidget = Text(widget.label as String,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: textColor));
                  } else {
                    labelWidget = widget.label as Widget;
                  }
                  return Center(
                    child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [backing, labelWidget]),
                  );
                })),
      ),
    );
  }
}
