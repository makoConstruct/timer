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
              page: TimerScreen(),
            );
          }
          return null;
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
    _selectedUnderlineAnimation.value = 1;
    _deletionAnimation = AnimationController(
        duration: const Duration(milliseconds: 240), vsync: this);
    _ticker = createTicker((d) {
      setTime(durationToSeconds(DateTime.now().difference(p.startTime)));
    });
    createEffect(() {
      TimerData? d = widget.mobj.value;
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
                color: theme.colorScheme.surfaceContainerHigh,
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
              // scale: 1 + _runningAnimation.value * 3,
              scale: 1,
              child: Container(
                  decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerLowest,
              )),
            )));

    double pieRadius = 24;

    Widget clockDial = AnimatedBuilder(
        key: _clockKey,
        animation: _runningAnimation,
        builder: (context, child) => Container(
              padding:
                  EdgeInsets.all((1 - _runningAnimation.value) * timerPaddingr),
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
            expandingHindCircle,
            // there's a very strange bug where the pie doesn't repaint when the timer is being dragged. Every other animation still works. I checked, and although build is being called, shouldRepaint isn't. I'm gonna ignore it for now.
            // oh! and I notice the numbers don't update either!
            Pie(
              backgroundColor: backgroundColor(d.hue),
              color: primaryColor(d.hue),
              value: pieCompletion,
              size: pieRadius,
            ),
          ],
        ));

    Widget result = GestureDetector(
      onTap: () {
        context
            .findAncestorStateOfType<TimerScreenState>()
            ?.takeActionOn(widget.mobj.id);
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(timerPaddingr),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            clockDial,
            SizedBox(width: timerPaddingr),
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
              child: FuzzyExpandingCircle(
                originAlignX: -0.3,
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
  late final Computed<TimerWidgets> timerWidgets;

  @override
  void initState() {
    super.initState();
    wrapKey = GlobalKey();

    TimerWidgets? prev;
    bool firstListChange = true;
    timerWidgets = createComputed(() {
      TimerWidgets next = {};
      for (MobjID t in widget.mobj.value!) {
        next[t] = prev?[t] ??
            Timer(
                key: GlobalKey(),
                mobj: Mobj.getAlreadyLoaded(t, TimerDataType()),
                animateIn: !firstListChange,
                owningList: widget.mobj.id);
      }
      prev = next;
      firstListChange = false;
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

    Widget result = Container(
        // constraints: BoxConstraints(maxheight: double.infinity)
        color: widget.backgroundColor,
        child: Align(
            alignment: FractionalOffset(0.8, 1), child: timersWrapWidget));

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
class _TimerDeletionAnimation extends StatelessWidget {
  final Rect rect;
  final Widget timerWidget;
  final AnimationController controller;
  final bool direction;

  const _TimerDeletionAnimation({
    super.key,
    required this.rect,
    required this.timerWidget,
    required this.direction,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    bool isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, const BoolType()).value!;
    return Positioned(
      left: rect.left,
      top: rect.top,
      child: IgnorePointer(
        child: RunOnceAnimation(
          controller: controller,
          child: timerWidget,
          builder: (context, progress, child) {
            if (direction) {
              return Transform.translate(
                  // we can't have this, I think it causes animated_to to lag behind the clip rect
                  offset: Offset(isRightHanded ? -60 : 60, 0) *
                      Curves.easeOut.transform(progress),
                  // offset: Offset(isRightHanded ? -40 : 40, 0) * progress,
                  child: FuzzyExpandingCircle(
                    progress: 1.0 - progress,
                    invertGradient: true,
                    originRight: isRightHanded ? 10 : null,
                    originLeft: isRightHanded ? null : 10,
                    child: child!,
                  ));
            } else {
              return Transform.translate(
                  offset: Offset(0, -10 * Curves.easeOut.transform(progress)),
                  child: FuzzyExpandingCircle(
                    progress: 1.0 - progress,
                    invertGradient: true,
                    originBottom: -50,
                    originLeft: 28,
                    child: child!,
                  ));
            }
          },
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
              shaderCallback: (bounds) =>
                  FuzzyEdgeShader.createRadialRevealShader(
                bounds: bounds,
                center: Alignment(
                    (bounds.center.dx + revealCenter.dx) / bounds.size.width,
                    (bounds.center.dy + revealCenter.dy) / bounds.size.height),
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
            return buildGivenAnimationParameters(upDownAnimation.value.$1,
                upDownAnimation.value.$2, optionActivationAnimation.value);
          },
        ));
  }
}

class TimerScreenState extends State<TimerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  late final Signal<MobjID<TimerData>?> selectedTimer = Signal(null);
  late final Mobj<bool> isRightHanded =
      Mobj.getAlreadyLoaded(isRightHandedID, const BoolType());
  late final Signal<Rect> numPadBounds = Signal(Rect.zero);
  late final Signal<Offset> backingPlusCenter = Signal(Offset.zero);
  late final Signal<bool> backingPlusInhibitor;
  late AnimationController backingPlusCenterAnimation =
      AnimationController(duration: Duration(milliseconds: 190), vsync: this);
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => timerListMobj.value!;
  List<MobjID<TimerData>> peekTimers() => timerListMobj.peek()!;

  GlobalKey controlPadKey = GlobalKey();
  GlobalKey timerTrayKey = GlobalKey();
  GlobalKey<EphemeralAnimationHostState> ephemeralAnimationLayer = GlobalKey();
  final Mobj<List<MobjID<TimerData>>> timerListMobj =
      Mobj.getAlreadyLoaded(timerListID, timerListType);
  // final Mobj<List<MobjID<TimerData>>> transientTimerListMobj =
  //     Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
  final Mobj<double> nextHueMobj =
      Mobj.getAlreadyLoaded(nextHueID, const DoubleType());
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());

  @override
  void initState() {
    super.initState();
    // only inhibit the backing plus for a second if the user is new to the app
    backingPlusInhibitor = Signal(
        !Mobj.getAlreadyLoaded(hasCreatedTimerID, const BoolType()).value!);
    if (backingPlusInhibitor.value) {
      async.Timer(Duration(milliseconds: 1400), () {
        backingPlusInhibitor.value = false;
      });
    }
    final backingPlusDeployed = Computed(
        () => !backingPlusInhibitor.value && selectedTimer.value == null);
    createEffect(() {
      if (backingPlusDeployed.value) {
        backingPlusCenterAnimation.forward();
      } else {
        backingPlusCenterAnimation.reverse();
      }
    });
  }

  @override
  void dispose() {
    numPadBounds.dispose();
    backingPlusCenter.dispose();
    backingPlusInhibitor.dispose();
    selectedTimer.dispose();
    backingPlusCenterAnimation.dispose();
    super.dispose();
  }

  void takeActionOn(MobjID<TimerData> timerID) {
    //todo: take whichever action is currently highlighted
    toggleRunning(timerID, reset: false);
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
    watchSignal(context, isRightHanded)!;
    bool padVerticallyAscending = watchSignal(context,
        Mobj.getAlreadyLoaded(padVerticallyAscendingID, const BoolType()))!;

    //buttons
    final configButtonKey = GlobalKey();
    final hereConfigButtonKey = GlobalKey();
    var configButton = TimersButton(
        key: hereConfigButtonKey,
        label: Hero(
          tag: 'configButton',
          child: Icon(
            Icons.settings_rounded,
            color: theme.colorScheme.onSurface,
            size: 30,
          ),
        ),
        onPressed: () {
          Navigator.push(
            context,
            CircularRevealRoute(
              page: SettingsScreen(
                  iconKey: configButtonKey, flipBackgroundColors: false),
              buttonCenter: widgetCenter(hereConfigButtonKey),
              iconKey: configButtonKey,
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
              Flexible(child: stopPlayButton),
              Flexible(child: backspaceButton),
              // Flexible(child: pausePlayButton),
              Flexible(child: selectButton),
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
              Flexible(child: configButton),
              Flexible(child: addButton),
            ],
          ),
        ),
      ]);
    }

    final thumbSpan = Thumbspan.of(context);

    // Schedule update of numPadBounds after this frame completes
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final controlPadRenderBox =
          controlPadKey.currentContext!.findRenderObject() as RenderBox;

      Rect t = negativeInfinityRect();
      Offset? center1;
      Offset? center5;

      for (int i = 0; i < numeralKeys.length; i++) {
        // Get position relative to controlPad to avoid transform distortion from route animations
        final rect = boxRectRelativeTo(numeralKeys[i], controlPadRenderBox);
        if (rect != null) {
          t = t.expandToInclude(rect);
          if (i == 1) center1 = rect.center;
          if (i == 5) center5 = rect.center;
        }
      }

      if (t.isEmpty) {
        numPadBounds.value = Rect.fromLTRB(0, 0, 0, 0);
      } else {
        numPadBounds.value = t;
        if (center1 != null && center5 != null) {
          backingPlusCenter.value = (center1 + center5) / 2;
        }
      }
    });
    final numberPadBacking = Watch((context) {
      Rect nr = numPadBounds.value.deflate(backingIndicatorGap / 2);
      return Positioned.fromRect(
        rect: nr,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(backingIndicatorCornerRounding),
          ),
        ),
      );
    });

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
                numberPadBacking,
                // disabling this for now, consider removing the whole feature
                // backingPlusCenterWidget,
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

    final timersWidget = TimerTray(
      key: timerTrayKey,
      mobj: timerListMobj,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      icon: Icon(Icons.push_pin), // You can customize this icon
      useScrollView: true,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarContrastEnforced: false,
          systemNavigationBarDividerColor:
              theme.colorScheme.surfaceContainerLowest.withAlpha(0),
          systemNavigationBarColor:
              theme.colorScheme.surfaceContainerLowest.withAlpha(0),
          systemNavigationBarIconBrightness: theme.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: Scaffold(
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
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Flexible(flex: 1, child: timersWidget),
                      Container(
                        constraints: BoxConstraints(minWidth: double.infinity),
                        // the lower part of the screen
                        child: controls,
                      )
                    ],
                  ),
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
      if (timers().isNotEmpty) {
        deleteTimer(timers().last);
      }
    }
  }

  void deleteTimer(MobjID ki, {bool pushAside = false}) {
    // Get the timer's position and size using the globalkey, so that we can animate the exit in the EphemeralHost layer
    final tts = timerTrayKey.currentState as _TimerTrayState;
    final timerWidget = tts.timerWidgets.value[ki];
    if (timerWidget != null) {
      final timerKey = timerWidget.key as GlobalKey<TimerState>;
      final timerState = timerKey.currentState;

      assert(timerState != null && timerState.mounted);
      final renderBox = timerState!.context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        Rect tr = boxRectRelativeTo(
                timerKey,
                ephemeralAnimationLayer.currentContext!.findRenderObject()
                    as RenderBox) ??
            Rect.zero;

        // Create and add the deletion animation
        final deleteAnimation = AnimationController(
          duration: const Duration(milliseconds: 270),
          vsync: this,
        );
        deleteAnimation.forward(from: 0);
        (timerWidget.key as GlobalKey<TimerState>)
            .currentState!
            .animatedToDisabled
            .value = true;
        final deletionAnimationWidget = _TimerDeletionAnimation(
          key: UniqueKey(),
          direction: pushAside,
          rect: tr,
          timerWidget: timerWidget,
          controller: deleteAnimation,
        );

        addToEphemeralAnimatioHost(
            ephemeralAnimationLayer, deletionAnimationWidget, deleteAnimation);
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
                  Hero(
                    tag: 'configButton',
                    createRectTween: (begin, end) =>
                        DelayedRectTween(begin: begin, end: end, delay: 0.14),
                    child: Icon(
                      Icons.settings_rounded,
                      color: theme.colorScheme.onSurface,
                      size: 30,
                    ),
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
            backgroundColor: backgroundColorB,
            surfaceTintColor: backgroundColorB,
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
                        page: AlarmSoundPickerScreen(
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
                        page: AboutScreen(
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
                        page: ThankAuthorScreen(
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
    with SignalsMixin {
  List<AudioInfo>? _alarmSounds;
  List<AudioInfo>? _notificationSounds;
  List<AudioInfo>? _ringtoneSounds;
  final List<AudioInfo> _assetSounds = PlatformAudio.assetSounds;
  late final Signal<String?> _currentlyPlayingAudioID = createSignal(null);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    print("init state");
    _loadSounds();
    print("after load sounds");
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
        print("after set state");
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
      return SliverToBoxAdapter(
        child: _SectionReveal(
          fadeDelay: fadeDelay,
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
                            .map((audio) => SoundTile(
                                audio: audio,
                                selectedAudioID: selectedAudioID,
                                currentlyPlayingAudioID:
                                    _currentlyPlayingAudioID))
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

class _SectionReveal extends StatefulWidget {
  final Duration? fadeDelay;
  final Widget child;

  const _SectionReveal({
    this.fadeDelay,
    required this.child,
  });

  @override
  State<_SectionReveal> createState() => _SectionRevealState();
}

class _SectionRevealState extends State<_SectionReveal>
    with SingleTickerProviderStateMixin {
  late AnimationController _revealController;

  @override
  void initState() {
    super.initState();
    _revealController = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );

    if (widget.fadeDelay != null) {
      Future.delayed(widget.fadeDelay!, () {
        if (mounted) {
          _revealController.forward();
        }
      });
    } else {
      _revealController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FuzzyCircleReveal(
      animation: _revealController,
      originAlignX: 0,
      originTop: -70,
      fuzzyEdgeWidth: 20.0,
      child: widget.child,
    );
  }
}

class SoundTile extends StatelessWidget {
  final AudioInfo audio;
  final MobjID<AudioInfo> selectedAudioID;
  final Signal<String?> currentlyPlayingAudioID;
  const SoundTile({
    super.key,
    required this.audio,
    required this.selectedAudioID,
    required this.currentlyPlayingAudioID,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedAudioMobj =
        Mobj.getAlreadyLoaded(selectedAudioID, const AudioInfoType());
    final jukebox = Provider.of<JukeBox>(context, listen: false);

    return GestureDetector(onTap: () async {
      jukebox.pauseAudio();
      selectedAudioMobj.value = audio;
      if (currentlyPlayingAudioID.peek() == audio.uri) {
        // if you click the currently playing one a second time, it just stops it
        currentlyPlayingAudioID.value = null;
      } else {
        currentlyPlayingAudioID.value = audio.uri;
        jukebox.playAudio(audio);
      }
    }, child: Watch(
      (context) {
        final textTheme = audio.uri == selectedAudioMobj.value!.uri
            ? theme.textTheme.bodyMedium!.copyWith(
                color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w800)
            : theme.textTheme.bodyMedium!;
        final backgroundColor = audio.uri == selectedAudioMobj.value!.uri
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
    ));
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
