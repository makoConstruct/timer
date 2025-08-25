import 'dart:math';
import 'dart:async';

import 'package:animated_containers/animated_wrap.dart';
import 'package:animated_to/animated_to.dart';
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
import 'package:makos_timer/database.dart' as DB;
import 'package:makos_timer/raise_animation.dart';
import 'package:makos_timer/size_reporter.dart';
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

final ObjID timerListID = '159e8ae1-19f6-4fe1-bdb3-5198f5e35b1b';

Future<void> torchDatabase(TheDatabase db) async {
  print('WARNING: Clearing all data from the database!');
  await db.kVs.deleteAll();
}

void main() async {
  final db = TheDatabase();
  await torchDatabase(db);
  // the db will be accessed via this singleton from then on
  await MobjRegistry.initialize(db);
  MobjRegistry.insertIfNotPresent(timerListID,
      TypeRegistry.getTypeHelp(['list', 'string']), () => <ObjID>[]);
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
    final initialTimers = <Timer>[];
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
          child: Timerscreen(
            timers: initialTimers,
            selectLastTimer: true,
          )),
    );
  }
}

class TimerData {
  /// represents, if runningState is 0, the time it was paused at, otherwise, the time it started
  final DateTime? startTime;

  /// whether it's paused/playing/completed
  final int runningState;
  bool get isRunning => runningState == running;
  bool get isCompleted => runningState == completed;
  static const paused = 0;
  static const running = 1;
  static const completed = 2;

  /// the hue of the (pastel) color, in [0,1)
  final double hue;

  /// whether it's currently being edited (shouldn't that be persisted via "currently selected")
  final bool selected;

  /// the digit form of duration. Used when tapping out or backspacing numbers. Not always kept up to date with duration..
  final List<int> digits;

  /// the amount of time it ran in before being paused (ignored if not paused, or if completed)
  final double ranTime;

  /// if the alarm is currently screaming and needs to be acknowledged by the user
  final bool isGoingOff;

  /// in seconds, computed from digits
  double get duration => digitsToDuration(digits).inMilliseconds / 1000.0;

  TimerData({
    this.startTime,
    this.runningState = paused,
    required this.hue,
    required this.selected,
    this.digits = const [],
    this.ranTime = 0,
    this.isGoingOff = false,
  });

  TimerData withChanges({
    // fortunately we never need to set startTime to null :/ dart's optional parameter syntax doesn't support that
    DateTime? startTime,
    int? runningState,
    double? hue,
    bool? selected,
    List<int>? digits,
    double? ranTime,
    bool? isGoingOff,
  }) {
    return TimerData(
      startTime: startTime ?? this.startTime,
      runningState: runningState ?? this.runningState,
      hue: hue ?? this.hue,
      selected: selected ?? this.selected,
      digits: digits ?? this.digits,
      ranTime: ranTime ?? this.ranTime,
      isGoingOff: isGoingOff ?? this.isGoingOff,
    );
  }
}

/// Timer widget, contrast with Timer row from the database orm
class Timer extends StatefulWidget {
  final ObjID timerID;
  final bool animateIn;
  const Timer({
    required GlobalKey<TimerState> key,
    required this.timerID,
    this.animateIn = true,
  }) : super(key: key);

  @override
  State<Timer> createState() => TimerState();
}

class TimerState extends State<Timer>
    with SignalsMixin, TickerProviderStateMixin {
  // we actually do need to keep both forms of these around, as each form can represent information the other can't. Duration can be millisecond precise, while digits can have abnormal numbers in, say, the seconds segment, eg, more than 60 seconds.
  late Mobj<TimerData> s;
  late Ticker _ticker;
  // in seconds
  double currentTime = 0;
  late AnimationController _runningAnimation;
  final GlobalKey _clockKey = GlobalKey();
  final previousSize = ValueNotifier<Size?>(null);
  final transferrableKey = GlobalKey();

  set selected(bool v) {
    s.value = s.peek()!.withChanges(selected: v);
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

  /// in seconds
  double get duration {
    return s.peek()!.duration;
  }

  set digits(List<int> value) {
    s.value = s.peek()!.withChanges(digits: value);
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
    super.initState();
    // todo remove
    testTimeConversions();
    s = MobjRegistry.get<TimerData>(widget.timerID)!;
    _runningAnimation = AnimationController(
        duration: const Duration(milliseconds: 80), vsync: this);
    _ticker = createTicker((d) {
      setTime(
          durationToSeconds(DateTime.now().difference(s.peek()!.startTime!)));
    });
  }

  @override
  dispose() {
    _runningAnimation.dispose();
    _ticker.dispose();
    previousSize.dispose();
    s.dispose();
    super.dispose();
  }

  void setTime(double nd) {
    if (currentTime == nd) {
      return;
    }
    final d = s.peek()!;
    setState(() {
      currentTime = nd;
      if (d.isRunning && nd >= d.duration && !d.isCompleted) {
        triggerAlert();
      }
    });
  }

  void triggerAlert() {
    JukeBox.jarringSound(context);
    _runningAnimation.reverse();
    _ticker.stop();
    setTime(0);
    s.value = s.peek()!.withChanges(
          runningState: 2,
          // here to note that we don't have this feature (prolonged alarms) in
          isGoingOff: false,
        );

    //todo: check to see whether the timer is visible in the list view. If not, do a push notification alert. Otherwise just make it do an animation and play a brief sound. Don't require an interaction, the user knows.
  }

  /// returns true iff the timer was caused to start by this call
  bool toggleRunning([bool reset = false]) {
    final d = s.peek()!;
    final ret = !d.isRunning;
    final trs = ret ? TimerData.running : TimerData.paused;
    if (ret) {
      _runningAnimation.forward();
      _ticker.start();
      bool resetting = d.isCompleted || reset;
      if (resetting) {
        setState(() {
          setTime(0);
        });
      }
      s.value = s.peek()!.withChanges(
          runningState: trs,
          // restart only if it was completed, or if we're in reset mode
          startTime: resetting
              ? DateTime.now()
              : DateTime.now().subtract(secondsToDuration(currentTime)));
    } else {
      _runningAnimation.reverse();
      _ticker.stop();
      if (reset) {
        setTime(0);
      }
      s.value = s.peek()!.withChanges(runningState: trs);
    }
    return ret;
  }

  void reset() {
    setState(() {
      setTime(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mover = 0.1;
    final thumbSpan = Thumbspan.of(context);

    TimerData? d = s.value;
    if (d == null) {
      return SizedBox();
    }

    double pieCompletion = clampUnit(currentTime / d.duration);
    final durationDigits = d.digits;
    final timeDigits = durationToDigits(currentTime,
        padLevel: padLevelFor(durationDigits.length));

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
                      Transform.scale(
                          alignment: Alignment.bottomLeft,
                          scale: lerp(0.6, 1, v),
                          child: Text(boring.formatTime(timeDigits))),
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

    Widget result = AnimatedBuilder(
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
      child: GestureDetector(
        onTap: () {
          context
              .findAncestorStateOfType<TimerScreenState>()
              ?.takeActionOn(widget.key as GlobalKey<TimerState>);
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
      ),
    );

    result = SizeReporter(
        key: transferrableKey, previousSize: previousSize, child: result);

    // final pb = DraggableFeedbackPositionBox();
    // return LongPressDraggable(
    //     delay: const Duration(milliseconds: 290),
    //     feedback: result,
    //     // I think this requires a second globalkey to narrow in on transferrable or something :/ and a listener
    //     childWhenDragging: SizeFollower(
    //       sizeNotifier: previousSize,
    //     ),
    //     child: result);

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

class Timerscreen extends StatefulWidget {
  final List<Timer> timers;
  final bool selectLastTimer;

  const Timerscreen(
      {super.key, this.timers = const [], this.selectLastTimer = true});

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
  GlobalKey<TimerState>? selectedTimer;

  bool isCranking = false;
  bool isRightHanded = true;
  late List<Timer> timers;

  GlobalKey controlPadKey = GlobalKey();
  GlobalKey pinnedTimersKey = GlobalKey();
  Offset numeralDragStart = Offset.zero;
  late final AnimationController numeralDragIndicator;
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());
  // a lime green default as the first color
  double nextHue = 0.252;

  @override
  void initState() {
    super.initState();
    timers = List.from(widget.timers);
    if (timers.isNotEmpty && widget.selectLastTimer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _selectTimer(timers.first.key as GlobalKey<TimerState>);
      });
    }
    numeralDragIndicator =
        AnimationController(vsync: this, duration: Duration(milliseconds: 70));
  }

  @override
  void dispose() {
    super.dispose();
    numeralDragIndicator.dispose();
  }

  void takeActionOn(GlobalKey<TimerState> key) {
    final timer = key.currentState as TimerState;
    //todo: take whichever action is currently highlighted
    timer.toggleRunning();
  }

  double nextRandomHue() {
    final ret = nextHue;
    final increment = 0.06 + Random().nextDouble() * 0.19;
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
      getStateMaybeDeferring(selectedTimer!, (sc) {
        List<int> ct = List.from(sc.s.peek()!.digits);
        sc.setState(() {
          for (int n in number) {
            ct.add(n);
          }
          sc.digits = ct;
        });
      });
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
        children: [
          // pinned timers
          Flexible(
              flex: 1,
              child: Scrollable(
                  viewportBuilder: (context, position) => Container(
                        alignment: Alignment.bottomRight,
                        constraints: BoxConstraints.expand(),
                        clipBehavior: Clip.none,
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: AnimatedWrap.material3(
                          key: pinnedTimersKey,
                          textDirection: TextDirection.ltr,
                          clipBehavior: Clip.none,
                          verticalDirection: VerticalDirection.down,
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: AnimatedWrapCrossAlignment.end,
                          runAlignment: WrapAlignment.end,
                          // I don't like cloning this, but ultimately, if we had really large numbers of timers, large enough that this clone operation was a problem, we'd need a viewer rather than a simple AnimatedWrap.
                          children: timers.toList(),
                        ),
                      ))),
          // unpinned timers
          Container(
              constraints:
                  BoxConstraints(minHeight: double.infinity, minWidth: 100),
              color: theme.colorScheme.surfaceContainer)
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
          DragTarget<GlobalKey<TimerState>>(
              builder: (context, candidateData, rejectedData) {
            print("builder");
            return Column(
              children: [
                timersWidget,
                Container(
                  constraints: BoxConstraints(minWidth: double.infinity),
                  // the lower part of the screen
                  child: controls,
                )
              ],
            );
          }, onMove: (DragTargetDetails<GlobalKey<TimerState>> details) {
            final index = (pinnedTimersKey.currentState as AnimatedWrapState)
                .insertionIndexAt((pinnedTimersKey.currentContext!
                        .findRenderObject() as RenderBox)
                    .globalToLocal(details.offset));
            print(
                "details.offset: ${details.offset}, insertionIndex: ${index.insertionIndex}");
          }, onAcceptWithDetails: (details) {
            final insertion =
                (pinnedTimersKey.currentState as AnimatedWrapState)
                    .insertionIndexAt((pinnedTimersKey.currentContext!
                            .findRenderObject() as RenderBox)
                        .globalToLocal(details.offset));
            final tkey = details.data;
            final insertionIndex = insertion.insertionIndex;
            final currentIndex = timers.indexWhere((t) => t.key == tkey);
            // do the insertion only if the item being inserted is new or if it's not right next to its current position
            if (currentIndex == -1 ||
                (insertionIndex != currentIndex &&
                    insertionIndex != currentIndex + 1)) {
              setState(() {
                Timer t = tkey.currentWidget! as Timer;
                timers.insert(insertionIndex, t);
                if (currentIndex != -1) {
                  timers.removeAt(insertionIndex < currentIndex
                      ? currentIndex + 1
                      : currentIndex);
                }
              });
            }
          }),
          numeralDragIndicatorWidget
        ]),
      ),
    );
  }

  void toggleStopPlay() {
    selectedOrLastTimerState()?.toggleRunning(true);
  }

  void pausePlaySelected([bool reset = false]) {
    if (selectedTimer != null) {
      getStateMaybeDeferring(selectedTimer!, (ts) {
        if (ts.toggleRunning(reset)) {
          _selectTimer(null);
        }
      });
    } else {
      if (timers.isNotEmpty) {
        getStateMaybeDeferring(timers.last.key as GlobalKey<TimerState>, (ts) {
          ts.toggleRunning(reset);
        });
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
    Mobj<TimerData>.create(
      ntid,
      const TimerDataType(),
      initial: TimerData(
        startTime: null,
        runningState: runningState ?? TimerData.paused,
        hue: nextRandomHue(),
        selected: selecting,
        digits: digits ?? const [],
        ranTime: 0,
        isGoingOff: false,
      ),
    );

    final newTimer = Timer(
      key: GlobalKey<TimerState>(),
      timerID: ntid,
    );

    setState(() {
      timers.add(newTimer);
      if (selecting) {
        _selectTimer(newTimer.key as GlobalKey<TimerState>);
      }
    });
  }

  void _selectTimer(GlobalKey<TimerState>? key) {
    selectedTimer?.currentState?.selected = false;
    selectedTimer = key;
    key?.currentState?.selected = true;
  }

  void _backspace() {
    if (selectedTimer != null) {
      final sc = selectedTimer!.currentState!;

      List<int> digits = List.from(sc.s.peek()!.digits);

      if (digits.isEmpty) {
        removeTimer(selectedTimer!);
      } else {
        digits.removeLast();
        sc.digits = digits;
      }
    } else {
      if (timers.isNotEmpty) {
        removeTimer(timers.last.key as GlobalKey<TimerState>);
      }
    }
  }

  void removeTimer(GlobalKey<TimerState> key) {
    setState(() {
      timers.removeWhere((timer) => timer.key == key);
      if (selectedTimer == key) {
        _selectTimer(null);
      }
    });
  }

  TimerState? selectedOrLastTimerState() =>
      selectedTimer?.currentState ??
      (timers.lastOrNull?.key as GlobalKey<TimerState>?)?.currentState;
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
