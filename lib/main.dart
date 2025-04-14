import 'dart:math';
import 'dart:async';

import 'package:animated_list_plus/animated_list_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/boring.dart' as boring;
import 'package:makos_timer/raise_animation.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
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

void main() {
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
const double timerPaddingr = 3;

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

class TimersApp extends StatelessWidget {
  const TimersApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final initialTimers = <Timer>[];

    // print("screenSize ${MediaQuery.sizeOf(context)}");

    final jukeBox = JukeBox.create();

    return MaterialApp(
      title: 'timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 60, 92, 56)),
        useMaterial3: true,
      ),
      home: MultiProvider(
          providers: [
            Provider<Thumbspan>(
                create: (context) => Thumbspan(lpixPerThumbspan(context))),
            Provider<Future<JukeBox>>(create: (_) => jukeBox)
          ],
          child: Timerscreen(
            timers: initialTimers,
            selectLastTimer: true,
          )),
    );
  }
}

class Timer extends StatefulWidget {
  final bool selected;
  final bool animateIn;
  final List<int> digits;
  final bool running;
  const Timer({
    super.key,
    this.selected = false,
    this.animateIn = true,
    this.digits = const [],
  }) : running = false;

  @override
  State<Timer> createState() => TimerState();
}

class TimerState extends State<Timer>
    with SignalsMixin, TickerProviderStateMixin {
  // we actually do need to keep both forms of these around, as each form can represent information the other can't. Duration can be millisecond precise, while digits can have abnormal numbers in, say, the seconds segment, eg, more than 60 seconds.
  bool isDigitMode = true;
  // the digit form of duration. Used when tapping out or backspacing numbers. Not always kept up to date with duration..
  late List<int> _digits;
  bool isGoingOff = false;
  Duration _duration = Duration.zero;
  DateTime? _startTime;
  Key dismissableKey = GlobalKey();
  bool wasDismissed = false;
  late Ticker _ticker;
  Duration currentTime = Duration.zero;
  late bool _selected;
  bool isRunning = false;
  bool isCompleted = false;
  var timerLayerLink = LayerLink();
  set selected(bool v) {
    setState(() {
      _selected = v;
    });
  }

  set duration(Duration d) {
    setState(() {
      d - currentTime;
      isDigitMode = false;
      _duration = d;
      if (currentTime >= d) {
        currentTime = d;
        isCompleted = true;
      } else {
        isCompleted = false;
      }
    });
  }

  Duration get duration {
    if (isDigitMode) {
      _duration = digitsToDuration(_digits);
    }
    return _duration;
  }

  set digits(List<int> value) {
    setState(() {
      isDigitMode = true;
      _digits = value;
    });
  }

  List<int> get digits {
    if (!isDigitMode) {
      _digits = durationToDigits(duration);
    }
    return _digits.toList();
  }

  @override
  void initState() {
    super.initState();
    testTimeConversions();
    _selected = widget.selected;
    _digits = widget.digits;
    isRunning = widget.running;
    _ticker = createTicker((d) {
      setTime(DateTime.now().difference(_startTime!));
    });
  }

  @override
  dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void setDigitMode(bool v) {
    if (v != isDigitMode) {
      setState(() {
        isDigitMode = v;
        if (v) {
          _digits = durationToDigits(_duration);
        } else {
          _duration = digitsToDuration(_digits);
        }
      });
    }
  }

  void setTime(Duration n) {
    if (currentTime == n) {
      return;
    }
    Duration prev = currentTime;
    currentTime = n;
    setDigitMode(false);
    // only update the widgets if the seconds part changed, otherwise the change would be invisible
    if (n.inSeconds != prev.inSeconds) {
      setState(() {
        if (isRunning && n.inSeconds >= duration.inSeconds && !isCompleted) {
          isCompleted = true;
          //todo: check to see whether the timer is visible in the list view. If not, do a push notification alert. Otherwise just make it do an animation and play a brief sound. Don't require an interaction, the user knows.

          JukeBox.jarringSound(context);

          _ticker.stop();

          setState(() {
            isGoingOff = false;
            isRunning = false;
          });
        }
      });
    }
  }

  /// returns true iff the timer was caused to start by this call
  bool toggleRunning([bool reset = false]) {
    setState(() {
      isRunning = !isRunning;
    });
    final ret = isRunning;
    if (isRunning) {
      setDigitMode(false);
      if (isCompleted || reset) {
        _startTime = DateTime.now();
        isCompleted = false;
      } else {
        _startTime = DateTime.now().subtract(currentTime);
      }
      _ticker.start();
    } else {
      _ticker.stop();
      if (reset) {
        setTime(Duration.zero);
      }
    }
    return ret;
  }

  void reset() {
    setState(() {
      setTime(Duration.zero);
      if (!isRunning) {
        toggleRunning();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbSpan = Thumbspan.of(context);
    double pieCompletion = currentTime.inMilliseconds <= 0
        ? 0
        : clampUnit(currentTime.inMilliseconds.toDouble() /
            duration.inMilliseconds.toDouble());
    final dismissThreshold =
        (1.4 * thumbSpan) / MediaQuery.of(context).size.width;
    final durationDigits =
        isDigitMode ? digits : durationToDigits(duration, padLevel: 1);
    final timeDigits = durationToDigits(currentTime,
        padLevel: padLevelFor(durationDigits.length));
    final Widget durationWidget = Text(formatTime(durationDigits));
    final Widget timeDisplay = DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: Row(children: [
          Text(formatTime(timeDigits)),
          Text("/"),
          CompositedTransformTarget(
            link: timerLayerLink,
            child: durationWidget,
          )
        ]));

    return Dismissible(
      key: dismissableKey,
      dismissThresholds: {
        DismissDirection.endToStart: dismissThreshold,
        DismissDirection.startToEnd: dismissThreshold,
      },
      onDismissed: (_) {
        final ts = context.findAncestorStateOfType<TimerScreenState>();
        wasDismissed = true;
        ts!.removeTimer(widget.key as GlobalKey<TimerState>);
      },
      background: Container(
        color: const Color.fromARGB(255, 231, 148, 142),
        alignment: Alignment.centerLeft,
        // padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: const Color.fromARGB(255, 231, 148, 142),
        alignment: Alignment.centerRight,
        // padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Theme.of(context).colorScheme.onPrimary,
          ),
          child: InkWell(
            onTap: () {
              toggleRunning();
            },
            child: Padding(
              padding: const EdgeInsets.all(timerPaddingr),
              child: Row(
                children: [
                  Container(width: timerPaddingr),
                  Pie(
                    size: 29,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    color: theme.colorScheme.primary,
                    value: pieCompletion,
                  ),
                  Container(width: timerPaddingr * 2),
                  timeDisplay,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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

class Dial extends StatefulWidget {
  // relative to screen
  final Offset center;
  // relative to screen
  final Offset dragStart;
  final GlobalKey<TimerState> selectedTimer;
  final AnimationController fadeBloom;
  // milliseconds as a function of radians
  final double Function(double) timeFunction;
  final GlobalKey controlPadKey;
  final GlobalKey dialHost = GlobalKey();
  Dial(
      {super.key,
      required this.center,
      required this.dragStart,
      required this.fadeBloom,
      required this.timeFunction,
      required this.controlPadKey,
      required this.selectedTimer});
  @override
  State<Dial> createState() => DialState();
}

class DialState extends State<Dial> {
  late Offset currentDrag;
  double timeAtStart = 0; // milliseconds
  late double initialAngle;
  // the number of times the dial has been rotated 360 degrees, with sign.
  int rounds = 0;

  @override
  void initState() {
    super.initState();
    // Transform.rotate(
    //               angle: 0.9,
    //               child: AnimatedScale(
    //                 duration: const Duration(
    //                     milliseconds: falcrumAnimationDurationMs),
    //                 curve: Curves.easeOut,
    //                 scale: 1.0,
    //                 child: FittedBox(
    //                     fit: BoxFit.none,
    //                     alignment: Alignment.centerLeft,
    //                     child: Row(children: [
    //                       SizedBox(width: 20, height: 3),
    //                       Text("100")
    //                     ]).animate().scaleY(
    //                         duration: Duration(
    //                             milliseconds: falcrumAnimationDurationMs),
    //                         curve: Curves.easeOut)),
    //               ))
    initialAngle = angleFrom(widget.dragStart, widget.center);
    rounds = 0;
    currentDrag = widget.dragStart;
    timeAtStart = (widget.selectedTimer.currentState?.duration ?? Duration.zero)
            .inMilliseconds
            .toDouble() /
        1000;
  }

  //issue: It's not calling startDrag when it starts a new drag. Replacing the widget probably isn't the way.

  void updateDrag(Offset newDrag) {
    double olda = angleFrom(currentDrag, widget.center);
    double newa = angleFrom(newDrag, widget.center);
    // double d = shortestAngleDistance(olda, newa);
    // we could just set cumulativeAngle to the sum of all ds, but that could accumulate error. Instead we do something more complicated. Gesturally: rounds is the higher digit and currentRound is the lower digit. cumulativeAngle is tau*rounds + currentRound.

    int nextRounds = rounds;
    final double so = shortestAngleDistance(initialAngle, olda);
    final double sn = shortestAngleDistance(initialAngle, newa);
    //detect a crossing of the initialAngle
    // (we use an || instead of an && because if the angle is spinning so fast (at a rate of pi per frame) that we can't tell whether it crossed the initialAngle, the preferred behavior is for the crossing to occur rather than never occur)

    if (so.sign.isNegative != sn.sign.isNegative &&
        (so.abs() < pi / 2 || sn.abs() < pi / 2)) {
      nextRounds += (sn - so).sign.toInt();
    }
    double currentRound = (newa - initialAngle) % tau;

    final nextAngle = tau * nextRounds + currentRound;

    double nextTime = timeAtStart + widget.timeFunction(nextAngle);
    if (nextTime < 0) {
      // refuse to update any settings if it would make the time go negative
      nextTime = 0;
      initialAngle = newa;
    } else {
      rounds = nextRounds;
    }
    final ts = widget.selectedTimer.currentState;
    if (ts != null) {
      ts.setState(() {
        // rounds down to the nearest second
        ts.duration = Duration(milliseconds: nextTime.toInt() * 1000);
        if (ts.currentTime > ts.duration) {
          ts.setTime(ts.duration);
        }
      });
    }

    setState(() {
      currentDrag = newDrag;
    });
  }

  void endDrag() {
    setState(() {
      rounds = 0;
      final ts = widget.selectedTimer.currentState;
      if (ts != null && !ts.isRunning && ts.duration > Duration.zero) {
        ts.toggleRunning();
      }
      widget.fadeBloom.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    double angle = angleFrom(widget.center, currentDrag);
    // Get the screen width from the MediaQuery
    final double screenWidth = MediaQuery.of(context).size.width;
    double r = max(widget.center.dx, screenWidth - widget.center.dx) * 1.6;
    Offset positionRelControlPad = widget.center -
        (widget.controlPadKey.currentContext!.findRenderObject()! as RenderBox)
            .localToGlobal(Offset.zero);
    HSLuvColor midColor =
        HSLuvColor.fromColor(Theme.of(context).colorScheme.primaryContainer);
    double midl = midColor.lightness;
    Color topColor = midColor.withLightness(midl + 2).toColor();
    Color bottomColor = midColor.withLightness(midl - 5).toColor();
    return Positioned(
      left: positionRelControlPad.dx,
      top: positionRelControlPad.dy,
      child: FadingDial(
          listenable: widget.fadeBloom,
          angle: angle,
          radius: r,
          topColor: topColor,
          bottomColor: bottomColor,
          holeRadius: 0),
    );
  }

  @override
  void didUpdateWidget(Dial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.center != oldWidget.center || currentDrag != widget.dragStart) {
      setState(() {
        currentDrag = widget.dragStart;
      });
    }
  }
}

class TimerScreenState extends State<Timerscreen>
    with SignalsMixin, TickerProviderStateMixin {
  GlobalKey<TimerState>? selectedTimer;

  bool isCranking = false;
  bool isRightHanded = true;
  late List<Timer> timers;

  GlobalKey controlPadKey = GlobalKey();
  late AnimationController dialBloom;
  late GlobalKey dialKey;
  Dial? dial;
  late final GlobalKey secondCrankButtonKey;
  late final GlobalKey minuteCrankButtonKey;
  Offset numeralDragStart = Offset.zero;
  late final AnimationController numeralDragIndicator;
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());

  @override
  void initState() {
    super.initState();
    dialBloom =
        AnimationController(vsync: this, duration: Duration(milliseconds: 140));
    timers = List.from(widget.timers);
    if (timers.isNotEmpty && widget.selectLastTimer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _selectTimer(timers.first.key as GlobalKey<TimerState>);
      });
    }
    numeralDragIndicator =
        AnimationController(vsync: this, duration: Duration(milliseconds: 70));
    secondCrankButtonKey = GlobalKey();
    minuteCrankButtonKey = GlobalKey();
  }

  @override
  void dispose() {
    super.dispose();
    dialBloom.dispose();
    numeralDragIndicator.dispose();
  }

  void numeralPressed(List<int> number, {bool viaKeyboard = false}) {
    if (selectedTimer == null) {
      addNewTimer(Timer(
          key: GlobalKey<TimerState>(),
          selected: true,
          digits: stripZeroes(number)));
    } else {
      getStateMaybeDeferring(selectedTimer!, (sc) {
        List<int> ct = sc.digits;
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
        flashAnimation.value = 0;
        flashAnimation.forward();
      }
    }
  }

  void startDragFor(double Function(double) timeFunction, Offset position) {
    final GlobalKey<TimerState> operatingTimer = GlobalKey<TimerState>();
    addNewTimer(Timer(key: operatingTimer, selected: true));
    setState(() {
      isCranking = true;

      // we rectify the dial center to make sure it's always positioned exactly relative to touch down. A user can learn to be more accurate relative to touchdown than they can be relative to the screen
      Offset controlPadCenter = widgetCenter(controlPadKey);
      Offset crankButtonCenter = widgetCenter(secondCrankButtonKey);
      Offset dialCenter =
          position + Offset(controlPadCenter.dx - crankButtonCenter.dx, 0);

      // make sure it knows it's a new dial/runs initState. The old dial will just abruptly disappear if you unpress and press too fast which isn't ideal, solvable with will but probably warrants a RemovableHost pattern which I don't want to think about right now
      dialKey = GlobalKey();

      dial = Dial(
        key: dialKey,
        controlPadKey: controlPadKey,
        timeFunction: timeFunction,
        dragStart: position,
        fadeBloom: dialBloom,
        selectedTimer: operatingTimer,
        center: dialCenter,
      );

      dialBloom.forward();
    });
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
          addNewTimer(Timer(key: GlobalKey<TimerState>(), selected: true));
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
    var settingsButton = TimersButton(
        label: Icon(Icons.settings),
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

    TimersButton crankButton(bool accented, String name,
        double Function(double) timeFunction, GlobalKey key) {
      return TimersButton(
          key: key,
          label: name,
          accented: accented,
          onPanDown: (Offset position) {
            startDragFor(timeFunction, position);
          },
          onPanUpdate: (Offset position) {
            ((dial?.key as GlobalKey).currentState as DialState?)
                ?.updateDrag(position);
          },
          onPanEnd: () {
            setState(() {
              ((dial?.key as GlobalKey).currentState as DialState?)?.endDrag();
              isCranking = false;
              _selectTimer(null);
            });
          });
    }

    final crankMinutesButton =
        crankButton(false, "m+↻", angleToTimeMinutes, minuteCrankButtonKey);
    final crankSecondsButton =
        crankButton(false, "s+↻", angleToTimeSeconds, secondCrankButtonKey);

    final addButton = TimersButton(
        label: Icon(Icons.add_circle),
        onPanDown: (_) {
          addNewTimer(Timer(key: GlobalKey<TimerState>(), selected: true));
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
              Flexible(child: addButton),
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
              Flexible(child: settingsButton),
              Flexible(child: selectButton),
            ],
          ),
        ),
      ]);
    }

    final thumbSpan = Thumbspan.of(context);
    final buttonSpan = thumbSpan * 0.7;

    // the lower part of the screen
    var controls = Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              alignment: Alignment.bottomRight,
              children: [
                if (dial != null) dial!,
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

    Widget drawIfNotDismissed(Widget item, Animation<double> animation,
        {required bool elseAssumeDismissed}) {
      final tk = item.key as GlobalKey<TimerState>?;
      if (tk == null) {
        return item;
      } else {
        final tks = tk.currentState;
        final raise = RaiseAnimation(
          animation: animation,
          child: item,
        );
        if (tks != null) {
          if (tks.wasDismissed) {
            return Container();
          } else {
            return raise;
          }
        } else {
          if (elseAssumeDismissed) {
            return Container();
          } else {
            return raise;
          }
        }
      }
    }

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
              Expanded(
                child: Container(
                  color:
                      theme.colorScheme.onPrimary, // Slightly grey background
                  child: ImplicitlyAnimatedList(
                    insertDuration: Duration(milliseconds: 170),
                    removeDuration: Duration(milliseconds: 170),
                    items: timers,
                    reverse: true,
                    // this horriffic workaround is here because ImplicitlyAnimatedList doesn't remove items as soon as the list changes, because it uses an asynchronous MyersDiff call, so a removed item may still be in the list and may still be called in itemBuilder for a frame after being removed, and if that removed item contains a Dismissible, it will scream, so we build a Container instead in those cases.
                    // The following two sections of code differ only in how they behave when the item has no state.
                    itemBuilder: (context, animation, item, index) {
                      return drawIfNotDismissed(item, animation,
                          elseAssumeDismissed: false);
                    },
                    removeItemBuilder: (context, animation, item) {
                      return drawIfNotDismissed(item, animation,
                          elseAssumeDismissed: true);
                    },
                    areItemsTheSame: (oldItem, newItem) =>
                        oldItem.key == newItem.key,
                  ),
                ),
              ),
              Container(
                constraints: BoxConstraints(
                    maxHeight: double.infinity,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    minWidth: double.infinity),
                // the lower part of the screen
                child: controls,
              )
            ],
          ),
          AnimatedBuilder(
            animation: Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(
              parent: numeralDragIndicator,
              curve: Curves.easeInCubic,
            )),
            builder: (context, child) => Positioned(
              left: numeralDragStart.dx,
              top: numeralDragStart.dy -
                  numeralDragDistanceTs * Thumbspan.of(context),
              child: CustomPaint(
                painter: DragIndicatorPainter(
                  color: theme.colorScheme.primary,
                  radius: Curves.easeIn.transform(numeralDragIndicator.value) *
                      thumbSpan *
                      0.15,
                ),
              ),
            ),
          )
        ]),
      ),
    );
  }

  void toggleStopPlay() {
    selectedOrFirstTimerState()?.toggleRunning(true);
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
        getStateMaybeDeferring(timers[0].key as GlobalKey<TimerState>, (ts) {
          ts.toggleRunning(reset);
        });
      }
    }
  }

  void addNewTimer(Timer nt) {
    setState(() {
      timers.insert(0, nt);
      _selectTimer(nt.key as GlobalKey<TimerState>);
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

      List<int> digits = sc.digits;

      if (digits.isEmpty) {
        removeTimer(selectedTimer!);
      } else {
        digits.removeLast();
        sc.digits = digits;
      }
    } else {
      if (timers.isNotEmpty) {
        removeTimer(timers[0].key as GlobalKey<TimerState>);
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

  TimerState? selectedOrFirstTimerState() {
    if (selectedTimer != null) {
      return selectedTimer!.currentState;
    } else {
      return timers.isNotEmpty
          ? (timers[0].key as GlobalKey<TimerState>).currentState
          : null;
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
    Animation<double> dialBloom = widget.dialBloomAnimation ??
        context.findAncestorStateOfType<TimerScreenState>()!.dialBloom;
    return GestureDetector(
      // we make sure to pass null if they're null because having a non-null value massively lowers the slopping radius
      onPanDown: (details) {
        if (widget.onPanDown != null) {
          widget.onPanDown?.call(details.globalPosition);
          shortFlash.value = 0;
          shortFlash.forward();
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
                animation: Listenable.merge([dialBloom, shortFlash, longFlash]),
                builder: (context, child) {
                  double flash = max(
                      (1 - Curves.easeIn.transform(shortFlash.value)),
                      (1 - Curves.easeInOutCubic.transform(longFlash.value)));
                  Color? textColor = widget.accented
                      ? lerpColor(theme.colorScheme.primary,
                          theme.colorScheme.onPrimary, 1 - dialBloom.value)
                      : null;
                  final backingColor = lerpColor(
                      widget.accented
                          ? theme.colorScheme.primary
                              .withAlpha(((1 - dialBloom.value) * 255).toInt())
                          : Colors.white.withAlpha(0),
                      Colors.white,
                      flash);
                  final backing = Padding(
                      padding: EdgeInsets.all(4),
                      child: Container(
                          decoration: BoxDecoration(
                              color: backingColor,
                              border: Border.all(
                                width: standardLineWidth,
                                color: widget.accented
                                    ? theme.colorScheme.primary
                                    : Colors.transparent,
                              ),
                              borderRadius: BorderRadius.circular(9))));
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
                  return Opacity(
                    opacity: widget.accented ? 1 : 1 - dialBloom.value * 1,
                    child: Center(
                        child: Transform.scale(
                            scale:
                                widget.accented ? 1 - dialBloom.value * 0.3 : 1,
                            // 1,
                            child: Stack(
                                alignment: Alignment.center,
                                clipBehavior: Clip.none,
                                children: [backing, labelWidget]))),
                  );
                })),
      ),
    );
  }
}
