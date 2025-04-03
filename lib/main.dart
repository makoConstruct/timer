import 'dart:math';
import 'dart:async' as da;
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';

import 'package:animated_list_plus/animated_list_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

class TimersApp extends StatelessWidget {
  const TimersApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final timers = [
      Timer(key: GlobalKey<TimerState>()),
    ];

    // print("screenSize ${MediaQuery.sizeOf(context)}");

    return MaterialApp(
      title: 'timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MultiProvider(
          providers: [
            FutureProvider<JukeBox?>(
                initialData: null, create: (_) => JukeBox.create())
          ],
          child: Timerscreen(
            timers: timers,
            selectLastTimer: true,
          )),
    );
  }
}

class Timer extends StatefulWidget {
  final bool selected;
  final bool animateIn;
  const Timer({super.key, this.selected = false, this.animateIn = false});

  @override
  State<Timer> createState() => TimerState();
}

class TimerState extends State<Timer>
    with SignalsMixin, TickerProviderStateMixin {
  // we actually do need to keep both forms of these around, as each form can represent information the other can't. Duration can be millisecond precise, while digits can have abnormal numbers in, say, the seconds segment, eg, more than 60 seconds.
  bool isDigitMode = false;
  // the digit form of duration. Used when tapping out or backspacing numbers. Not always kept up to date with duration..
  List<int> _digits = [];
  bool isGoingOff = false;
  Duration _duration = Duration.zero;
  DateTime? _startTime;
  Key dismissableKey = GlobalKey();
  late Ticker _ticker;
  Duration currentTime = Duration.zero;
  late final Signal<bool> selectedSignal;
  bool isRunning = false;
  bool isCompleted = true;
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
    testTimeConversions();
    super.initState();
    selectedSignal = createSignal(widget.selected);
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
          digits = durationToDigits(duration);
        } else {
          duration = digitsToDuration(digits);
        }
      });
    }
  }

  void setTime(Duration n) {
    if (currentTime == n) {
      return;
    }
    setDigitMode(false);
    Duration prev = currentTime;
    currentTime = n;
    // only update the widgets if the seconds part changed, otherwise the change would be invisible
    if (n.inSeconds != prev.inSeconds) {
      setState(() {
        if (isRunning && n.inSeconds >= duration.inSeconds && !isCompleted) {
          isCompleted = true;
          //todo: check to see whether the timer is visible in the list view. If not, do a push notification alert. Otherwise just make it do an animation and play a brief sound. Don't require an interaction, the user knows.

          // context
          //     .findAncestorStateOfType<TimerScreenState>()
          //     ?.jarringSoundPlayer
          //     .play(pianoSound);
          context.read<JukeBox?>()?.jarringPlayers.start();

          _ticker.stop();

          setState(() {
            isGoingOff = false;
            isRunning = false;
          });
        }
      });
    }
  }

  bool toggleRunning() {
    setState(() {
      isRunning = !isRunning;
    });
    final ret = isRunning;
    if (isRunning) {
      setDigitMode(false);
      if (isCompleted) {
        _startTime = DateTime.now();
        isCompleted = false;
      } else {
        _startTime = DateTime.now().subtract(currentTime);
      }
      _ticker.start();
    } else {
      _ticker.stop();
    }
    return ret;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    double pieCompletion = currentTime.inMilliseconds <= 0
        ? 0
        : clampUnit(currentTime.inMilliseconds.toDouble() /
            duration.inMilliseconds.toDouble());
    final dismissThreshold = 25 / MediaQuery.of(context).size.width;
    return Dismissible(
      key: dismissableKey,
      dismissThresholds: {
        DismissDirection.endToStart: dismissThreshold,
        DismissDirection.startToEnd: dismissThreshold,
      },
      onDismissed: (_) {
        final ts = context.findAncestorStateOfType<TimerScreenState>();
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
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    color: isRunning
                        ? theme.colorScheme.onSecondaryContainer
                        :
                        // otherwise soften the color
                        lerpColor(theme.colorScheme.onSecondaryContainer,
                            theme.colorScheme.secondaryContainer, 0.5),
                    // value: timeHasRun.inSeconds / duration.inSeconds,
                    value: pieCompletion,
                  ),
                  Container(width: timerPaddingr * 2),
                  Text(
                      style: TextStyle(color: theme.colorScheme.onSurface),
                      '${formatTime(currentTime)}/${isDigitMode ? formatTime(digits) : formatTime(duration)}'),
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

/// something that self-removing widgets can seek and remove themselves from. Example of such a widget: Animated ones that need to be removed when their timer runs down.
class RemovalHost extends StatefulWidget {
  /// if a new widget is identified with this one that has a different initialChildren, it will be ignored. RemovalHosts manage their children statefully.
  final List<Widget> initialChildren;
  final Widget Function(BuildContext context, List<Widget> children) builder;
  const RemovalHost(
      {super.key, required this.initialChildren, required this.builder});
  @override
  State<RemovalHost> createState() => RemovalHostState();

  static RemovalHostState? of(BuildContext context) {
    return context.findAncestorStateOfType<RemovalHostState>()!;
  }
}

class RemovalHostState extends State<RemovalHost> {
  List<Widget> children = [];
  @override
  void initState() {
    super.initState();
    children = List.from(widget.initialChildren);
  }

  add(Widget w) {
    setState(() {
      children.add(w);
    });
  }

  remove(GlobalKey key) {
    setState(() {
      children.removeWhere((w) => w.key == key);
    });
  }

  // I notice I kinda wanna animate removals, but no, ImplicitlyAnimatedList can't do that, it really has to be a list.
  @override
  void didUpdateWidget(RemovalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialChildren != oldWidget.initialChildren) {
      setState(() {
        children = List.from(widget.initialChildren);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, children);
  }
}

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
      child: RemovalHost(
        key: widget.dialHost,
        builder: (context, stackLayers) => Stack(children: stackLayers),
        initialChildren: [
          FadingDial(
              listenable: widget.fadeBloom,
              angle: angle,
              radius: r,
              topColor: topColor,
              bottomColor: bottomColor,
              holeRadius: 0),
        ],
      ),
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
    secondCrankButtonKey = GlobalKey();
    minuteCrankButtonKey = GlobalKey();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _numeralPressed(List<int> number) {
    if (selectedTimer == null) {
      _addNewTimer();
      // double deferral to ensure the new timer is mounted after the setState in _addNewTimer
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final sc = selectedTimer!.currentState!;
          List<int> ct = sc.digits;
          for (int n in number) {
            ct.add(n);
          }
          sc.digits = ct;
          if (sc.isRunning) {
            sc.toggleRunning();
          }
        });
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final sc = selectedTimer!.currentState!;
        List<int> ct = sc.digits;
        for (int n in number) {
          ct.add(n);
        }
        sc.digits = ct;
      });
    }
  }

  void startDragFor(double Function(double) timeFunction, Offset position) {
    final GlobalKey<TimerState> operatingTimer = _addNewTimer();

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

  @override
  Widget build(BuildContext context) {
    // todo: trying to determine the physical dimensions of the screen so that we know how many logical pixels to assign to ergonomic controls
    const int falcrumAnimationDurationMs = 140;
    final Size screenSize = MediaQuery.sizeOf(context);

    double lpixPerMM = boring.lpixPerMM(context);

    ThemeData theme = Theme.of(context);

    //buttons
    var settingsButton = TimersButton(
        label: Icon(Icons.settings),
        onPressed: () {
          context.read<JukeBox?>()?.jarringPlayers.start();
        });

    var backspaceButton = TimersButton(
        label: Icon(Icons.backspace),
        onPressed: () {
          _backspace();
        });

    TimersButton crankButton(bool accented, String name,
        double Function(double) timeFunction, GlobalKey key) {
      return TimersButton(
          key: key,
          label: name,
          accented: accented,
          onPressed: () {},
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
            });
          });
    }

    final crankMinutesButton =
        crankButton(false, "m+↻", angleToTimeMinutes, minuteCrankButtonKey);
    final crankSecondsButton =
        crankButton(true, "s+↻", angleToTimeSeconds, secondCrankButtonKey);

    final addButton =
        TimersButton(label: Icon(Icons.add_circle), onPressed: _addNewTimer);

    final playButton = TimersButton(
        label: Icon(Icons.play_circle_fill_rounded),
        onPressed: _pausePlaySelected);

    final doubleZeroButton = TimersButton(
        label: "00",
        onPressed: () {
          _numeralPressed([0, 0]);
        });

    final zeroButton = TimersButton(
        label: "0",
        onPressed: () {
          _numeralPressed([0]);
        });

    final oneButton = TimersButton(
        label: "1",
        onPressed: () {
          _numeralPressed([1]);
        });

    final twoButton = TimersButton(
        label: "2",
        onPressed: () {
          _numeralPressed([2]);
        });

    final threeButton = TimersButton(
        label: "3",
        onPressed: () {
          _numeralPressed([3]);
        });

    final fourButton = TimersButton(
        label: "4",
        onPressed: () {
          _numeralPressed([4]);
        });

    final fiveButton = TimersButton(
        label: "5",
        onPressed: () {
          _numeralPressed([5]);
        });

    final sixButton = TimersButton(
        label: "6",
        onPressed: () {
          _numeralPressed([6]);
        });

    final sevenButton = TimersButton(
        label: "7",
        onPressed: () {
          _numeralPressed([7]);
        });

    final eightButton = TimersButton(
        label: "8",
        onPressed: () {
          _numeralPressed([8]);
        });

    final nineButton = TimersButton(
        label: "9",
        onPressed: () {
          _numeralPressed([9]);
        });

    List<Widget> controlPadWidgets(bool isRightHanded) {
      return isRightHanded
          ? [
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  backspaceButton,
                  crankMinutesButton,
                  crankSecondsButton,
                  addButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  oneButton,
                  fourButton,
                  sevenButton,
                  playButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  twoButton,
                  fiveButton,
                  eightButton,
                  zeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  threeButton,
                  sixButton,
                  nineButton,
                  doubleZeroButton,
                ],
              ),
            ]
          : [
              // you can't just flip the arrays since the number pad has to be the same despite the rest being flipped
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  oneButton,
                  fourButton,
                  sevenButton,
                  doubleZeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  twoButton,
                  fiveButton,
                  eightButton,
                  zeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  threeButton,
                  sixButton,
                  nineButton,
                  playButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  backspaceButton,
                  crankMinutesButton,
                  crankSecondsButton,
                  addButton,
                ],
              ),
            ];
    }

    var controlPad =
        Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      if (dial != null) dial!,
      Container(
        key: controlPadKey,
        constraints: BoxConstraints(
            maxHeight: lpixPerMM * 4 * standardButtonSizeMM,
            maxWidth: lpixPerMM * 4 * standardButtonSizeMM),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment:
              isRightHanded ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: controlPadWidgets(isRightHanded),
        ),
      )
    ]);
    var controlPadder = Container(
      constraints: BoxConstraints.tight(Size(lpixPerMM * 10, lpixPerMM * 10)),
      color: Colors.transparent,
    );

    var controls = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer),
      child: Row(
          // mainAxisSize: MainAxisSize.min,
          mainAxisAlignment:
              isRightHanded ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: reverseIfNot(isRightHanded, [controlPad, controlPadder])),
    );

    return Scaffold(
        body: Column(
      children: [
        Expanded(
          child: Container(
            color: theme.colorScheme.onPrimary, // Slightly grey background
            child: ImplicitlyAnimatedList(
              insertDuration: Duration(milliseconds: 170),
              removeDuration: Duration(milliseconds: 170),
              items: timers,
              reverse: true,
              itemBuilder: (context, animation, item, index) {
                return RaiseAnimation(
                  animation: animation,
                  child: item,
                );
              },
              removeItemBuilder: (context, animation, item) {
                // the timers are dismissables, which animate their own removal, so at this point they're already invisible, so we'll return an empty. If we didn't do this, and instead built the dismissible form item as usual, the dismissable would scream.
                return Container();
                // RaiseAnimation(
                //   animation: animation,
                //   child: item,
                // );
              },
              areItemsTheSame: (oldItem, newItem) => oldItem.key == newItem.key,
            ),
          ),
        ),
        Container(
          constraints: BoxConstraints(
              maxHeight: double.infinity,
              minHeight: 0,
              maxWidth: double.infinity,
              minWidth: double.infinity),
          child: controls,
        )
      ],
    ));
  }

  void _pausePlaySelected() {
    if (selectedTimer != null) {
      if (selectedTimer!.currentState!.toggleRunning()) {
        selectedTimer!.currentState!.selectedSignal.value = false;
        selectedTimer = null;
      }
    } else {
      if (timers.isNotEmpty) {
        (timers[0].key as GlobalKey<TimerState>).currentState!.toggleRunning();
      }
    }
  }

  GlobalKey<TimerState> _addNewTimer() {
    final nk = GlobalKey<TimerState>();
    final nt = Timer(key: nk, selected: true, animateIn: true);
    setState(() {
      timers.insert(0, nt);
      _selectTimer(nt.key as GlobalKey<TimerState>);
    });
    return nk;
  }

  void _selectTimer(GlobalKey<TimerState>? key) {
    selectedTimer?.currentState?.selectedSignal.value = false;
    selectedTimer = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      key?.currentState?.selectedSignal.value = true;
    });
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
}

class TimersButton extends StatelessWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback onPressed;
  final bool accented;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final Animation<double>? dialBloomAnimation;

  const TimersButton(
      {super.key,
      required this.label,
      required this.onPressed,
      this.accented = false,
      this.onPanDown,
      this.onPanUpdate,
      this.onPanEnd,
      this.dialBloomAnimation});

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    Animation<double> dialBloom = dialBloomAnimation ??
        context.findAncestorStateOfType<TimerScreenState>()!.dialBloom;
    return Flexible(
      child: GestureDetector(
          // we make sure to pass null if they're null because having a non-null value massively lowers the slopping radius
          onPanDown: onPanDown != null
              ? (details) => onPanDown?.call(details.globalPosition)
              : null,
          onPanUpdate: onPanUpdate != null
              ? (details) => onPanUpdate?.call(details.globalPosition)
              : null,
          onPanCancel: onPanEnd != null ? () => onPanEnd?.call() : null,
          onPanEnd: onPanEnd != null ? (details) => onPanEnd?.call() : null,
          child: Container(
            // todo: this is wrong, we shouldn't be setting the size here, unfortunately there's a layout overflow behavior with rows that I don't understand
            constraints: BoxConstraints(
                maxWidth: standardButtonSizeMM * lpixPerMM(context),
                maxHeight: standardButtonSizeMM * lpixPerMM(context)),
            child: InkWell(
                onTap: onPressed,
                splashColor: accented ? Colors.transparent : null,
                highlightColor: accented ? Colors.transparent : null,
                hoverColor: accented ? Colors.transparent : null,
                focusColor: accented ? Colors.transparent : null,
                // overlayColor: WidgetStateColor.resolveWith((_) => Colors.white),
                child: AnimatedBuilder(
                    animation: dialBloom,
                    builder: (context, child) {
                      Color? textColor = accented
                          ? lerpColor(theme.colorScheme.primary,
                              theme.colorScheme.onPrimary, 1 - dialBloom.value)
                          : null;
                      Widget backing() => Padding(
                          padding: EdgeInsets.all(4),
                          child: Container(
                              decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withAlpha(
                                      ((1 - dialBloom.value) * 255).toInt()),
                                  border: Border.all(
                                      width: standardLineWidth,
                                      color: theme.colorScheme.primary),
                                  borderRadius: BorderRadius.circular(9))));
                      final Widget labelWidget;
                      if (label is String) {
                        labelWidget = Text(label as String,
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: textColor));
                      } else {
                        assert(label is Widget);
                        labelWidget = label as Widget;
                      }
                      return Opacity(
                        opacity: accented ? 1 : 1 - dialBloom.value * 1,
                        child: Center(
                            child: Transform.scale(
                                scale:
                                    accented ? 1 - dialBloom.value * 0.08 : 1,
                                // 1,
                                child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      if (accented) backing(),
                                      labelWidget
                                    ]))),
                      );
                    })),
          )),
    );
  }
}
