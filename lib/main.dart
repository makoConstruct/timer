// this file tries to only concern itself with the core logic of the app. Anything whose functionality would be obvious just from its name/context but can't be fully modularized will be in boring.dart. Main and Boring aren't separable, so why separate them? I guess you could say main is like a "best of" of the code, for anyone who enjoys reading code.

import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:async' as async;

import 'package:animated_containers/retargetable_easers.dart'
    hide defaultPulserFunction;
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
import 'package:makos_timer/crank_game.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
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

const double timerOutline = 7;
const double timerGap = 11;
// might make this user-configurable
final Signal<double> timerWidgetRadius = Signal(19);

/// Was supposed to be a custom Hero flight shuttle builder with 60ms delay, but I it looks like it does nothing, I can't see how the movement part of the animation would be affected by this, it would only affect an animation over the hero widget
/// should have been a builder for createRectTween instead
Widget delayedHeroFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final delayedAnimation = CurvedAnimation(
    parent: animation,
    curve: const Interval(0.3, 1.0, curve: Curves.fastOutSlowIn),
  );

  // Get the child from the destination hero
  final Widget toHeroChild = (flightDirection == HeroFlightDirection.push)
      ? (toHeroContext.widget as Hero).child
      : (fromHeroContext.widget as Hero).child;

  return AnimatedBuilder(
    animation: delayedAnimation,
    builder: (context, child) {
      return toHeroChild;
    },
  );
}

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
        initial: () => PlatformAudio.assetSounds[0],
        debugLabel: "selected audio"),
    Mobj.getOrCreate(timeFirstUsedApp,
        type: const StringType(),
        initial: () => '',
        debugLabel: "first used app"),
    Mobj.getOrCreate(hasCreatedTimerID,
        type: const BoolType(),
        initial: () => false,
        debugLabel: "has created timer"),
    Mobj.getOrCreate(exitedSetupID,
        type: const BoolType(), initial: () => false, debugLabel: "left setup"),
    Mobj.getOrCreate(completedSetupID,
        type: const BoolType(),
        initial: () => false,
        debugLabel: "completed setup"),
    Mobj.getOrCreate(buttonSpanID,
        type: const DoubleType(),
        initial: () => 64.0,
        debugLabel: "button span"),
    Mobj.getOrCreate(buttonScaleDialOnID,
        type: const BoolType(),
        initial: () => false,
        debugLabel: "button scale dial on"),
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

/// this is in charge of running timer sounds in response to changes to the timer list
/// eventually it will be responsible for doing repeat timer logic
/// ideally the background thread would also use it
class TimerHolm {
  late JukeBox jukeBox;
  final Mobj<List<MobjID<TimerData>>> list;
  Map<MobjID<TimerData>, TimerTrack> tracking = {};
  late Signal<bool> enabled;

  /// when disabled, it behaves as if there are no timers in the list
  late final Computed<List<MobjID<TimerData>>> currentList;
  // late EffectCleanup reaction;
  late EffectCleanup reaction;
  TimerHolm({required this.list, required this.jukeBox}) {
    enabled = signal(true);
    currentList = computed(() => enabled.value ? list.value ?? [] : []);
    reaction = effect(() {
      Map<MobjID<TimerData>, TimerTrack> newTracking = {};
      for (final tid in currentList.value) {
        if (!tracking.containsKey(tid)) {
          bool unsubscribedPreFuture = false;
          final tt = TimerTrack()
            ..subscription = () {
              unsubscribedPreFuture = true;
            };
          Mobj.fetch(tid, type: const TimerDataType()).then((mobj) {
            if (unsubscribedPreFuture) {
              // mobj.reduceRef
              tt.subscription = null;
              return;
            }
            tt.mobj = mobj;
            tt.subscription = enlivenTimer(tt, mobj, jukeBox);
          });
          newTracking[tid] = tt;
        } else {
          newTracking[tid] = tracking[tid]!;
        }
      }
      for (final tt in tracking.entries) {
        if (!newTracking.containsKey(tt.key)) {
          tt.value.subscription?.call();
          tt.value.subscription = null;
          tt.value.completionTimer?.cancel();
          tt.value.completionTimer = null;
          tt.value.mobj = null;
        }
      }
      tracking = newTracking;
    });
  }

  /// how each timer is subscribed to and responded to
  void Function() enlivenTimer(
      TimerTrack tt, Mobj<TimerData> mobj, JukeBox jukeBox) {
    void reinitializeCompletionTimer() {
      tt.completionTimer?.cancel();
      final d = mobj.value!;
      tt.completionTimer = async.Timer(
          Duration(
              milliseconds:
                  (d.duration - DateTime.now().difference(d.startTime))
                      .inMilliseconds
                      .ceil()), () {
        tt.completionTimer = null;
        jukeBox.playAudio(
            Mobj.getAlreadyLoaded(selectedAudioID, const AudioInfoType())
                .value!);
        mobj.value = mobj.value!.withChanges(
          runningState: TimerData.completed,
          // isGoingOff: true,
        );
      });
    }

    TimerData? prev = mobj.value;
    // once null always null
    if (prev != null) {
      return effect(() {
        final TimerData? d = mobj.value;
        if (d == null) {
          // mobj.reduceRef();
          // this is never actually called, the list change triggers this listener to be unhooked
          tt.completionTimer?.cancel();
          tt.completionTimer = null;
        } else {
          bool prevRunning = prev?.isRunning ?? false;
          if (prevRunning != d.isRunning) {
            if (prevRunning) {
              tt.completionTimer?.cancel();
              tt.completionTimer = null;
            } else {
              reinitializeCompletionTimer();
            }
          }
        }
        prev = d;
      });
    } else {
      return () {};
    }
  }
}

class TimerTrack {
  Function()? subscription;
  async.Timer? completionTimer;
  Mobj<TimerData>? mobj;
}

// Global to cache screen corner radius
ScreenRadius? _cachedCornerRadius;
ScreenRadius defaultCornerRadius = ScreenRadius.value(0.0);
Future<ScreenRadius> _loadCornerRadius() async {
  if (_cachedCornerRadius != null) return _cachedCornerRadius!;
  try {
    _cachedCornerRadius = await ScreenCornerRadius.get() ?? defaultCornerRadius;
  } on UnimplementedError catch (_) {
    _cachedCornerRadius = defaultCornerRadius;
  } on MissingPluginException catch (_) {
    _cachedCornerRadius = defaultCornerRadius;
  }
  return _cachedCornerRadius!;
}

ScreenRadius getCachedCornerRadius() =>
    _cachedCornerRadius ?? defaultCornerRadius;

class _TimersAppState extends State<TimersApp> with WidgetsBindingObserver {
  late JukeBox jukeBox;
  late TimerHolm timerHolm;
  _TimersAppState() {
    WidgetsFlutterBinding.ensureInitialized();
  }
  @override
  void initState() {
    super.initState();
    jukeBox = JukeBox.create();
    _loadCornerRadius();

    // Enable edge-to-edge mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    WidgetsBinding.instance.addObserver(this);

    // start listening to all currently existing timers (I'd like if this were listening to the lists, but we tried implementing that with background task and it was complicated and didn't quite come together, again, we don't need to, there's only one other place new timers are added through)

    final timerListMobj = Mobj<List<MobjID>>.getAlreadyLoaded(
        timerListID, ListType(const StringType()));
    timerHolm = TimerHolm(list: timerListMobj, jukeBox: jukeBox);
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
        timerHolm.enabled.value = true;
        print("mako regrasping foreground service");
        break;
      case AppLifecycleState.paused:
        FlutterForegroundTask.sendDataToTask({'op': 'goodbye'});
        timerHolm.enabled.value = false;
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
          // brightness: (() {
          //   print("CRITICAL WARNING: overriding theme for debugging purposes");
          //   return Brightness.light;
          // })(),
          brightness: brightness,
        ),
        useMaterial3: true,
      );
    }

    return MultiProvider(
      providers: [
        Provider<Thumbspan>(
            create: (context) => Thumbspan(lpixPerThumbspan(context))),
        Provider<JukeBox>(create: (_) => jukeBox),
      ],
      child: MaterialApp(
        title: 'timer',
        theme: makeTheme(Brightness.light),
        darkTheme: makeTheme(Brightness.dark),
        onGenerateRoute: (settings) {
          if (settings.name == '/') {
            return CircularRevealRoute(
              builder: (context) => TimerScreen(),
            );
          }
          if (settings.name == '/onboard') {
            return CircularRevealRoute(
              builder: (context) => OnboardScreen(),
            );
          }
          return null;
        },
        onGenerateInitialRoutes: (initialRouteName) {
          final completedSetup =
              Mobj.getAlreadyLoaded(completedSetupID, const BoolType()).value ??
                  false;
          return <Route<dynamic>>[
            CircularRevealRoute(builder: (context) => TimerScreen()),
            if (!completedSetup)
              CircularRevealRoute(builder: (context) => OnboardScreen()),
          ];
        },
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
  late final AnimationController _appearanceAnimation;
  late final AnimationController _runningAnimation;
  Offset _slideBounceDirection = Offset(0, -1);
  late final AnimationController _slideActivateBounceAnimation;
  late final AnimationController _unpinnedIndicatorShowing;
  late final AnimationController _unpinnedIndicatorFullyShowing;
  late final AnimationController _selectedUnderlineAnimation;
  // currently inactive. I was considering using this for doing a deletion where most of the deletion animation happens in-place and then it's shunted out into another layer just for the end.
  late final AnimationController _deletionAnimation;
  final GlobalKey _clockKey = GlobalKey();
  final GlobalKey animatedToKey = GlobalKey();
  // used to prevent the deletion animation from being interfered with by animated to, which unfortunately only pays attention to paint position, so slows down even non-layout position transforms.
  late final Signal<bool> animatedToDisabled = createSignal(false);
  final previousSize = ValueNotifier<Size?>(null);
  final transferrableKey = GlobalKey();
  bool hasDisabled = false;
  TimerData? previousValue;

  /// kept so that drag handlers will know to remove it from the lsit
  late MobjID? owningList;

  // maybe I should just use an animated_to like approach. I'm pretty sure the current approach (AnimatedContainers) wont work because when we transfer between two containers a remove will play that will mount the same globalkey twice. Terrible.
  // /// set at the end of a drag animation with the position of the drag item relative to the parent
  // Offset? comingHomeFrom;

  set selected(bool v) {
    if (p.selected == v) return;
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
    _appearanceAnimation = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
    if (widget.animateIn) {
      _appearanceAnimation.forward();
    } else {
      _appearanceAnimation.value = 1;
    }

    _runningAnimation = AnimationController(
        duration: const Duration(milliseconds: 80), vsync: this);
    _slideBounceDirection = Offset(0, -1);
    _slideActivateBounceAnimation = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
    _unpinnedIndicatorShowing = AnimationController(
        duration: const Duration(milliseconds: 150), vsync: this);
    _unpinnedIndicatorFullyShowing = AnimationController(
        duration: const Duration(milliseconds: 150), vsync: this);
    _selectedUnderlineAnimation = AnimationController(
        duration: const Duration(milliseconds: 250), vsync: this);

    _deletionAnimation = AnimationController(
        duration: const Duration(milliseconds: 240), vsync: this);
    _ticker = createTicker((d) {
      setTime(durationToSeconds(DateTime.now().difference(p.startTime)));
    });
    createEffect(() {
      TimerData? d = widget.mobj.value;
      bool isSelected = d?.selected ?? false;
      if (previousValue?.selected != isSelected) {
        if (isSelected) {
          _selectedUnderlineAnimation.forward();
        } else {
          _selectedUnderlineAnimation.reverse();
        }
      }
      if (d == null) {
        _deletionAnimation.forward();
        disable();
        return;
      }
      if ((previousValue?.isRunning ?? false) != d.isRunning) {
        if (d.isRunning) {
          _runningAnimation.forward();
          _ticker.start();
        } else {
          _runningAnimation.reverse();
          _ticker.stop();
        }
      }
      moveAnimationTowardsState(_unpinnedIndicatorShowing, !d.pinned);
      moveAnimationTowardsState(_unpinnedIndicatorFullyShowing, !d.isRunning);

      // Trigger underline animation when selected changes
      moveAnimationTowardsState(_selectedUnderlineAnimation, d.selected);

      previousValue = d;
    });
  }

  @override
  dispose() {
    disable();
    _appearanceAnimation.dispose();
    _runningAnimation.dispose();
    _unpinnedIndicatorShowing.dispose();
    _unpinnedIndicatorFullyShowing.dispose();
    _selectedUnderlineAnimation.dispose();
    _deletionAnimation.dispose();
    previousSize.dispose();

    super.dispose();
  }

  void disable() {
    if (hasDisabled) return;
    hasDisabled = true;
    _ticker.dispose();
  }

  void setTime(double nd) {
    if (currentTime == nd) {
      return;
    }
    setState(() {
      currentTime = nd;
      // we don't set the timer off/change its state, enlivenTimer bindings do that
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = watchSignal(context, widget.mobj) ?? previousValue!;
    final theme = Theme.of(context);
    final mt = MakoThemeData.fromTheme(theme);
    final mover = 0.1;

    // final thumbSpan = Thumbspan.of(context);

    final dd = durationToSeconds(digitsToDuration(d.digits));
    // sometimes the background thread completes the timer, the currentTime wont be updated, so in that case it should be ignored.
    double pieCompletion = d.transpired / dd;
    final durationDigits = d.digits;
    final timeDigits = durationToDigits(d.transpired,
        padLevel: padLevelFor(durationDigits.length));

    List<int> withDigitsReplacedWith(List<int> v, int d) =>
        List.filled(v.length, d);

    // Selected underline animation
    // why is this still clipping (why does it seem to move down so far)
    Widget selectionUnderline = AnimatedBuilder(
      animation: _selectedUnderlineAnimation,
      builder: (context, child) {
        final progress =
            Curves.easeOut.transform(_selectedUnderlineAnimation.value);
        final underlineHeight = 9.0;
        final gap = 3.0;

        return Positioned(
          left: 0,
          right: 0,
          bottom: -underlineHeight - gap,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: progress,
            child: Container(
              height: underlineHeight,
              decoration: BoxDecoration(
                color: mt.foreBackColor,
                borderRadius: BorderRadius.circular(underlineHeight / 2),
              ),
            ),
          ),
        );
      },
    );

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
                      // adding a second invisible but laid-out copy of the text, underneath the top text, so that if the width of the numerals changes the width of the timer doesn't. We assume that 0 is the widest digit, because it was on mako's machine. If this fails to hold, we can precalculate which is the widest digit.
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
                      Stack(clipBehavior: Clip.none, children: [
                        Transform.scale(
                            alignment: Alignment.topLeft,
                            scale: lerp(1, 0.6, v),
                            child: Text(boring.formatTime(durationDigits),
                                overflow: TextOverflow.clip)),
                        selectionUnderline,
                      ]),
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
              scale: 1,
              child: Container(
                  decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: mt.foreBackColor,
              )),
            )));

    // Widget clockDial = AnimatedBuilder(
    //     key: _clockKey,
    //     animation: _runningAnimation,
    //     builder: (context, child) => Container(
    //           padding:
    //               EdgeInsets.all((1 - _runningAnimation.value) * timerPaddingr),
    //           decoration: BoxDecoration(
    //             shape: BoxShape.circle,
    //             color: mt.foreBackColor,
    //           ),
    //           constraints: BoxConstraints(maxHeight: 49, maxWidth: 49),
    //           child: child,
    //         ),
    //     child: Stack(
    //       clipBehavior: Clip.none,
    //       fit: StackFit.expand,
    //       children: [
    //         // expandingHindCircle,
    //         // there's a very strange bug where the pie doesn't repaint when the timer is being dragged. Every other animation still works. I checked, and although build is being called, shouldRepaint isn't. I'm gonna ignore it for now.
    //         // oh! and I notice the numbers don't update either!
    //         Pie(
    //           backgroundColor: backgroundColor(d.hue),
    //           color: primaryColor(d.hue),
    //           value: pieCompletion,
    //           size: pieRadius,
    //         ),
    //       ],
    //     ));
    Widget clockDial = Container(
      padding: EdgeInsets.all(timerOutline),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: mt.foreBackColor,
      ),
      child: Pie(
          backgroundColor: backgroundColor(d.hue),
          color: primaryColor(d.hue),
          value: pieCompletion,
          size: 2 * watchSignal(context, timerWidgetRadius)!),
    );

    Widget result = GestureDetector(
      onTap: () {
        context
            .findAncestorStateOfType<TimerScreenState>()
            ?.takeActionOn(widget.mobj.id);
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.all(timerGap / 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            clockDial,
            SizedBox(width: timerGap * 0.4),
            Flexible(
              child: timeText,
            ),
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
            // // the running animation is mostly conveyed by the expanding circle, so only turn on as a contingency in case the circle doesn't fill it
            // color: _runningAnimation.value == 1
            //     ? theme.colorScheme.surfaceContainerLowest
            //     : theme.colorScheme.surfaceContainerLowest.withAlpha(0)
          ),
          child: child),
      child: result,
    );

    // probably just going to use the existing ring (visible when timer isn't playing) for this instead
    // Widget unpinnedIndicator = AnimatedBuilder(
    //   animation: Listenable.merge([
    //     _unpinnedIndicatorShowing,
    //     _unpinnedIndicatorFullyShowing,
    //   ]),
    //   builder: (context, child) {
    //     final circleSize = lerp(
    //             3,
    //             7,
    //             Curves.easeInOut
    //                 .transform(_unpinnedIndicatorFullyShowing.value)) *
    //         Curves.easeOut.transform(_unpinnedIndicatorShowing.value);

    //     return Container(
    //         clipBehavior: Clip.none,
    //         width: 0,
    //         height: 0,
    //         child: Center(
    //           child: Container(
    //             width: circleSize,
    //             height: circleSize,
    //             decoration: BoxDecoration(
    //               shape: BoxShape.circle,
    //               color: backgroundColor(d.hue),
    //             ),
    //           ),
    //         ));
    //   },
    // );

    result = Stack(
      clipBehavior: Clip.none,
      children: [
        result,
        // Positioned(
        //   left: 1.4,
        //   bottom: 1.4,
        //   child: unpinnedIndicator,
        // ),
        // selectedUnderline,
      ],
    );

    result = AnimatedBuilder(
        animation: _appearanceAnimation,
        child: result,
        builder: (context, child) => FractionalTranslation(
              translation: Offset(
                  0,
                  0.6 *
                      (1.0 -
                          Curves.easeOut
                              .transform(_appearanceAnimation.value))),
              child: FuzzyLinearClip(
                angle: pi / 2,
                progress: _appearanceAnimation.value,
                child: child!,
              ),
            ));

    // do a bounce animation to respond to slide to start interactions
    double bounceDistance =
        10 * defaultPulserFunction(_slideActivateBounceAnimation.value);
    result = AnimatedBuilder(
        animation: _slideActivateBounceAnimation,
        builder: (context, child) => Transform.translate(
            offset: _slideBounceDirection * bounceDistance, child: child),
        child: result);

    // result = AnimatedBuilder(
    //   animation: _deletionAnimation,
    //   builder: (context, child) =>
    //       Opacity(opacity: 1 - _deletionAnimation.value, child: child),
    //   child: result,
    // );

    result = AnimatedTo.spring(
        globalKey: animatedToKey,
        enabled: !watchSignal(context, animatedToDisabled)!,
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

  final Computed<TimerWidgets> timerWidgets;

  /// Icon widget that displays above the sequence
  final Widget? icon;

  /// Whether this sequence should render within a scrollview
  final bool useScrollView;

  /// Callback for when a timer is dropped into this sequence
  final Function(MobjID<TimerData> timerId)? onTimerDropped;

  const TimerTray({
    super.key,
    required this.mobj,
    required this.backgroundColor,
    required this.timerWidgets,
    this.icon,
    this.useScrollView = true,
    this.onTimerDropped,
  });

  @override
  State<TimerTray> createState() => _TimerTrayState();
}

typedef TimerWidgets = Map<MobjID<TimerData>, Timer>;

class _TimerTrayState extends State<TimerTray> with SignalsMixin {
  late final GlobalKey wrapKey;

  @override
  void initState() {
    super.initState();
    wrapKey = GlobalKey();
  }

  List<MobjID<TimerData>> get p => widget.mobj.peek()!;

  @override
  Widget build(BuildContext context) {
    final result = Watch((context) {
      final isRightHanded =
          Mobj.getAlreadyLoaded(isRightHandedID, const BoolType()).value!;
      return Align(
          alignment: isRightHanded
              ? FractionalOffset(0.8, 1)
              : FractionalOffset(0.2, 1),
          child: IWrap(
            key: wrapKey,
            textDirection:
                isRightHanded ? TextDirection.ltr : TextDirection.rtl,
            // TextDirection.rtl,
            clipBehavior: Clip.none,
            verticalDirection: VerticalDirection.down,
            alignment: WrapAlignment.end,
            crossAxisAlignment:
                // isRightHanded ? WrapCrossAlignment.end : WrapCrossAlignment.start,
                WrapCrossAlignment.start,
            children: widget.mobj.value!
                .map((ki) => widget.timerWidgets.value[ki]!)
                .toList(),
          ));
    });

    return DragTarget<GlobalKey<TimerState>>(
      builder: (context, candidateData, rejectedData) => result,
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

/// Ephemeral animation for timer deletion - swipes the timer left with clipping
class _TimerDeletionAnimation extends StatefulWidget {
  final Rect rect;
  final Widget timerWidget;
  final bool direction;
  final Duration duration;

  const _TimerDeletionAnimation({
    super.key,
    required this.rect,
    required this.timerWidget,
    required this.direction,
    required this.duration,
  });

  @override
  State<_TimerDeletionAnimation> createState() =>
      _TimerDeletionAnimationState();
}

class _TimerDeletionAnimationState extends State<_TimerDeletionAnimation> {
  @override
  Widget build(BuildContext context) {
    //    bool isRightHanded =
    // Mobj.getAlreadyLoaded(isRightHandedID, const BoolType()).value!;
    return Positioned(
      left: widget.rect.left,
      top: widget.rect.top,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: widget.duration,
          onEnd: () {
            // Remove this widget from the ephemeral animation host when animation completes
            context
                .findAncestorStateOfType<EphemeralAnimationHostState>()
                ?.remove(widget);
          },
          builder: (context, progress, child) {
            // I'm not really sure it's a good idea to have two animations happening inconsistently
            // if (direction) {
            // return Transform.translate(
            //     offset: Offset(isRightHanded ? -70 : 70, 0) *
            //         Curves.easeOut.transform(progress),
            //     child: FuzzyExpandingCircle(
            //       progress: 1.0 - progress,
            //       invertGradient: true,
            //       originRight: isRightHanded ? 10 : null,
            //       originLeft: isRightHanded ? null : 10,
            //       child: child!,
            //     ));
            // } else {
            return Transform.translate(
                offset: Offset(0, -30 * Curves.easeOut.transform(progress)),
                child: FuzzyCircleClip(
                  progress: 1.0 - progress,
                  fuzzyEdgeWidth: 6,
                  invertGradient: true,
                  origin: RelAlignment(originBottom: -90, originLeft: 27),
                  child: child!,
                ));
            // }
          },
          child: widget.timerWidget,
        ),
      ),
    );
  }
}

class TimerScreen extends StatefulWidget {
  const TimerScreen({super.key});

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
void pausePlaySelected(TimerScreenState tss) {
  tss.pausePlaySelected();
  HapticFeedback.lightImpact();
}

final List<Function(TimerScreenState)> radialActivatorFunctions = [
  pausePlaySelected,
  (tss) {
    tss.numeralPressed([0, 0]);
    pausePlaySelected(tss);
  },
];

class NumeralDragActionRing extends StatefulWidget {
  final Offset position;
  final Signal<int?> dragEvents;
  final Listenable numeralDragActionRingBus;
  const NumeralDragActionRing(
      {super.key,
      required this.position,
      required this.dragEvents,
      required this.numeralDragActionRingBus});

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

  void _onOtherRingOpens() {
    upDownAnimation.reverse();
  }

  @override
  void initState() {
    super.initState();
    widget.numeralDragActionRingBus.addListener(_onOtherRingOpens);
    upDownAnimation = UpDownAnimationController(
      vsync: this,
      riseDuration: Duration(milliseconds: 300),
      fallDuration: Duration(milliseconds: 140),
    );
    upDownAnimation.forward();
    optionActivationAnimation = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 200),
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
    widget.numeralDragActionRingBus.removeListener(_onOtherRingOpens);
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

  Widget buildWithGivenAnimationParameters(
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

    final revealFraction = 1 - Curves.easeOut.transform(swipep);
    final revealCenter = numberSelected != -1
        ? positionFor(numberSelected, overrideRisep: 1)
        : Offset.zero;
    final revealMaxRadius = totalSpan;

    return IgnorePointer(
        child: FractionalTranslation(
            translation: Offset(-0.5, -0.5),
            child: ShaderMask(
              shaderCallback: (bounds) => createRadialRevealShader(
                bounds: bounds,
                center: Alignment(revealCenter.dx / (bounds.size.width / 2),
                    revealCenter.dy / (bounds.size.height / 2)),
                fraction: revealFraction,
                fuzzyEdgeWidth: 20.0,
                maxRadius: revealMaxRadius,
              ),
              child: SizedBox(
                  width: totalSpan,
                  height: totalSpan,

                  // so that child contents can still be relative to 0 and be centered within this
                  child: Transform.translate(
                    offset: Offset(totalSpan / 2, totalSpan / 2),
                    // offset: Offset.zero,
                    child: Stack(clipBehavior: Clip.none, children: [
                      radialActivationRing,
                      ...numeralDragRadialActivators
                    ]),
                  )),
            )));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
        left: widget.position.dx,
        top: widget.position.dy,
        child: AnimatedBuilder(
          animation:
              Listenable.merge([upDownAnimation, optionActivationAnimation]),
          builder: (context, child) {
            return buildWithGivenAnimationParameters(upDownAnimation.value.$1,
                upDownAnimation.value.$2, optionActivationAnimation.value);
          },
        ));
  }
}

class TimerScreenState extends State<TimerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  late final Signal<MobjID<TimerData>?> selectedTimer = createSignal(null);
  late final Signal<Rect?> lastSelectedTimerBounds = createSignal(null);
  late final Computed<TimerWidgets> timerWidgets;
  late final Mobj<bool> isRightHandedMobj =
      Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());
  late final Signal<Rect> numPadBounds = Signal(Rect.zero);
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => timerListMobj.value!;
  List<MobjID<TimerData>> peekTimers() => timerListMobj.peek()!;

  GlobalKey controlPadKey = GlobalKey();
  GlobalKey timerTrayKey = GlobalKey();
  GlobalKey pinButtonKey = GlobalKey();
  GlobalKey deleteButtonKey = GlobalKey();
  GlobalKey<EphemeralAnimationHostState> ephemeralAnimationLayer = GlobalKey();
  final Mobj<List<MobjID<TimerData>>> timerListMobj =
      Mobj.getAlreadyLoaded(timerListID, timerListType);
  // final Mobj<List<MobjID<TimerData>>> transientTimerListMobj =
  //     Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
  late final Mobj<double> nextHueMobj =
      Mobj.getAlreadyLoaded(nextHueID, const DoubleType());
  late final Mobj<bool> buttonScaleDialOn =
      Mobj.getAlreadyLoaded(buttonScaleDialOnID, const BoolType());
  late final Mobj<double> buttonSpanMobj =
      Mobj.getAlreadyLoaded(buttonSpanID, const DoubleType());
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());
  late SmoothOffset modeMovementAnimation = SmoothOffset(
      vsync: this,
      initialValue: Offset.zero,
      duration: Duration(milliseconds: 200));
  late AnimationController modeLivenessAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));
  // emits whenever a drag action ring is created, so that older ones can disable themselves
  late final ChangeNotifier onNewNumeralDragActionRing = ChangeNotifier();
  late final AnimationController buttonScaleDialAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));
  late final AnimationController buttonScaleFlashAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 1600));
  late final Signal<Offset?> buttonScaleDialCenter = createSignal(Offset.zero);
  late final Signal<double> buttonScaleDialAngle = createSignal(0.0);
  async.Timer? buttonScaleDialLeavingTimer;
  Rect editPopoverControls = Rect.zero;
  late final AnimationController editPopoverAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200))
        ..value = 0;

  /// which mode is currently selected. Can be 'pin', 'delete', or 'play', any other value will be treated as 'play'
  /// we should probably persist this... but it doesn't matter much.
  late Signal<String> actionMode = createSignal('play');

  @override
  void initState() {
    super.initState();
    // make sure the mode indicator follows the current mode
    createEffect(() {
      void moveTo(GlobalKey target) {
        Offset t =
            renderBox(controlPadKey)!.globalToLocal(boxRect(target)!.center);
        if (modeLivenessAnimation.value == 0) {
          modeMovementAnimation.value = t;
        } else {
          modeMovementAnimation.target(t);
        }
        modeLivenessAnimation.forward();
      }

      if (actionMode.value == 'pin') {
        moveTo(pinButtonKey);
      } else if (actionMode.value == 'delete') {
        moveTo(deleteButtonKey);
      } else {
        modeLivenessAnimation.reverse();
      }
    });
    // resetting the button scale dial
    createEffect(() {
      if (buttonScaleDialOn.value!) {
        buttonScaleDialAnimation.forward();
        buttonScaleDialCenter.value = null;
        buttonScaleDialAngle.value = 0.0;
        buttonScaleFlashAnimation.forward(from: 0);
      } else {
        buttonScaleDialAnimation.reverse();
      }
    });
    TimerWidgets prevTimerWidgets = {};
    timerWidgets = createComputed(() {
      TimerWidgets next = {};
      for (MobjID t in timerListMobj.value!) {
        next[t] = prevTimerWidgets[t] ??
            Timer(
                key: GlobalKey(),
                mobj: Mobj.getAlreadyLoaded(t, TimerDataType()),
                animateIn: true,
                owningList: timerListMobj.id);
      }
      prevTimerWidgets = next;
      return next;
    });

    void updateLastSelectedTimerBounds([bool recursed = false]) {
      bool delayAnimation = false;
      if (selectedTimer.value == null) {
        editPopoverAnimation.reverse();
      } else {
        Rect? r =
            boxRect(timerWidgets.value[selectedTimer.value!]!.key as GlobalKey);
        if (r != null) {
          lastSelectedTimerBounds.value = r;
        } else {
          // r will always be null though, since the new timer isn't mounted in the frame when selectedTimer is changed
          if (!recursed) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => updateLastSelectedTimerBounds(true));
            delayAnimation = true;
          }
        }
        if (r != null && !delayAnimation) {
          editPopoverAnimation.forward();
        }
      }
    }

    createEffect(updateLastSelectedTimerBounds);
  }

  @override
  void dispose() {
    onNewNumeralDragActionRing.dispose();
    numPadBounds.dispose();
    selectedTimer.dispose();
    actionMode.dispose();
    modeMovementAnimation.dispose();
    modeLivenessAnimation.dispose();
    super.dispose();
  }

  void takeActionOn(MobjID<TimerData> timerID) {
    String mode = actionMode.peek();
    if (mode == 'pin') {
      Mobj.fetch(timerID, type: TimerDataType()).then((mt) {
        bool pp = mt.peek()!.pinned;
        if (pp && !mt.peek()!.isRunning) {
          deleteTimer(timerID);
        } else {
          mt.value = mt.peek()!.withChanges(pinned: !pp);
        }
      });
    } else if (mode == 'delete') {
      deleteTimer(timerID);
    } else {
      mode = 'play';
      toggleRunning(timerID, reset: false);
    }
    _selectTimer(null);
  }

  double nextRandomHue() {
    final ret = nextHueMobj.value!;
    final increment = 0.1 + Random().nextDouble() * 0.15;
    nextHueMobj.value = (ret + increment) % 1;
    return ret;
  }

  void numeralPressed(List<int> number, {bool viaKeyboard = false}) {
    if (selectedTimer.peek() == null) {
      addNewTimer(
        selected: true,
        digits: stripZeroes(number),
      );
    } else {
      final mt = Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
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
    Size screenSize = MediaQuery.sizeOf(context);
    MakoThemeData mt = MakoThemeData.fromTheme(theme);
    watchSignal(context, isRightHandedMobj)!;
    bool padVerticallyAscending = watchSignal(context,
        Mobj.getAlreadyLoaded(padVerticallyAscendingID, const BoolType()))!;

    Widget proportionedIcon(IconData icon, {double size = 22}) {
      return ScalingAspectRatio(
          child: SizedBox(
              width: 50,
              height: 50,
              child: Center(child: Icon(size: size, icon))));
    }

    final configButtonKey = GlobalKey();
    final hereConfigButtonKey = GlobalKey();
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
        key: deleteButtonKey,
        label: proportionedIcon(Icons.backspace),
        onPanDown: (_) {
          _backspace();
        });

    var pinButton = TimersButton(
        key: pinButtonKey,
        label: proportionedIcon(Icons.push_pin),
        onPanEnd: () {
          _selectAction('pin');
        });

    final addButton = TimersButton(
        label: proportionedIcon(Icons.add_circle),
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

    // final pausePlayButton = TimersButton(
    //     label: playIcon(Icon(Icons.pause_rounded)),
    //     onPanDown: (_) {
    //       pausePlaySelected();
    //     });
    final stopPlayButton = TimersButton(
        label: playIcon(Icon(Icons.restart_alt_rounded)),
        onPanDown: (_) {
          pausePlaySelected(reset: true);
        });

    final thumbSpan = Thumbspan.of(context);

    final buttonScaleDial = Watch(
      (context) {
        if (buttonScaleDialCenter.value == null) {
          Offset p = Offset(screenSize.width * 0.23, screenSize.height / 2);
          if (!isRightHandedMobj.value!) {
            p = Offset(screenSize.width - p.dx, p.dy);
          }
          buttonScaleDialCenter.value = p;
        }
        return positionedAt(
          buttonScaleDialCenter.value!,
          FractionalTranslation(
              translation: Offset(-0.5, -0.5),
              child: AnimatedBuilder(
                animation: Listenable.merge(
                    [buttonScaleDialAnimation, buttonScaleFlashAnimation]),
                builder: (context, child) {
                  final fa = buttonScaleFlashAnimation.value;
                  double flashu =
                      fa == 1.0 ? 0 : moduloProperly(-fa, 1.0 / 5.0);
                  return Transform.scale(
                      scale: Curves.easeOutCubic
                          .transform(buttonScaleDialAnimation.value),
                      child: GestureDetector(
                        onPanDown: (details) {
                          buttonScaleDialLeavingTimer?.cancel();
                        },
                        onPanUpdate: (details) {
                          final aa = angleFrom(buttonScaleDialCenter.peek()!,
                              details.globalPosition - details.delta);
                          final ab = angleFrom(buttonScaleDialCenter.peek()!,
                              details.globalPosition);
                          final a = shortestAngleDistance(aa, ab);
                          buttonScaleDialAngle.value += a;
                          buttonSpanMobj.value = clampDouble(
                              buttonSpanMobj.value! + a * 1.2,
                              12,
                              screenSize.width / 5);
                          print(
                              "buttonSpanMobj.value: ${buttonSpanMobj.value}");
                        },
                        onPanEnd: (details) {
                          buttonScaleDialLeavingTimer =
                              async.Timer(Duration(milliseconds: 470), () {
                            buttonScaleDialOn.value = false;
                          });
                        },
                        child: Transform.rotate(
                          transformHitTests: false,
                          angle: buttonScaleDialAngle.value,
                          child: Container(
                            width: 140,
                            height: 140,
                            decoration: BoxDecoration(
                              color: lerpColor(mt.midBackColor,
                                  theme.colorScheme.primary, flashu),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanDown: (details) {},
                                onPanUpdate: (details) {
                                  buttonScaleDialCenter.value =
                                      buttonScaleDialCenter.value! +
                                          details.delta;
                                },
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    color: mt.foreBackColor,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Text("turn me",
                                          textAlign: TextAlign.center)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ));
                },
              )),
        );
      },
    );

    // the lower part of the screen
    final controls = Watch(key: controlPadKey, (context) {
      return LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final bottomGutter = thumbSpan * 0.3;
        final buttonSpan = min(w / 5, buttonSpanMobj.value!);
        final h = bottomGutter + 4 * buttonSpan;
        final buttonSize = Size(buttonSpan, buttonSpan);
        final isRightHanded = isRightHandedMobj.value!;
        // this code is supposed to nudge things over a little to be perfectly centered if stuff is very close to being centered.
        double tentativeRightPos = w - buttonSpan / 2 * 1.16;
        final imperfection = ((tentativeRightPos - 2 * buttonSpan) - w / 2) / w;
        if (imperfection < 0.055) {
          tentativeRightPos = w / 2 + 2 * buttonSpan;
        }
        final topRightPos = Offset(tentativeRightPos, buttonSpan / 2);

        // final topLeftPos = topRightPos + Offset(-buttonSpan * 5, 0);
        Rect positionAt(Offset pi, Size spani) {
          Offset point = (topRightPos + pi * buttonSpan);
          if (!isRightHanded) {
            point =
                Offset(w - point.dx - (spani.width - 1) * buttonSpan, point.dy);
          }
          return ((point - sizeToOffset(buttonSize / 2)) &
              (spani * buttonSpan));
        }

        final configButton = TimersButton(
            key: hereConfigButtonKey,
            label: SizedBox(
              width: buttonSpan * 0.54,
              height: buttonSpan * 0.54,
              child: Hero(
                  tag: 'configButton',
                  child: ScalingAspectRatio(
                      child: Icon(
                    size: 10,
                    Icons.settings_rounded,
                  ))),
            ),
            // onPanDown feels more responsive of course, but it's inconsistent with usual behavior of touch interfaces, so I'm not sure which is better
            // onPanDown: (_) {
            onPanEnd: () {
              Navigator.push(
                context,
                CircularRevealRoute(
                  builder: (context) => SettingsScreen(
                      iconKey: configButtonKey, flipBackgroundColors: false),
                  buttonCenter: widgetCenter(hereConfigButtonKey),
                  iconKey: configButtonKey,
                ),
              );
            });

        final backingCornerRounding = 0.37;
        final double e = 0.07 * buttonSpan;
        Widget numeralBacking = Positioned.fromRect(
            rect: positionAt(Offset(-3, 0), Size(3, 4)).deflate(e),
            child: Container(
                constraints: BoxConstraints.expand(),
                decoration: BoxDecoration(
                    color: mt.foreBackColor,
                    borderRadius: BorderRadius.circular(
                        backingCornerRounding * buttonSpan))));

        final double modalHighlightSpan = buttonSpan - 2 * e;
        Widget modalHighlightBacking = AnimatedBuilder(
          animation:
              Listenable.merge([modeMovementAnimation, modeLivenessAnimation]),
          builder: (context, child) {
            return positionedAt(
                modeMovementAnimation.value,
                FractionalTranslation(
                  translation: Offset(-0.5, -0.5),
                  child: SizedBox(
                    width: modalHighlightSpan * modeLivenessAnimation.value,
                    height: modalHighlightSpan * modeLivenessAnimation.value,
                    child: Container(
                        decoration: BoxDecoration(
                            color: mt.foreBackColor,
                            borderRadius: BorderRadius.circular(
                                backingCornerRounding * buttonSpan))),
                  ),
                ));
          },
        );

        final editPopoverButtonWidth = buttonSpan;
        final editPopoverButtonHeight = buttonSpan;
        final epw = 2 * editPopoverButtonWidth;
        final editPopoverControls = Watch((context) {
          Rect lr = lastSelectedTimerBounds.value ??
              Rect.fromLTWH(MediaQuery.of(context).size.width / 2, 0, 0, 0);
          return Positioned(
            left: isRightHanded
                ? lr.left + timerWidgetRadius.value - epw
                : lr.right - timerWidgetRadius.value,
            bottom: h,
            child: IgnorePointer(
              ignoring: selectedTimer.value == null,
              child: AnimatedBuilder(
                animation: editPopoverAnimation,
                builder: (context, child) {
                  return FuzzyLinearClip(
                    angle: -pi / 2,
                    progress: editPopoverAnimation.value,
                    child: Row(
                      children: [
                        GestureDetector(
                            onTap: () {
                              _backspace();
                            },
                            child: SizedBox(
                              width: editPopoverButtonWidth,
                              height: editPopoverButtonHeight,
                              child: Icon(
                                Icons.delete_rounded,
                                size: editPopoverButtonHeight * 0.5,
                              ),
                            )),
                        GestureDetector(
                            onTap: () {
                              pausePlaySelected();
                            },
                            child: SizedBox(
                              width: editPopoverButtonWidth,
                              height: editPopoverButtonHeight,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: editPopoverButtonHeight * 0.5,
                              ),
                            )),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        });

        final numeralPartAnchor = Offset(-3, 0);
        final outerPaletteAnchor = Offset(-4, 0);
        final innerPaletteAnchor = Offset(0, 0);

        return SizedBox(
          width: w,
          height: h,
          child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.passthrough,
              children: [
                modalHighlightBacking,
                numeralBacking,
                ...List.generate(9, (i) {
                  int ix = i % 3;
                  // double invert
                  if (!isRightHanded) {
                    ix = 2 - ix;
                  }
                  final ii = i + 1;
                  return Positioned.fromRect(
                      rect: positionAt(
                          numeralPartAnchor +
                              Offset(ix.toDouble(), (i ~/ 3).toDouble()),
                          Size(1, 1)),
                      child: NumeralButton(
                          digits: [ii],
                          timerButtonKey: numeralKeys[ii],
                          otherDragActionRingStarted:
                              onNewNumeralDragActionRing));
                }),
                Positioned.fromRect(
                    rect: positionAt(
                        numeralPartAnchor + Offset(0, 3), Size(1, 1)),
                    child: NumeralButton(
                        digits: [0],
                        timerButtonKey: numeralKeys[0],
                        otherDragActionRingStarted:
                            onNewNumeralDragActionRing)),
                Positioned.fromRect(
                    rect: positionAt(
                        innerPaletteAnchor + Offset(0, 0), Size(1, 1)),
                    child: configButton),
                // Positioned.fromRect(
                //     rect: positionAt(outerPaletteAnchor, Size(1, 1)),
                //     child: backspaceButton),
                Positioned.fromRect(
                    rect: positionAt(
                        innerPaletteAnchor + Offset(0, 1), Size(1, 1)),
                    child: pinButton),
                editPopoverControls,
              ]),
        );
      });
    });

    final timersWidget = TimerTray(
      key: timerTrayKey,
      timerWidgets: timerWidgets,
      mobj: timerListMobj,
      backgroundColor: mt.lowestBackColor,
      icon: Icon(Icons.push_pin), // You can customize this icon
      useScrollView: true,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarContrastEnforced: false,
          systemNavigationBarDividerColor: mt.lowestBackColor.withAlpha(0),
          systemNavigationBarColor: mt.lowestBackColor.withAlpha(0),
          systemNavigationBarIconBrightness: theme.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: Scaffold(
          backgroundColor: mt.lowestBackColor,
          body: Focus(
            autofocus: true, // Automatically request focus when built
            onKeyEvent: (_, event) {
              _handleKeyPress(event);
              return KeyEventResult.handled; // Prevent event from propagating
            },
            child: EphemeralAnimationHost(
                key: ephemeralAnimationLayer,
                builder: (children, context) => Stack(children: children),
                // we stack a bunch of stuff here that's not ephemeral because that's allowed
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Flexible(flex: 1, child: timersWidget),
                      controls,
                    ],
                  ),
                  buttonScaleDial,
                ]),
          ),
        ));
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
    TimerData nv = timer.peek()!.toggleRunning(reset: reset);
    timer.value = nv;
    return !wasRunning;
  }

  void pausePlaySelected({bool reset = false}) {
    if (selectedTimer.peek() != null) {
      if (toggleRunning(selectedTimer.peek()!, reset: reset)) {
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
    Mobj.getAlreadyLoaded(hasCreatedTimerID, const BoolType()).value = true;

    timerListMobj.value = timers().toList()..add(ntid);
    if (selecting) {
      _selectTimer(ntid);
    }

    // remove (previous) unpinned nonplaying timers
    final curTimers = peekTimers();
    for (final tid in curTimers) {
      if (tid == ntid) continue;
      final t = Mobj.getAlreadyLoaded(tid, TimerDataType());
      if (!t.peek()!.pinned && !t.peek()!.isRunning) {
        // delay slightly to make it clear what's happened (might not be necessary if we introduce deletion animations)
        deleteTimer(tid, pushAside: true);
      }
    }
  }

  void _selectTimer(MobjID<TimerData>? timerID) {
    if (selectedTimer.peek() != null) {
      final oldMobj =
          Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      oldMobj.value = oldMobj.peek()!.withChanges(selected: false);
    }
    selectedTimer.value = timerID;
    if (timerID != null) {
      final newMobj = Mobj.getAlreadyLoaded(timerID, TimerDataType());
      newMobj.value = newMobj.peek()!.withChanges(selected: true);
    }
  }

  void _backspace() {
    if (selectedTimer.peek() != null) {
      final mobj =
          Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      List<int> digits = List.from(mobj.peek()!.digits);

      if (digits.isEmpty) {
        deleteTimer(selectedTimer.peek()!);
      } else {
        digits.removeLast();
        if (digits.isEmpty) {
          deleteTimer(selectedTimer.peek()!);
        } else {
          mobj.value = mobj.peek()!.withChanges(digits: digits);
        }
      }
    } else {
      _selectAction('delete');
      // if (timers().isNotEmpty) {
      //   deleteTimer(timers().last);
      // }
    }
  }

  void _selectAction(String action) {
    if (actionMode.peek() != action) {
      actionMode.value = action;
    } else {
      actionMode.value = 'play';
    }
  }

  void deleteTimer(MobjID ki, {bool pushAside = false}) {
    // Get the timer's position and size using the globalkey, so that we can animate the exit in the EphemeralHost layer
    final timerWidget = timerWidgets.value[ki];
    if (timerWidget != null) {
      final timerKey = timerWidget.key as GlobalKey<TimerState>;
      final timerState = timerKey.currentState;

      assert(timerState != null && timerState.mounted);
      final renderBox = timerState!.context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        Rect tr = boxRectRelativeTo(boring.renderBox(timerKey),
            boring.renderBox(ephemeralAnimationLayer))!;

        // Create and add the deletion animation
        (timerWidget.key as GlobalKey<TimerState>)
            .currentState!
            .animatedToDisabled
            .value = true;
        final deletionAnimationWidget = _TimerDeletionAnimation(
          key: UniqueKey(),
          direction: pushAside,
          rect: tr,
          timerWidget: timerWidget,
          duration: const Duration(milliseconds: 270),
        );

        ephemeralAnimationLayer.currentState!
            .addWithoutAutomaticRemoval(deletionAnimationWidget);
      }
    }

    removeTimer(ki);
    Mobj.getAlreadyLoaded(ki, TimerDataType()).value = null;
    // [todo] reduceRef
  }

  void removeTimer(MobjID ki) {
    // Check if timer exists in the list
    if (!peekTimers().contains(ki)) {
      return;
    }

    timerListMobj.value = peekTimers().toList()
      ..removeWhere((timer) => timer == ki);

    if (selectedTimer.peek() == ki) {
      _selectTimer(null);
    }
  }

  Mobj<TimerData>? selectedOrLastTimerState() {
    if (selectedTimer.peek() != null) {
      return Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
    } else {
      final lt = peekTimers().lastOrNull;
      if (lt != null) {
        return Mobj.getAlreadyLoaded(lt, TimerDataType());
      }
      return null;
    }
  }
}

class NumeralButton extends StatefulWidget {
  final List<int> digits;
  final GlobalKey<TimersButtonState>? timerButtonKey;
  final ChangeNotifier otherDragActionRingStarted;
  const NumeralButton(
      {super.key,
      required this.digits,
      this.timerButtonKey,
      required this.otherDragActionRingStarted});
  @override
  State<NumeralButton> createState() => _NumeralButtonState();
}

class _NumeralButtonState extends State<NumeralButton>
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
  bool dragActionRingDisabled = false;
  void _disable() {
    dragActionRingDisabled = true;
  }

  @override
  Widget build(BuildContext context) {
    return TimersButton(
      key: widget.timerButtonKey,
      label: widget.digits.join(),
      onPanDown: (Offset p) {
        hasTriggered = false;
        dragActionRingDisabled = false;
        _startDrag = p;
        final tss = context.findAncestorStateOfType<TimerScreenState>()!;
        tss.numeralPressed(widget.digits);
        dragEvents.value = -1;
        // ignore: invalid_use_of_protected_member
        widget.otherDragActionRingStarted.notifyListeners();
        widget.otherDragActionRingStarted.addListener(_disable);
        final numeralDragActionRing = NumeralDragActionRing(
          key: UniqueKey(),
          position: p,
          numeralDragActionRingBus: widget.otherDragActionRingStarted,
          dragEvents: dragEvents,
        );
        context
            .findAncestorStateOfType<EphemeralAnimationHostState>()
            ?.addWithoutAutomaticRemoval(numeralDragActionRing);
      },
      onPanUpdate: (Offset p) {
        Offset dp = p - _startDrag;
        if (!dragActionRingDisabled &&
            dp.distance > Thumbspan.of(context) * 0.18 &&
            !hasTriggered) {
          hasTriggered = true;
          final tss = context.findAncestorStateOfType<TimerScreenState>();
          if (tss == null) {
            return;
          }
          bool isRightHanded = tss.isRightHandedMobj.value!;
          final rectifiedActivatorPositions = isRightHanded
              ? radialActivatorPositions
              : radialActivatorPositions.map(flipAngleHorizontally).toList();
          // int dragResult = radialDragResult(
          //     rectifiedActivatorPositions, offsetAngle(dp),
          //     hitSpan: pi / 2);
          int dragResult = radialDragResult(
              rectifiedActivatorPositions, offsetAngle(dp),
              // no limit, will activate on the nearest option regardless of its distance. If you want to be more sophisticated, you can maintain an accumulator vector and not activate until the vector aligns somewhat closely with one of the options
              hitSpan: pi);
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
              final ts =
                  (tss.timerWidgets.value[lti]?.key as GlobalKey<TimerState>?)
                      ?.currentState;
              ts?._slideActivateBounceAnimation.forward(from: 0);
              ts?._slideBounceDirection = Offset.fromDirection(
                  rectifiedActivatorPositions[dragResult], 1);
            }
          }
        }
      },
      onPanEnd: () {
        dragEvents.value = null;
        widget.otherDragActionRingStarted.removeListener(_disable);
      },
    );
  }
}

const controlPadTextStyle = TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.normal,
  fontFamily: 'Dongle',
  height: 1.71, // Controls line height, adjust to fine-tune vertical centering
);

class TimersButton extends StatefulWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback? onTap;
  final bool accented;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final bool solidColor;
  final Animation<double>? dialBloomAnimation;

  const TimersButton(
      {super.key,
      required this.label,
      this.onTap,
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
        // most of this is junk, you can just cut it down to the label widget if you ever need to
        child: InkWell(
            onTap: widget.onTap,
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
                    labelWidget = ScalingAspectRatio(
                        child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                                child: Text(widget.label as String,
                                    style: controlPadTextStyle
                                        .merge(TextStyle(color: textColor))))));
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
  final Color? color;
  final double width;

  const _NumpadTypeIndicator(
      {required this.isAscending, this.color, this.width = 100.0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cellSpan = width / 3;
    final fontScale = cellSpan / 10;
    final color = this.color ?? theme.colorScheme.onSurface;

    return SizedBox(
      width: width,
      height: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(9, (index) {
          final widg = Text((index + 1).toString(),
              style: TextStyle(
                  fontSize: index == 0 ? 11.0 : 9.0,
                  color: color,
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
                translation: Offset(-0.5, -0.5),
                child: Transform.scale(scale: fontScale, child: widg)),
          );
        }),
      ),
    );
  }
}

double halfScreenHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  final screenHeight = mq.size.height;
  return screenHeight / 2 - mq.viewPadding.top;
}

// it would also look nice if you used this to size the app bar, but half is better for now
// double screenWidth(BuildContext context) {
//   final mq = MediaQuery.of(context);
//   return mq.size.width;
// }

(Color, Color) maybeFlippedBackgroundColors(
    ThemeData theme, bool flipBackgroundColors) {
  if (flipBackgroundColors) {
    return (
      theme.colorScheme.surfaceContainerLow,
      theme.colorScheme.surfaceContainerLowest
    );
  } else {
    return (
      theme.colorScheme.surfaceContainerLowest,
      theme.colorScheme.surfaceContainerLow
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final GlobalKey? iconKey;
  final bool flipBackgroundColors;
  const SettingsScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: 0,
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
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, widget.flipBackgroundColors);
    final listItemPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0);

    Widget trailing(Widget child) =>
        SizedBox(width: 32.0, child: Center(child: child));

    bool completedSetup = watchSignal(
        context, Mobj.getAlreadyLoaded(completedSetupID, const BoolType()))!;

    Widget setupTile = ListTile(
      title: Text('Setup', style: theme.textTheme.headlineLarge),
      subtitle: Text('Resume setup', style: theme.textTheme.bodyLarge),
      trailing: trailing(Icon(Icons.settings_rounded)),
      onTap: () {
        Navigator.push(context,
            CircularRevealRoute(builder: (context) => OnboardScreen()));
      },
    );

    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Collapsible app bar with title
          SliverAppBar(
            pinned: true,
            centerTitle: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale:
                  1.0, // Disable title scaling to prevent Hero discontinuity
              title: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 40,
                      height: 40,
                      child: Hero(
                        tag: 'configButton',
                        createRectTween: (begin, end) => DelayedRectTween(
                            begin: begin, end: end, delay: 0.14),
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.settings_rounded,
                          color: theme.colorScheme.onSurface,
                          size: 10,
                        )),
                      )),
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
            backgroundColor: backgroundColorB,
            surfaceTintColor: backgroundColorB,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          // Extra padding at top to allow scrolling content to bottom
          // SliverPadding(
          //   padding: EdgeInsets.only(top: _topPadding),
          // ),
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
                  // splashColor: Colors.black,

                  // aaargh I can't fix the awful white-grey aspect of the highlight and the smash
                  // focusColor: Colors.red,
                  // selectedColor: Colors.red,
                  // // tileColor: Colors.red,
                  // selectedTileColor: Colors.red,
                  // textColor: Colors.red,
                  // hoverColor: Colors.red,
                  // splashColor: Colors.black,

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
                    width: 36,
                  )),
                  onTap: () {
                    padVerticallyAscendingMobj.value = !padVerticallyAscending;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              // Alarm sound setting
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title: Text('Alarm sound', style: theme.textTheme.bodyLarge),
                  subtitle: Watch((context) {
                    return Text(
                      Mobj.getAlreadyLoaded(
                              selectedAudioID, const AudioInfoType())
                          .value!
                          .name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    );
                  }),
                  trailing: trailing(SizedBox(
                      width: 26,
                      height: 26,
                      child: Hero(
                        tag: 'alarm-sound-icon',
                        child: ScalingAspectRatio(
                            child: Icon(Icons.music_note,
                                key: hereIconKey,
                                color: theme.colorScheme.primary)),
                      ))),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => AlarmSoundPickerScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Watch((context) {
                final buttonScaleDialOnOn = Mobj.getAlreadyLoaded(
                    buttonScaleDialOnID, const BoolType());
                return ListTile(
                  title: Text('Button size', style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                      buttonScaleDialOnOn.value!
                          ? "Button scale dial is currently deployed, tap here to turn it off"
                          : 'Introduce a dial by which you can adjust UI scale',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  onTap: () {
                    buttonScaleDialOnOn.value = !buttonScaleDialOnOn.value!;
                    if (buttonScaleDialOnOn.value!) {
                      Navigator.of(context).pop();
                    }
                  },
                );
              }),
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                Offset? tapPosition;
                return GestureDetector(
                  onTapDown: (details) {
                    tapPosition = details.globalPosition;
                  },
                  child: ListTile(
                    title: Text('Crank game', style: theme.textTheme.bodyLarge),
                    subtitle: Text(
                      'A silly game about turning a crank at a consistent speed. Can you do the work of the clock?',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: trailing(SizedBox(
                      width: 26,
                      height: 26,
                      child: Hero(
                        tag: 'crank-game-icon',
                        child: ScalingAspectRatio(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.rotate_right_rounded,
                                color: theme.colorScheme.primary,
                                size: 24,
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Icon(
                                  Icons.sports_esports,
                                  color: theme.colorScheme.primary,
                                  size: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )),
                    onTap: () {
                      Navigator.push(
                        context,
                        CircularRevealRoute(
                          builder: (context) => CrankGameScreen(
                              iconKey: iconKey,
                              flipBackgroundColors:
                                  !widget.flipBackgroundColors),
                          buttonCenter: tapPosition ?? Offset.zero,
                          iconKey: iconKey,
                        ),
                      );
                    },
                    contentPadding: listItemPadding,
                  ),
                );
              }),
              Builder(builder: (context) {
                // Need a Builder to get the correct context for finding the icon's position
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title:
                      Text('About this app', style: theme.textTheme.bodyLarge),
                  trailing: trailing(SizedBox(
                    width: 26,
                    height: 26,
                    child: Hero(
                        tag: 'about-icon',
                        child: ScalingAspectRatio(
                            child: Icon(Icons.info_outline,
                                key: hereIconKey,
                                size: 10,
                                color: theme.colorScheme.primary))),
                  )),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => AboutScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title: Text('Thank the author',
                      style: theme.textTheme.bodyLarge),
                  trailing: trailing(SizedBox(
                    width: 26,
                    height: 26,
                    child: Hero(
                        tag: 'thank-author-icon',
                        child: ScalingAspectRatio(
                          child: Icon(
                            Icons.heart_broken,
                            key: hereIconKey,
                            color: theme.colorScheme.primary,
                          ),
                        )),
                  )),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => ThankAuthorScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
              if (!completedSetup) ...[
                setupTile,
              ],
            ]),
          ),
        ],
      ),
    );
  }
}

class ThankAuthorScreen extends StatelessWidget {
  final bool flipBackgroundColors;
  const ThankAuthorScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, flipBackgroundColors);
    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                      width: 32,
                      height: 32,
                      child: Hero(
                        tag: 'thank-author-icon',
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.heart_broken,
                          color: theme.colorScheme.primary,
                        )),
                      )),
                  SizedBox(width: 16),
                  Text('Thank the author',
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
            backgroundColor: backgroundColorB,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverList(
            delegate: SliverChildListDelegate(
              [
                Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Text(
                      'The audience for this app is large. Even a small payment in total would enable the author to go on to create much more ambitious projects.',
                      style: theme.textTheme.bodyLarge,
                    )),
                SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  final bool flipBackgroundColors;
  const AboutScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, flipBackgroundColors);
    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                    width: 35,
                    height: 35,
                    child: Hero(
                        tag: 'about-icon',
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.info_outline,
                          color: theme.colorScheme.primary,
                        ))),
                  ),
                  SizedBox(width: 9),
                  Text("About Mako's Timer",
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
            backgroundColor: backgroundColorB,
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

class AlarmSoundPickerScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  const AlarmSoundPickerScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  State<AlarmSoundPickerScreen> createState() => _AlarmSoundPickerScreenState();
}

class _AlarmSoundPickerScreenState extends State<AlarmSoundPickerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  List<AudioInfo>? _alarmSounds;
  List<AudioInfo>? _notificationSounds;
  List<AudioInfo>? _ringtoneSounds;
  final List<AudioInfo> _assetSounds = PlatformAudio.assetSounds;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSounds();
  }

  Future<void> _loadSounds() async {
    try {
      if (platformIsDesktop()) {
        setState(() {
          _loading = false;
        });
        return;
      } else {
        final alarmsFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.alarm);
        final notificationsFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.notification);
        final ringtonesFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.ringtone);
        final [alarms, notifications, ringtones] = await Future.wait([
          alarmsFuture,
          notificationsFuture,
          ringtonesFuture,
        ]);
        setState(() {
          _alarmSounds = alarms;
          _notificationSounds = notifications;
          _ringtoneSounds = ringtones;
          _loading = false;
        });
      }
    } catch (e) {
      print('Error loading sounds: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, widget.flipBackgroundColors);

    Widget section(String title, List<AudioInfo> sounds,
        {Duration? fadeDelay}) {
      final animDuration = Duration(milliseconds: 100);
      final totalDuration =
          fadeDelay != null ? fadeDelay + animDuration : animDuration;
      final delayFraction = fadeDelay != null
          ? fadeDelay.inMicroseconds / totalDuration.inMicroseconds
          : 0.0;

      final selectedAudio =
          Mobj.getAlreadyLoaded(selectedAudioID, const AudioInfoType());
      final jukeBox = Provider.of<JukeBox>(context, listen: false);

      Widget radioSelector(AudioInfo audio) {
        bool hasPlayed = false;
        return RadioItem<AudioInfo?>(
          equalityComparison: (AudioInfo? a, AudioInfo? b) => a?.url == b?.url,
          me: audio,
          selection: selectedAudio,
          onTap: () {
            jukeBox.pauseAudio();
            if (selectedAudio.value?.url != audio.url) {
              hasPlayed = false;
            }
            if (!hasPlayed) {
              jukeBox.playAudio(audio);
            }
            hasPlayed = !hasPlayed;
          },
          builder: (context, isOn) {
            final textTheme = isOn
                ? theme.textTheme.bodyMedium!
                    .copyWith(color: theme.colorScheme.onPrimary)
                : theme.textTheme.bodyMedium!;
            final backgroundColor = isOn
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerLowest;
            return Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(audio.name, style: textTheme));
          },
        );
      }

      return SliverToBoxAdapter(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: totalDuration,
          curve: Interval(delayFraction, 1.0, curve: Curves.linear),
          builder: (context, value, child) =>
              Opacity(opacity: value, child: child!),
          child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                        padding: EdgeInsets.fromLTRB(0, 0, 0, 7),
                        child: Text(title,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: theme.colorScheme.primary))),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: sounds
                            .map((audio) => radioSelector(audio))
                            .toList()),
                  ])),
        ),
      );
    }

    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Hero(
                      tag: 'alarm-sound-icon',
                      createRectTween: (begin, end) =>
                          DelayedRectTween(begin: begin, end: end, delay: 0.14),
                      child: ScalingAspectRatio(
                          child: Icon(
                        Icons.music_note,
                        color: theme.colorScheme.primary,
                      )),
                    ),
                  ),
                  SizedBox(width: 16),
                  Text('Alarm sound',
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
            backgroundColor: backgroundColorB,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          if (!_loading) ...[
            if (_assetSounds.isNotEmpty)
              section('Mako Timer Sounds', _assetSounds,
                  fadeDelay: Duration(milliseconds: 0)),
            if (_alarmSounds != null && _alarmSounds!.isNotEmpty)
              section('Alarms', _alarmSounds!,
                  fadeDelay: Duration(milliseconds: 100)),
            if (_notificationSounds != null && _notificationSounds!.isNotEmpty)
              section('Notifications', _notificationSounds!,
                  fadeDelay: Duration(milliseconds: 200)),
            if (_ringtoneSounds != null && _ringtoneSounds!.isNotEmpty)
              section('Ringtones', _ringtoneSounds!,
                  fadeDelay: Duration(milliseconds: 300)),
            SliverToBoxAdapter(
              child:
                  SizedBox(height: 16 + MediaQuery.of(context).padding.bottom),
            ),
          ],
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

class OnboardScreen extends StatefulWidget {
  const OnboardScreen({super.key});

  @override
  State<OnboardScreen> createState() => _OnboardScreenState();
}

const double standardSpacing = 18;
const spacer = SizedBox(width: standardSpacing, height: standardSpacing);
const double standardButtonHeight = 80;
const double buttonCornerRadius = 16;

class _OnboardScreenState extends State<OnboardScreen> with SignalsMixin {
  late ScrollController _scrollController;
  late Signal<bool?> setIsRightHanded = createSignal(null);
  final GlobalKey handednessKey = GlobalKey();
  final GlobalKey skipKey = GlobalKey();
  final GlobalKey padKey = GlobalKey();
  late List<GlobalKey> allKeys = [handednessKey, padKey, skipKey];
  late Signal<bool?> numpadOrientation = createSignal(null);
  late List<Signal<dynamic>> allChoices = [setIsRightHanded, numpadOrientation];
  late Signal<bool> allChoicesCompleted = createSignal(false);
  late async.Timer? autoMoveOn;

  @override
  void initState() {
    super.initState();
    final isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());
    createEffect(() {
      if (setIsRightHanded.value != null) {
        isRightHanded.value = setIsRightHanded.value!;
      }
    });
    createEffect(() {
      if (numpadOrientation.value != null) {
        Mobj.getAlreadyLoaded(padVerticallyAscendingID, const BoolType())
            .value = numpadOrientation.value!;
      }
    });
    //when all choices are non-null, navigate away
    createEffect(() {
      if (allChoices.every((signal) => signal.value != null)) {
        // redundant but might as well set it as soon as possible, may change it later to only set exit in moveOn
        Mobj.getAlreadyLoaded(completedSetupID, const BoolType()).value = true;
        autoMoveOn = async.Timer(Duration(milliseconds: 900), () => moveOn());
        allChoicesCompleted.value = true;
      }
    });
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    setIsRightHanded.dispose();
    numpadOrientation.dispose();
    super.dispose();
  }

  void _scrollTo(GlobalKey key) {
    Scrollable.ensureVisible(
      key.currentContext!,
      duration: const Duration(milliseconds: 700),
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      curve: Interval(0.4, 1.0, curve: Curves.easeInOutCubic),
    );
  }

  void inputCompleted(GlobalKey key) {
    // If all choices are non-null, navigate away
    final idx = allKeys.indexOf(key);
    if (idx != -1 && idx < allKeys.length - 1) {
      final nextKey = allKeys[idx + 1];
      _scrollTo(nextKey);
    }
  }

  void moveOn() {
    autoMoveOn?.cancel();
    autoMoveOn = null;
    Mobj.getAlreadyLoaded(completedSetupID, const BoolType()).value = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final backgroundColor = theme.colorScheme.surfaceContainerLow;
    final isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());

    Widget handButton({
      required bool isRight,
    }) {
      return Expanded(
        child: RadioItem<bool?>(
          selection: setIsRightHanded,
          duration: Duration(milliseconds: 370),
          me: isRight,
          onTap: () => inputCompleted(handednessKey),
          builder: (context, isOn) {
            final leftHand = Transform.rotate(
              angle: 1 / 8 * tau,
              child: Icon(Icons.back_hand_rounded,
                  size: 36, color: foregroundColorFor(theme, isOn)),
            );
            final rightHand = Transform.scale(
              scaleX: -1,
              child: leftHand,
            );
            return Container(
              height: standardButtonHeight,
              decoration: BoxDecoration(
                color: backgroundColorFor(theme, isOn),
                borderRadius: BorderRadius.circular(buttonCornerRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: isRight
                    ? [
                        Text('right',
                            style: theme.textTheme.titleMedium!.copyWith(
                                color: foregroundColorFor(theme, isOn))),
                        spacer,
                        rightHand,
                      ]
                    : [
                        leftHand,
                        spacer,
                        Text('left',
                            style: theme.textTheme.titleMedium!.copyWith(
                                color: foregroundColorFor(theme, isOn))),
                      ],
              ),
            );
          },
        ),
      );
    }

    Widget numpadForSetup(bool isAscending) {
      return RadioItem<bool?>(
        selection: numpadOrientation,
        duration: Duration(milliseconds: 370),
        onTap: () => inputCompleted(padKey),
        me: isAscending,
        builder: (context, isOn) {
          final theme = Theme.of(context);
          const double gap = 16;
          final double diameter = 132;
          return Container(
            width: diameter,
            height: diameter,
            padding: EdgeInsets.all(gap),
            decoration: BoxDecoration(
              color: backgroundColorFor(theme, isOn),
              borderRadius: BorderRadius.circular(buttonCornerRadius),
            ),
            child: _NumpadTypeIndicator(
              isAscending: isAscending,
              color: foregroundColorFor(theme, isOn),
              width: 132 - 2 * gap,
            ),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Handedness selection - full screen
          SliverToBoxAdapter(
              key: handednessKey,
              child: Container(
                  height: screenHeight,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                  ),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                            padding: EdgeInsets.all(standardSpacing),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                            ),
                            child: Text("Setup",
                                style: theme.textTheme.titleMedium)),
                        Container(
                            padding: EdgeInsets.all(standardSpacing),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                            ),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Are you left or right-handed?',
                                      style: theme.textTheme.titleMedium),
                                  SizedBox(height: standardSpacing),
                                  Row(
                                    children: [
                                      handButton(
                                        isRight: false,
                                      ),
                                      spacer,
                                      handButton(
                                        isRight: true,
                                      ),
                                    ],
                                  )
                                ]))
                      ]))),
          SliverToBoxAdapter(
              key: padKey,
              child: Container(
                  padding: EdgeInsets.all(
                    standardSpacing,
                  ),
                  child: GestureDetector(
                      onTap: () => inputCompleted(padKey),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                                "Which kind of numpad is more familiar to you?",
                                style: theme.textTheme.titleMedium!),
                            spacer,
                            Watch((context) {
                              return AnimatedAlign(
                                duration: Duration(milliseconds: 340),
                                curve: Curves.easeInOutCubic,
                                alignment: isRightHanded.value == true
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Column(
                                        children: [
                                          Text(
                                            "phone style",
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          spacer,
                                          numpadForSetup(
                                            false,
                                          ),
                                        ],
                                      ),
                                      spacer,
                                      Column(
                                        children: [
                                          Text(
                                            "calculator style",
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          spacer,
                                          numpadForSetup(
                                            true,
                                          ),
                                        ],
                                      ),
                                    ]),
                              );
                            })
                          ])))),
          // Skip button - full screen
          SliverToBoxAdapter(
              key: skipKey,
              child: Padding(
                  padding: EdgeInsets.only(
                      left: standardSpacing,
                      right: standardSpacing,
                      bottom: standardSpacing),
                  child: GestureDetector(
                      onTap: () {
                        moveOn();
                      },
                      child: Container(
                        height: standardButtonHeight,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLowest,
                          borderRadius:
                              BorderRadius.circular(buttonCornerRadius),
                        ),
                        child: Center(
                            child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                              Watch((context) => Text(
                                  allChoicesCompleted.value
                                      ? 'done, continue'
                                      : 'skip',
                                  style: theme.textTheme.titleMedium!)),
                              spacer,
                              Icon(Icons.arrow_forward_ios,
                                  size: 16, color: theme.colorScheme.primary),
                            ])),
                      )))),
        ],
      ),
    );
  }
}
