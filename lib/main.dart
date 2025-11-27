import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:async' as async;

import 'package:animated_to/animated_to.dart';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_refresh_rate_control/flutter_refresh_rate_control.dart';
import 'package:improved_wrap/improved_wrap.dart';
// imported as because there's a name collision with Column, lmao
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hsluv/extensions.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:makos_timer/platform_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:makos_timer/background_service_stuff.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/boring.dart' as boring;
import 'package:makos_timer/database.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:springster/springster.dart';
import 'package:uuid/v4.dart';

Future<void> deleteDatabase() async {
  final directory = await getApplicationSupportDirectory();
  final file = File(p.join(directory.path, '$databaseName.sqlite'));
  await file.delete();
  print("CRITICAL: deleted database file as commanded");
}

Future<void> torchDatabase(TheDatabase db) async {
  print('CRITICAL ERROR: Clearing all data from the database!');
  await db.kVs.deleteAll();
}

// think about this later after spawning a foreground task
// Future<DriftIsolate> createIsolateManually() async {
//   final receiveIsolate = ReceivePort('receive drift isolate handle');
//   await Isolate.spawn<SendPort>((message) async {
//     final server = DriftIsolate.inCurrent(() {
//       // Again, this needs to return the LazyDatabase or the connection to use.
//     });

//     // Now, inform the original isolate about the created server:
//     message.send(server);
//   }, receiveIsolate.sendPort);

//   final server = await receiveIsolate.first as DriftIsolate;
//   receiveIsolate.close();
//   return server;
// }

final sharedDriftIsolateName = "sharedDrift";

const databaseName = 'mako_timer_db';

Future<void> initializeDatabase() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = TheDatabase();
  // the db will be accessed via this singleton from then on
  // initialize version one of the db
  await MobjRegistry.initialize(db);
  final fversion = Mobj.getOrCreate(dbVersionID,
      type: const IntType(), initial: () => 0, debugLabel: "version");
  await Future.wait(<Future>[
    // we know that the data required for the app is minimal enough that we should wait until it's loaded before showing anything... idk not sure I believe this
    Mobj.getOrCreate(timerListID,
        type: ListType(const StringType()), initial: () => <MobjID>[]),
    Mobj.getOrCreate(transientTimerListID,
        type: ListType(const StringType()), initial: () => <MobjID>[]),
    Mobj.getOrCreate(nextHueID, type: const DoubleType(), initial: () => 0.252),
    Mobj.getOrCreate(isRightHandedID,
        type: const BoolType(),
        initial: () => true,
        debugLabel: "is right handed"),
    Mobj.getOrCreate(padVerticallyAscendingID,
        type: const BoolType(),
        initial: () => false,
        debugLabel: "pad vertically ascending"),
    Mobj.getOrCreate(selectedAudioID,
        type: const AudioInfoType(),
        initial: () => AudioInfo.defaultNotification,
        debugLabel: "selected audio"),
    fversion,
  ]);
}

Future<void> enableHighRefreshRate() async {
  final refreshRateControl = FlutterRefreshRateControl();
  // Request high refresh rate
  await refreshRateControl.requestHighRefreshRate();
  // How to stop high refresh rate mode:
  // bool success = await _refreshRateControl.stopHighRefreshRate();
}

void main() async {
  // await deleteDatabase();
  WidgetsFlutterBinding.ensureInitialized();
  await enableHighRefreshRate();
  await initializeDatabase();
  FlutterForegroundTask.addTaskDataCallback(onDataReceived);
  // my impression so far is that apple forbid you from running stuff in the background on iOS unless you're an application for which it would create bad PR for them to kill you, so you can't really make the best timer apps there. On iOS, we're going to have to disable repeat timers.
  // android will support repeat timers via the foreground service
  await graspForegroundService();
  runApp(const TimersApp());
}

void onDataReceived(Object data) {
  print("data received: $data");
}

const double standardLineWidth = 6;
const double standardButtonSizeMM = 13;
const double timerPaddingr = 6;

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

void enlivenTimer(Mobj<TimerData> mobj, JukeBox jukeBox) {
  async.Timer? completionTimer;
  Function()? ed;
  void reinitializeCompletionTimer() {
    completionTimer?.cancel();
    final d = mobj.value!;
    completionTimer = async.Timer(
        Duration(
            milliseconds: (d.duration - DateTime.now().difference(d.startTime))
                .inMilliseconds
                .ceil()), () {
      completionTimer = null;
      jukeBox.playJarringSound();
      mobj.value = mobj.value!.withChanges(
        runningState: TimerData.completed,
        // isGoingOff: true,
      );
    });
  }

  TimerData? prev = mobj.value;
  ed = effect(() {
    final TimerData? d = mobj.value;
    if (d == null) {
      ed?.call();
      ed = null;
      return;
    }
    if (d.isRunning) {
      if (prev?.duration != d.duration || (!(prev?.isRunning ?? false))) {
        reinitializeCompletionTimer();
      }
    } else if ((prev?.isRunning ?? false) && !d.isRunning) {
      completionTimer?.cancel();
      completionTimer = null;
    }
    prev = d;
  });
}

class _TimersAppState extends State<TimersApp> with WidgetsBindingObserver {
  late Future<JukeBox> jukeBox;
  _TimersAppState() {
    WidgetsFlutterBinding.ensureInitialized();
  }
  @override
  void initState() {
    super.initState();
    jukeBox = JukeBox.create();
    WidgetsBinding.instance.addObserver(this);

    // start listening to all currently existing timers (I'd like if this were listening to the lists, but we tried implementing that with background task and it was complicated and didn't quite come together, again, we don't need to, there's only one other place new timers are added through)
    jukeBox.then((jukeBox) {
      void enlivenAllTimersInList(Mobj<List<MobjID>> listMobj) {
        for (final tid in listMobj.peek() ?? []) {
          Mobj.fetch(tid, type: const TimerDataType())
              .then((mobj) => enlivenTimer(mobj, jukeBox));
        }
      }

      final timerListMobj = Mobj<List<MobjID>>.getAlreadyLoaded(
          timerListID, ListType(const StringType()));
      final transientTimerListMobj =
          Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
      enlivenAllTimersInList(timerListMobj);
      enlivenAllTimersInList(transientTimerListMobj);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        graspForegroundService();
        print("mako regrasping foreground service");
        break;
      case AppLifecycleState.paused:
        FlutterForegroundTask.sendDataToTask({'op': 'goodbye'});
        print("mako goodbye");
        break;
      default:
        break;
    }
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    ThemeData makeTheme(Brightness brightness) {
      return ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.white,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
          brightness: brightness,
        ),
        useMaterial3: true,
      );
    }

    return MaterialApp(
      title: 'timer',
      theme: makeTheme(Brightness.light),
      darkTheme: makeTheme(Brightness.dark),
      home: MultiProvider(
        providers: [
          Provider<Thumbspan>(
              create: (context) => Thumbspan(lpixPerThumbspan(context))),
          Provider<Future<JukeBox>>(create: (_) => jukeBox),
        ],
        child: TimerScreen(
          selectLastTimer: true,
        ),
      ),
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
  late final AnimationController _runningAnimation;
  Offset _slideBounceDirection = Offset(0, -1);
  late final AnimationController _slideActivateBounceAnimation;
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
    _slideBounceDirection = Offset(0, -1);
    _slideActivateBounceAnimation = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
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
    final pp = p;
    setState(() {
      currentTime = nd;
      // we don't set the timer off/change its state, enlivenTimer bindings do that
    });
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
    // sometimes the background thread completes the timer, the currentTime wont be updated, so in that case it should be ignored.
    double pieCompletion = d.isCompleted
        ? 0
        : d.runningState == TimerData.paused
            ? (d.ranTime.inMilliseconds.toDouble() / 1000) / dd
            : dd == 0
                ? 0
                : clampUnit(currentTime / dd);
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
                            child: Text(
                                boring.formatTime(
                                    withDigitsReplacedWith(timeDigits, 0)),
                                overflow: TextOverflow.clip)),
                        Transform.scale(
                            alignment: Alignment.bottomLeft,
                            scale: lerp(0.6, 1, v),
                            child: Text(boring.formatTime(timeDigits),
                                overflow: TextOverflow.clip))
                      ]),
                      Transform.scale(
                          alignment: Alignment.topLeft,
                          scale: lerp(1, 0.6, v),
                          child: Text(boring.formatTime(durationDigits),
                              overflow: TextOverflow.clip)),
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
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(timerPaddingr),
        child: ClipRect(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              clockDial(_clockKey, expandingHindCircle),
              SizedBox(width: timerPaddingr),
              Flexible(
                child: timeText,
              ),
            ],
          ),
        ),
      ),
    );

    result = AnimatedBuilder(
      animation: _runningAnimation,
      builder: (context, child) => Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
              shape: BoxShape.rectangle,
              // the running animation is mostly conveyed by the expanding circle, so only turn on as a contingency in case the circle doesn't fill it
              color: _runningAnimation.value == 1
                  ? theme.colorScheme.surfaceContainerLowest
                  : theme.colorScheme.surfaceContainerLowest.withAlpha(0)),
          child: child),
      child: result,
    );

    // do a bounce animation to respond to slide to start interactions
    double bounceDistance =
        10 * defaultPulserFunction(_slideActivateBounceAnimation.value);
    result = AnimatedBuilder(
        animation: _slideActivateBounceAnimation,
        builder: (context, child) => Transform.translate(
            offset: _slideBounceDirection * bounceDistance, child: child),
        child: result);

    result = AnimatedTo.spring(
        globalKey: animatedToKey,
        // tighter than default. ios sets this to .55
        description: const Spring.withDamping(durationSeconds: 0.2),
        child: result);

    result = SizeReporter(
        key: transferrableKey, previousSize: previousSize, child: result);

    return DraggableWidget<GlobalKey<TimerState>>(
        data: widget.key as GlobalKey<TimerState>, child: result);

    // return result;
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
        color: widget.backgroundColor,
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

class TimerScreen extends StatefulWidget {
  final bool selectLastTimer;
  const TimerScreen({super.key, this.selectLastTimer = true});

  @override
  State<TimerScreen> createState() => TimerScreenState();
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

final List<double> radialActivatorPositions = [
  -pi / 2,
  -pi,
];
final List<Function(TimerScreenState)> radialActivatorFunctions = [
  // (TimerScreenState tss) {
  //   tss.numeralPressed([0]);
  //   tss.pausePlaySelected();
  //   HapticFeedback.lightImpact();
  // },
  (TimerScreenState tss) {
    tss.pausePlaySelected();
    HapticFeedback.lightImpact();
  },
  (TimerScreenState tss) {
    tss.numeralPressed([0, 0]);
    tss.pausePlaySelected();
    HapticFeedback.lightImpact();
  },
];

class NumeralDragActionRing extends StatefulWidget {
  final Offset position;
  final Signal<int?> dragEvents;
  const NumeralDragActionRing(
      {super.key, required this.position, required this.dragEvents});

  @override
  State<NumeralDragActionRing> createState() => NumeralDragActionRingState();
}

class NumeralDragActionRingState extends State<NumeralDragActionRing>
    with TickerProviderStateMixin, SignalsMixin {
  double actionSizepAtSelection = 0;
  int numberSelected = -1;
  late final UpDownAnimationController upDownAnimation;
  late final AnimationController optionActivationAnimation;
  Function()? dragEventsSubscription;

  @override
  void initState() {
    super.initState();
    upDownAnimation = UpDownAnimationController(
      vsync: this,
      riseDuration: Duration(milliseconds: 300),
      fallDuration: Duration(milliseconds: 140),
    );
    upDownAnimation.forward();
    optionActivationAnimation = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 160),
    );
    optionActivationAnimation.addStatusListener((status) {
      if (!mounted) {
        return;
      }
      if (status == AnimationStatus.completed) {
        context
            .findAncestorStateOfType<EphemeralAnimationHostState>()
            ?.remove(widget);
      }
    });
    upDownAnimation.addStatusListener((status) {
      // wait for option activation if it's going
      if (!optionActivationAnimation.isAnimating &&
          status == AnimationStatus.dismissed) {
        if (!mounted) {
          return;
        }
        context
            .findAncestorStateOfType<EphemeralAnimationHostState>()
            ?.remove(widget);
      }
    });
    dragEventsSubscription = widget.dragEvents.subscribe((v) {
      if (v == null) {
        upDownAnimation.reverse();
        dragEventsSubscription?.call();
      } else if (v != -1) {
        setState(() {
          numberSelected = v;
          actionSizepAtSelection = currentActionSize();
          optionActivationAnimation.forward();
        });
      } else {
        upDownAnimation.forward();
      }
    });
  }

  @override
  void dispose() {
    optionActivationAnimation.dispose();
    upDownAnimation.dispose();
    dragEventsSubscription?.call();
    super.dispose();
  }

  double currentActionSize() {
    // disables fade down if action selected
    return Curves.easeIn.transform(unlerpUnit(
        0.4,
        0.65,
        upDownAnimation.value.$1 *
            (1 - (numberSelected != -1 ? 0 : upDownAnimation.value.$2))));
  }

  Widget buildGivenAnimationParameters(
      double risep, double fallp, double swipep) {
    final theme = Theme.of(context);
    final thumbSpan = Thumbspan.of(context);
    final isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, const BoolType()).value!;

    final radialRadiusMax = thumbSpan * (0.5 + 0.17);
    // disable fade down if a number is selected
    final double fallpIfNotSelected = numberSelected != -1 ? 0 : fallp;
    final radius = radialRadiusMax *
        Curves.easeOut
            .transform(unlerpUnit(0, 0.6, risep * (1 - fallpIfNotSelected)));
    // Calculate visible height for directional wipe-out (1.0 = fully visible, 0.0 = fully clipped)
    final Widget radialActivationRing = Positioned(
      left: 0,
      top: 0,
      child: FractionalTranslation(
        translation: Offset(-0.5, -0.5),
        child: Container(
          constraints: BoxConstraints.tight(Size(radius * 2, radius * 2)),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );

    final actionRadiusMax = thumbSpan * 0.6;
    Widget dragChoiceWidget(Widget child) {
      return Container(
        constraints:
            BoxConstraints.tight(Size(actionRadiusMax, actionRadiusMax)),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
        padding: EdgeInsets.all(8),
        child: Opacity(
          opacity: unlerpUnit(0.6, 1, risep),
          child: IconTheme(
            data: IconThemeData(
              color: theme.colorScheme.onPrimary,
            ),
            child: DefaultTextStyle(
              style: controlPadTextStyle
                  .merge(TextStyle(color: theme.colorScheme.onPrimary)),
              child: FittedBox(fit: BoxFit.scaleDown, child: child),
            ),
          ),
        ),
      );
    }

    List<Widget> radialActivatorWidgets = [
      dragChoiceWidget(Icon(Icons.play_arrow_rounded)),
      dragChoiceWidget(
        Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 0,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [Icon(Icons.play_arrow_rounded), Text('+00')]),
      ),
    ];

    Offset positionFor(int actionIndex, {double? overrideRisep}) {
      final angle = conditionallyApplyIf<double>(!isRightHanded,
          flipAngleHorizontally, radialActivatorPositions[actionIndex]);
      return Offset.fromDirection(
          angle,
          lerp(
              radius - actionRadiusMax,
              radius,
              Curves.easeOut.transform(unlerpUnit(0.6, 1,
                  (overrideRisep ?? risep) * (1 - fallpIfNotSelected)))));
    }

    final List<Widget> numeralDragRadialActivators =
        List.generate(radialActivatorFunctions.length, (i) {
      Offset o = positionFor(i);
      return Positioned(
        left: o.dx,
        top: o.dy,
        child: FractionalTranslation(
            translation: Offset(-0.5, -0.5),
            child: Transform.scale(
                scale: currentActionSize(), child: radialActivatorWidgets[i])),
      );
    });

    double totalSpan = 2 * radialRadiusMax + 2 * actionRadiusMax;

    final double? selectedAngle = numberSelected == -1
        ? null
        : conditionallyApplyIf<double>(!isRightHanded, flipAngleHorizontally,
            radialActivatorPositions[numberSelected]);

    return IgnorePointer(
        child: ClipPath(
            clipper: CircularRevealClipper(
              fraction: 1 - Curves.easeOut.transform(swipep),
              centerOffset: numberSelected != -1
                  ? positionFor(numberSelected, overrideRisep: 1)
                  : Offset.zero,
              maxRadius: totalSpan * 0.7,
              minRadius: 0,
            ),
            child: Container(
                width: 0,
                height: 0,
                child: Stack(clipBehavior: Clip.none, children: [
                  radialActivationRing,
                  ...numeralDragRadialActivators
                ]))));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
        left: widget.position.dx,
        top: widget.position.dy,
        child: AnimatedBuilder(
          animation: upDownAnimation,
          builder: (context, child) {
            return AnimatedBuilder(
              animation: optionActivationAnimation,
              builder: (context, child) {
                return buildGivenAnimationParameters(upDownAnimation.value.$1,
                    upDownAnimation.value.$2, optionActivationAnimation.value);
              },
            );
          },
        ));
  }
}

class TimerScreenState extends State<TimerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  MobjID<TimerData>? selectedTimer;
  late final Mobj<bool> isRightHanded =
      Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => timerListMobj.value!;
  List<MobjID<TimerData>> peekTimers() => timerListMobj.peek()!;

  GlobalKey controlPadKey = GlobalKey();
  GlobalKey timerTrayKey = GlobalKey();
  GlobalKey<EphemeralAnimationHostState> ephemeralAnimationLayer = GlobalKey();
  final Mobj<List<MobjID<TimerData>>> timerListMobj =
      Mobj.getAlreadyLoaded(timerListID, timerListType);
  final Mobj<List<MobjID<TimerData>>> transientTimerListMobj =
      Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
  final Mobj<double> nextHueMobj =
      Mobj.getAlreadyLoaded(nextHueID, const DoubleType());
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());

  void takeActionOn(MobjID<TimerData> timerID) {
    //todo: take whichever action is currently highlighted
    toggleRunning(timerID, reset: false);
  }

  double nextRandomHue() {
    final ret = nextHueMobj.value!;
    final increment = 0.1 + Random().nextDouble() * 0.15;
    nextHueMobj.value = (ret + increment) % 1;
    return ret;
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
    ThemeData theme = Theme.of(context);
    watchSignal(context, isRightHanded)!;
    bool padVerticallyAscending = watchSignal(context,
        Mobj.getAlreadyLoaded(padVerticallyAscendingID, const BoolType()))!;

    //buttons
    var configButton = TimersButton(
        label: Hero(
          tag: 'settings_icon',
          child: AnimatedScale(
              scale: 1.0,
              duration: Duration(milliseconds: 280),
              child: Icon(
                Icons.settings_rounded,
                color: theme.colorScheme.onSurface,
                size: 30,
              )),
        ),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const SettingsScreen(),
            ),
          );
        });

    //buttons
    var selectButton = TimersButton(
        // label: Icon(Icons.select_all),
        // label: Icon(Icons.border_outer_rounded),
        label: Icon(Icons.center_focus_strong),
        onPanDown: (_) {
          numeralPressed([1]);
          numeralPressed([2]);
          numeralPressed([3]);
          numeralPressed([4]);
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
          pausePlaySelected(reset: true);
        });

    final doubleZeroButton = NumberButton(digits: [0, 0]);
    final zeroButton =
        NumberButton(digits: [0], timerButtonKey: numeralKeys[0]);

    List<Widget> controlPadWidgets(bool isRightHanded) {
      /// the number pad isn't flipped for lefthanded mode
      Widget pad(int column, int row) {
        column = isRightHanded ? column : 2 - column;
        row = padVerticallyAscending ? 2 - row : row;
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
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLow),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: isRightHanded.value!
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
                    mainAxisAlignment: isRightHanded.value!
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: controlPadWidgets(isRightHanded.value!),
                  ),
                )
              ]),
          Container(
            constraints: BoxConstraints(maxHeight: thumbSpan * 0.3),
          )
        ],
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
                  key: timerTrayKey,
                  mobj: timerListMobj,
                  backgroundColor: theme.colorScheme.surfaceContainerLow,
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
        child: EphemeralAnimationHost(
            key: ephemeralAnimationLayer,
            builder: (children, context) => Stack(children: children),
            children: [
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

  void pausePlaySelected({bool reset = false}) {
    if (selectedTimer != null) {
      if (toggleRunning(selectedTimer!, reset: reset)) {
        _selectTimer(null);
      }
    } else {
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
    final nt = Mobj<TimerData>.clobberCreate(
      ntid,
      type: const TimerDataType(),
      initial: TimerData(
        startTime: null,
        runningState: runningState ?? TimerData.paused,
        hue: nextRandomHue(),
        selected: selecting,
        digits: digits ?? const [],
        ranTime: Duration.zero,
        isGoingOff: false,
      ),
    );
    Provider.of<Future<JukeBox>>(context, listen: false).then((jukeBox) {
      enlivenTimer(nt, jukeBox);
    });

    timerListMobj.value = timers().toList()..add(ntid);
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
        if (digits.isEmpty) {
          removeTimer(selectedTimer!);
        } else {
          mobj.value = mobj.peek()!.withChanges(digits: digits);
        }
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

    timerListMobj.value = peekTimers().toList()
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
    with TickerProviderStateMixin, SignalsMixin {
  /// -1 means mousedown, number means item has been selected, null means dismissed
  late Signal<int?> dragEvents = createSignal(-1, debugLabel: 'dragEvents');
  // UpDownAnimationController? get numeralDragIndicator =>
  //     numeralDragActionRing?.currentState?.widget.upDownAnimation;
  // AnimationController? get numeralDragIndicatorSelect =>
  //     numeralDragActionRing?.currentState?.widget.optionActivationAnimation;
  // GlobalKey<NumeralDragActionRingState>? numeralDragActionRing;
  Offset _startDrag = Offset.zero;
  bool hasTriggered = false;
  @override
  void initState() {
    super.initState();
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
        dragEvents.value = -1;
        final numeralDragActionRing = NumeralDragActionRing(
          key: UniqueKey(),
          position: p,
          dragEvents: dragEvents,
        );
        context
            .findAncestorStateOfType<EphemeralAnimationHostState>()
            ?.addWithoutAutomaticRemoval(numeralDragActionRing);
      },
      onPanUpdate: (Offset p) {
        Offset dp = p - _startDrag;
        if (dp.distance > Thumbspan.of(context) * 0.18 && !hasTriggered) {
          hasTriggered = true;
          final tss = context.findAncestorStateOfType<TimerScreenState>();
          if (tss == null) {
            return;
          }
          final angle = offsetAngle(dp);
          bool isRightHanded = tss.isRightHanded.value!;
          int dragResult = radialDragResult(
              isRightHanded
                  ? radialActivatorPositions
                  : radialActivatorPositions
                      .map(flipAngleHorizontally)
                      .toList(),
              angle,
              hitSpan: pi / 2);
          if (dragResult == -1) {
            dragEvents.value = null;
          } else {
            // activate
            radialActivatorFunctions[dragResult](tss);
            dragEvents.value = dragResult;
            dragEvents.value = null;
            // bounce animation
            final lti = tss.timerListMobj.value!.lastOrNull;
            if (lti != null) {
              final tts = tss.timerTrayKey.currentState as _TimerTrayState?;
              if (tts != null) {
                final ts =
                    (tts.timerWidgets.value[lti]?.key as GlobalKey<TimerState>?)
                        ?.currentState;
                ts?._slideActivateBounceAnimation.forward(from: 0);
                ts?._slideBounceDirection = Offset.fromDirection(angle, 1);
              }
            }
          }
        }
      },
      onPanEnd: () {
        dragEvents.value = null;
      },
    );
  }
}

final controlPadTextStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.bold,
);

class TimersButton extends StatefulWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback? onPressed;
  final bool accented;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final bool solidColor;
  final Animation<double>? dialBloomAnimation;

  const TimersButton(
      {super.key,
      required this.label,
      this.onPressed,
      this.solidColor = false,
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
          // shortFlash.forward(from: 0);
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
                          : widget.solidColor
                              ? theme.colorScheme.surfaceContainerLowest
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
                        style: controlPadTextStyle
                            .merge(TextStyle(color: textColor)));
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

class _NumpadTypeIndicator extends StatelessWidget {
  final bool isAscending;

  const _NumpadTypeIndicator({required this.isAscending});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cellSpan = 10.0;

    return SizedBox(
      width: cellSpan * 3,
      height: cellSpan * 3,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(9, (index) {
          final widg = Text((index + 1).toString(),
              style: TextStyle(
                  fontSize: index == 0 ? 11.0 : 9.0,
                  color: theme.colorScheme.primary,
                  fontWeight: index == 0 ? FontWeight.w900 : FontWeight.w400,
                  fontFamily: 'monospace'));
          // : Icon(Icons.circle, size: 3.0, color: theme.colorScheme.primary);
          final x = index % 3;
          int y = index ~/ 3;
          int py = isAscending ? 2 - y : y;
          return AnimatedPositioned(
            key: ValueKey((x, y)),
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: cellSpan / 2 + x * cellSpan,
            top: cellSpan / 2 + py * cellSpan,
            child: FractionalTranslation(
                translation: Offset(-0.5, -0.5), child: widg),
          );
        }),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ScrollController _scrollController;
  static const double _initialScrollOffset = 100.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: _initialScrollOffset,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final listItemPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0);
    final crap = List.generate(
        10,
        (index) => ListTile(
            title: Text('Item $index'), contentPadding: listItemPadding));

    Widget trailing(Widget child) =>
        SizedBox(width: 32.0, child: Center(child: child));

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Collapsible app bar with title
          SliverAppBar(
            pinned: true,
            expandedHeight: 500.0,
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale:
                  1.0, // Disable title scaling to prevent Hero discontinuity
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Hero(
                    tag: 'settings_icon',
                    child: AnimatedScale(
                        scale: 1.0,
                        duration: Duration(milliseconds: 280),
                        child: Icon(
                          Icons.settings_rounded,
                          color: theme.colorScheme.onSurface,
                          size: 30,
                        )),
                  ),
                  SizedBox(width: 5),
                  Text('Settings',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: theme.colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          // Extra padding at top to allow scrolling content to bottom
          // SliverPadding(
          //   padding: EdgeInsets.only(top: _topPadding),
          // ),
          // Settings items
          SliverList(
            delegate: SliverChildListDelegate([
              // Right-handed mode setting
              Watch((context) {
                final isRightHandedMobj =
                    Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());
                final isRightHanded = isRightHandedMobj.value ?? true;
                return ListTile(
                  title: Text('${isRightHanded ? 'Right' : 'Left'}-handed mode',
                      style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                    'optimize for ${isRightHanded ? 'right' : 'left'}-handed use',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  trailing: trailing(TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: isRightHanded ? -1.0 : 1.0,
                      end: isRightHanded ? -1.0 : 1.0,
                    ),
                    duration: Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    builder: (context, scaleX, child) {
                      return Transform.scale(
                        scaleX: scaleX,
                        child: child,
                      );
                    },
                    child: Transform.rotate(
                      angle: 45 * pi / 180, // 45 degrees clockwise
                      child: Icon(
                        Icons.back_hand_rounded,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  )),
                  onTap: () {
                    isRightHandedMobj.value = !isRightHanded;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Watch((context) {
                final padVerticallyAscendingMobj = Mobj.getAlreadyLoaded(
                    padVerticallyAscendingID, const BoolType());
                final padVerticallyAscending =
                    padVerticallyAscendingMobj.value ?? false;
                return ListTile(
                  title: Text('numpad type', style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                    padVerticallyAscending
                        ? 'calculator/keyboard style'
                        : 'phone style',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  trailing: trailing(_NumpadTypeIndicator(
                    isAscending: padVerticallyAscending,
                  )),
                  onTap: () {
                    padVerticallyAscendingMobj.value = !padVerticallyAscending;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Divider(height: 1, indent: 16.0, endIndent: 16.0),
              ListTile(
                title: Text('About this app', style: theme.textTheme.bodyLarge),
                trailing: trailing(
                    Icon(Icons.info_outline, color: theme.colorScheme.primary)),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const AboutScreen(),
                    ),
                  );
                },
                contentPadding: listItemPadding,
              ),
              ListTile(
                title:
                    Text('Thank the author', style: theme.textTheme.bodyLarge),
                trailing: trailing(Icon(
                  Icons.favorite_rounded,
                  color: theme.colorScheme.primary,
                )),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ThankAuthorScreen(),
                    ),
                  );
                },
                contentPadding: listItemPadding,
              ),
              ...crap,
            ]),
          ),
        ],
      ),
    );
  }
}

class ThankAuthorScreen extends StatelessWidget {
  const ThankAuthorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 120.0,
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Text('Thank the author',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  )),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: theme.colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverPadding(
            padding: EdgeInsets.all(24.0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Text(
                  'The audience for this app is large. Even a small payment in total would enable the author to go on to create much more ambitious projects.',
                  style: theme.textTheme.bodyLarge,
                ),
                SizedBox(height: 24),
                // Add more content here as needed
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 120.0,
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Text("About Mako's Timer",
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  )),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: theme.colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverPadding(
            padding: EdgeInsets.all(24.0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                SizedBox(height: 24),
                Text(
                  "This was made over the span of many months of work and through much experimentation.",
                  style: theme.textTheme.bodyMedium,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> hasBackgroundPermission() {
  if (Platform.isAndroid) {
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } else if (Platform.isIOS) {
    // iOS does not allow persistent background execution for timers.
    return Future.value(false);
  } else {
    // Other platforms (web, desktop) do not support background execution for this app.
    return Future.value(false);
  }
}
