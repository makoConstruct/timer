import 'dart:collection';
import 'dart:math';

import 'package:animated_list_plus/animated_list_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/raise_animation.dart';
import 'package:signals/signals_flutter.dart';

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

/// represents the increments in gearing of the dial that is used by angleTime. The dial is a set of "milestones", points where, when the dial is rotated to that point, the time will be that milestone's time, and between milestones, the time is interpolated. `gradations` is not the milestone but the differences between them.
/// at p.$1 rotational units, the time increment is $2 seconds
// final List<(double, double)> gradations = [
//   (0.5, 60),
//   (0.5, 60 * 3),
//   (0.5, 60 * 6),
//   (0.5, 60 * 20),
//   (0.5, 60 * 30),
//   (0.5, 60 * 60),
//   (0.5, 60 * 60 * 10),
//   (0.5, 60 * 60 * 12),
//   (0.5, 60 * 60 * 48),
// ];

// List<(double, double)> calculateMilestonesPerTau(
//     List<(double, double)> gradations) {
//   List<(double, double)> ret = [(0, 0)];
//   double currentTau = 0.0;
//   double currentTime = 0.0;
//   for (var g in gradations) {
//     ret.add((currentTau, currentTime));
//     currentTau += g.$1;
//     currentTime += g.$2;
//   }
//   return ret;
// }

/// the angleTime is a set of milestones, points where, when the dial is rotated to that point, the time will be that milestone's time in seconds, and between milestones, the time is interpolated. Milestones will also be shown on the dial as space becomes available (which is going to be complicated to code).
final List<(double, double)> angleTime = [
  (0, 0),
  (pi, 60),
  (2 * pi, 5 * 60),
  (3 * pi, 10 * 60),
  (4 * pi, 60 * 60),
  (5 * pi, 2 * 60 * 60),
  (6 * pi, 3 * 60 * 60),
  (7 * pi, 4 * 60 * 60),
  (8 * pi, 5 * 60 * 60),
  (9 * pi, 6 * 60 * 60),
  (10 * pi, 12 * 60 * 60),
  (11 * pi, 24 * 60 * 60),
  (12 * pi, 48 * 60 * 60),
  (13 * pi, 7 * 24 * 60 * 60),
  (14 * pi, 365 * 24 * 60 * 60),
  (15 * pi, 2 * 365 * 24 * 60 * 60),
  (16 * pi, 5 * 365 * 24 * 60 * 60),
  (17 * pi, 10 * 365 * 24 * 60 * 60),
  (18 * pi, 20 * 365 * 24 * 60 * 60),
  (19 * pi, 40 * 365 * 24 * 60 * 60),
  (20 * pi, 100 * 365 * 24 * 60 * 60),
  (21 * pi, 200 * 365 * 24 * 60 * 60),
];
// final List<(double, double)> angleTime = calculateMilestonesPerTau(gradations);

/// basically just linearly interpolates the relevant angleTime segment
double angleToTime(double angle) {
  final sign = angle.sign;
  angle = angle.abs();
  var lower = angleTime[0];
  for (int i = 1; i < angleTime.length - 2; i++) {
    final upper = angleTime[i];
    if (angle < upper.$1) {
      return lerp(lower.$2, upper.$2, unlerpUnit(lower.$1, upper.$1, angle));
    }
    lower = upper;
  }
  final lp = angleTime.last;
  double lastt = lp.$2;
  return sign *
      (lastt + (lastt - angleTime[angleTime.length - 2].$1) * (angle - lp.$1));
}

class TimersApp extends StatelessWidget {
  const TimersApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final timers = [
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
      Timer(key: GlobalKey<TimerState>()),
    ];
    return MaterialApp(
      title: 'timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: Timerscreen(
        timers: timers,
        selectLastTimer: true,
      ),
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

class TimerState extends State<Timer> with SignalsMixin {
  // we actually do need to keep both forms of these around, as each form can represent information the other can't. Duration can be millisecond precise, while digits can have abnormal numbers in, say, the seconds segment, eg, more than 60 seconds.
  bool isDigitMode = false;
  // the digit form of duration. Used when tapping out or backspacing numbers. Not always kept up to date with duration..
  List<int> _digits = [];
  bool isGoingOff = false;
  Duration _duration = Duration.zero;
  Key dismissableKey = GlobalKey();

  Duration currentTime = Duration.zero;
  late final Signal<bool> selectedSignal;
  bool isRunning = false;

  set duration(Duration d) {
    setState(() {
      isDigitMode = false;
      _duration = d;
      if (currentTime > d) {
        currentTime = d;
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
    setDigitMode(false);
    setState(() {
      if (n > duration) {
        duration = n;
      }
      currentTime = n;
    });
  }

  bool toggleRunning() {
    final ret = !isRunning;
    setState(() {
      isRunning = !isRunning;
      //todo: make timer ongoing thing that runs each frame, even when app is in background (take inspiration from google timer)
    });
    if (isRunning) {
      setDigitMode(false);
    }
    return ret;
  }

  @override
  Widget build(BuildContext context) {
    final dismissThreshold = 25 / MediaQuery.of(context).size.width;
    return Dismissible(
      key: dismissableKey,
      dismissThresholds: {
        DismissDirection.endToStart: dismissThreshold,
        DismissDirection.startToEnd: dismissThreshold,
      },
      onDismissed: (_) {
        final ts = context.findAncestorStateOfType<TimerScreenState>();
        ts?.removeTimer(widget.key as GlobalKey<TimerState>);
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
      child: Container(
        width: double.infinity,
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Pie(
                        color: selectedSignal.value
                            ? Colors.black
                            : Color.fromARGB(255, 126, 126, 126),
                        // value: timeHasRun.inSeconds / duration.inSeconds,
                        value: 1.0,
                      ),
                    ),
                    Container(width: 10),
                    Text(
                        style: TextStyle(
                            color: selectedSignal.value
                                ? Colors.black
                                : Color.fromARGB(255, 72, 72, 72)),
                        'Timer ${formatTime(currentTime)}/${isDigitMode ? formatTime(digits) : formatTime(duration)} ${isRunning ? 'running' : 'stopped'}'),
                  ],
                ),
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
  final GlobalKey controlPadKey;
  final GlobalKey dialHost = GlobalKey();
  Dial(
      {super.key,
      required this.center,
      required this.dragStart,
      required this.fadeBloom,
      required this.controlPadKey,
      required this.selectedTimer});
  @override
  State<Dial> createState() => DialState();
}

class DialState extends State<Dial> {
  late Offset currentDrag;
  double timeAtStart = 0; // milliseconds
  late final double initialAngle;
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
    currentDrag = widget.dragStart;
    timeAtStart = (widget.selectedTimer.currentState?.duration ?? Duration.zero)
            .inMilliseconds
            .toDouble() /
        1000;
  }

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

    double nextTime = timeAtStart + angleToTime(nextAngle);
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
        ts.duration = Duration(milliseconds: (nextTime * 1000).toInt());
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
  GlobalKey dialKey = GlobalKey();
  Dial? dial;

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

  @override
  Widget build(BuildContext context) {
    final double squarePadSpan = 340;
    const int falcrumAnimationDurationMs = 140;

    ThemeData theme = Theme.of(context);

    //buttons
    var settingsButton = TimersButton(label: "⚙", onPressed: () {});

    var backspaceButton = TimersButton(
        label: "⌫",
        onPressed: () {
          _backspace();
        });

    var crankButton = TimersButton(
        label: "+↻",
        accented: true,
        onPressed: () {},
        onPanDown: (Offset position) {
          final GlobalKey<TimerState> operatingTimer = _addNewTimer();

          setState(() {
            isCranking = true;

            final cpro =
                controlPadKey.currentContext!.findRenderObject() as RenderBox;
            dial = Dial(
              key: dialKey,
              controlPadKey: controlPadKey,
              dragStart: position,
              fadeBloom: dialBloom,
              selectedTimer: operatingTimer,
              center:
                  cpro.localToGlobal(Offset.zero) + sizeToOffset(cpro.size / 2),
            );

            dialBloom.forward();
          });
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

    var addButton = TimersButton(label: "+", onPressed: _addNewTimer);

    var playButton = TimersButton(label: "▶", onPressed: _pausePlaySelected);

    var doubleZeroButton = TimersButton(
        label: "00",
        onPressed: () {
          _numeralPressed([0, 0]);
        });

    var zeroButton = TimersButton(
        label: "0",
        onPressed: () {
          _numeralPressed([0]);
        });

    var oneButton = TimersButton(
        label: "1",
        onPressed: () {
          _numeralPressed([1]);
        });

    var twoButton = TimersButton(
        label: "2",
        onPressed: () {
          _numeralPressed([2]);
        });

    var threeButton = TimersButton(
        label: "3",
        onPressed: () {
          _numeralPressed([3]);
        });

    var fourButton = TimersButton(
        label: "4",
        onPressed: () {
          _numeralPressed([4]);
        });

    var fiveButton = TimersButton(
        label: "5",
        onPressed: () {
          _numeralPressed([5]);
        });

    var sixButton = TimersButton(
        label: "6",
        onPressed: () {
          _numeralPressed([6]);
        });

    var sevenButton = TimersButton(
        label: "7",
        onPressed: () {
          _numeralPressed([7]);
        });

    var eightButton = TimersButton(
        label: "8",
        onPressed: () {
          _numeralPressed([8]);
        });

    var nineButton = TimersButton(
        label: "9",
        onPressed: () {
          _numeralPressed([9]);
        });

    List<Widget> controlPadWidgets(bool isRightHanded) {
      return isRightHanded
          ? [
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  settingsButton,
                  backspaceButton,
                  crankButton,
                  addButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  oneButton,
                  fourButton,
                  sevenButton,
                  playButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  twoButton,
                  fiveButton,
                  eightButton,
                  zeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
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
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  oneButton,
                  fourButton,
                  sevenButton,
                  doubleZeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  twoButton,
                  fiveButton,
                  eightButton,
                  zeroButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  threeButton,
                  sixButton,
                  nineButton,
                  playButton,
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  settingsButton,
                  backspaceButton,
                  crankButton,
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
        constraints: BoxConstraints(maxHeight: squarePadSpan),
        child: Row(
          mainAxisAlignment:
              isRightHanded ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: controlPadWidgets(isRightHanded),
        ),
      )
    ]);
    var controlPadder = Container(
      constraints: BoxConstraints.tight(Size(40, 40)),
      color: Colors.transparent,
    );

    var controls = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer),
      child: Row(
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
                return RaiseAnimation(
                  animation: animation,
                  child: item,
                );
              },
              areItemsTheSame: (oldItem, newItem) => oldItem.key == newItem.key,
            ),
          ),
        ),
        controls
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
  final String label;
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
    final textPart = Text(
      label,
      style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: accented ? theme.colorScheme.onPrimary : null),
    );
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
            constraints: BoxConstraints(maxWidth: 100, maxHeight: 100),
            child: InkWell(
                onTap: onPressed,
                splashColor: accented ? Colors.transparent : null,
                highlightColor: accented ? Colors.transparent : null,
                hoverColor: accented ? Colors.transparent : null,
                focusColor: accented ? Colors.transparent : null,
                child: AnimatedBuilder(
                    animation: dialBloom,
                    builder: (context, child) => Opacity(
                          opacity: accented ? 1 : 1 - dialBloom.value * 1,
                          child: Center(
                              child: Transform.scale(
                                  scale:
                                      accented ? 1 - dialBloom.value * 0.08 : 1,
                                  // 1,
                                  child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        if (accented)
                                          Padding(
                                              padding: EdgeInsets.all(4),
                                              child: Container(
                                                  decoration: BoxDecoration(
                                                      color: theme
                                                          .colorScheme.primary,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              16)))),
                                        textPart
                                      ]))),
                        ))),
          )),
    );
  }
}

class Pie extends StatelessWidget {
  final double value;
  final Color color;
  final double size;

  const Pie({
    super.key,
    required this.value,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: PiePainter(
          value: value.clamp(0.0, 1.0),
          color: color,
        ),
      ),
    );
  }
}
