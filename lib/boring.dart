// the boring file is where we put things that're either self-explanatory or just small and fragmented and not very relevant to understanding the core structure of the application

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hsluv/hsluvcolor.dart';

// import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
// import 'package:flutter_soloud/flutter_soloud.dart' as sl;

import 'platform_audio.dart';
import 'main.dart' show getCachedCornerRadius;

const double tau = 2 * pi;
const double backingIndicatorCornerRounding = 25.0;
const double backingIndicatorGap = 8.0;
const double backingPlusRadius = 5.0;

bool platformIsDesktop() =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

// Using platform audio for content:// URI support (for using system ringtones)
// On Linux, uses audioplayers instead since platform_audio doesn't work there, though audioplayers doesn't work perfectly, we're not actually doing a linux target, linux is just for testing
class JukeBox {
  static final AssetSource _defaultSound =
      AssetSource('sounds/jingles_STEEL16.ogg');
  AudioPlayer? _audioPlayer; // Only used on Linux

  static JukeBox create() {
    final jukebox = JukeBox();
    if (platformIsDesktop()) {
      jukebox._audioPlayer = AudioPlayer();
    }
    return jukebox;
  }

  /// unfortunately the future doesn't represent the end of the audio playback, it actually represents the wait for the start. We should probably change that.
  Future<void> playAudio(AudioInfo a) async {
    if (platformIsDesktop()) {
      // Use audioplayers on Linux
      if (a.uri == null) {
        return;
      }

      // Convert URI to appropriate Source
      Source source;
      if (a.uri!.startsWith('asset://')) {
        // Flutter asset
        final assetPath = a.uri!.replaceFirst('asset://assets/', '');
        source = AssetSource(assetPath);
      } else if (a.uri!.startsWith('file://')) {
        // Local file
        source = DeviceFileSource(a.uri!.replaceFirst('file://', ''));
      } else {
        // Try as file path
        source = DeviceFileSource(a.uri!);
      }

      await _audioPlayer!.play(source);
    } else {
      // Use platform audio on other platforms
      await PlatformAudio.playAudio(a);
    }
  }

  Future<void> pauseAudio() async {
    if (platformIsDesktop()) {
      await _audioPlayer!.pause();
    } else {
      await PlatformAudio.pauseAudio();
    }
  }

  Future<void> playJarringSound() async {
    if (platformIsDesktop()) {
      // Use default asset sound on Linux
      await _audioPlayer!.play(_defaultSound);
    } else {
      // Get the user's actual default notification sound
      final defaultSound =
          await PlatformAudio.getDefaultAudio(PlatformAudioType.notification);
      await playAudio(defaultSound!);
    }
  }

  static void jarringSound(BuildContext context) {
    Provider.of<JukeBox>(context, listen: false).playJarringSound();
  }

  void dispose() {
    _audioPlayer?.dispose();
  }
}

Rect negativeInfinityRect() => Rect.fromLTRB(
    double.infinity, double.infinity, -double.infinity, -double.infinity);

/// information regarding a timer that we're currently monitoring/running
class TrackedTimer {
  final Mobj<TimerData> mobj;
  Timer? secondCountdownIndicatorTimer;
  Timer? triggerTimer;
  Function()? mobjUnsubscribe;

  TrackedTimer(this.mobj);

  double secondsRemaining() {
    return max(
        (mobj.value!.duration -
                    DateTime.now().difference(mobj.value!.startTime))
                .inMicroseconds
                .toDouble() /
            1000000,
        0);
  }

  void endTrackedTimer() {
    mobjUnsubscribe?.call();
    triggerTimer?.cancel();
    triggerTimer = null;
    secondCountdownIndicatorTimer?.cancel();
    secondCountdownIndicatorTimer = null;
  }
}

// class TimerTracking {
//   late JukeBox jukeBox;
//   Map<MobjID<TimerData>, TrackedTimer> trackedTimers = {};
//   void onTimerDataChanged(TrackedTimer tracked) {
//     final timer = tracked.mobj;
//     final ntp = timer.peek()!;
//     if (ntp.isRunning) {
//       tracked.triggerTimer?.cancel();
//       tracked.triggerTimer = Timer(
//           digitsToDuration(timer.peek()!.digits) -
//               DateTime.now().difference(timer.peek()!.startTime), () {
//         // trigger timer
//         Mobj.fetch(selectedAudioID, type: AudioInfoType()).then((audio) {
//           jukeBox.playAudio(audio.value!);
//         });
//         timer.value =
//             timer.value!.withChanges(runningState: TimerData.completed);
//       });
//     } else {
//       tracked.endTrackedTimer();
//       // [todo]
//       // updateRunningTimersNotification();
//     }
//   }

//   List<Function()> cleanups = [];
//   void startTracking(Mobj<List<MobjID>> listMobj) {
//     cleanups.add(listMobj.subscribe((list) {
//       for (final tid in list ?? []) {
//         Mobj.fetch(tid, type: TimerDataType())
//             .then((mobj) => enlivenTimer(mobj, jukeBox));
//       }
//     }));
//   }

//   void stopTrackingAll() {}
// }

// Old audioplayers implementation (kept for reference)
// class JukeBox {
//   static final AssetSource steel15 = AssetSource('sounds/jingles_STEEL15.ogg');
//   static final AssetSource steel16 = AssetSource('sounds/jingles_STEEL16.ogg');
//   // minor tombstone, audioplayers can't play ringtone urls. We'll have to use platform audio instead.
//   // static final UrlSource forbiddenZetaRingtone = UrlSource(
//   // 'content://media/internal/audio/media/194?title=Zeta&canonical=1');
//   // static const String jarringSound = 'assets/jarring.mp3';
//   late AudioPool jarringPlayers;
//   static Future<JukeBox> create() async {
//     return AudioPool.create(
//       source: steel16,
//       maxPlayers: 4,
//       audioContext: AudioContext(
//           android: AudioContextAndroid(
//               audioFocus: AndroidAudioFocus.gainTransient,
//               contentType: AndroidContentType.sonification,
//               usageType: AndroidUsageType.alarm),
//           iOS: AudioContextIOS(category: AVAudioSessionCategory.playAndRecord)),
//     ).then((pool) => JukeBox()..jarringPlayers = pool);
//   }
//
//   void playJarringSound() {
//     jarringPlayers.start();
//   }
//
//   static void jarringSound(BuildContext context) {
//     Provider.of<Future<JukeBox>>(context, listen: false).then((jb) {
//       jb.jarringPlayers.start();
//     });
//   }
// }

// ringtone manager is totally inadequate because it doesn't give you control over how it interacts with the currently playing sounds, and of course it gives you no control over which asset specifically is played.
// // with ringtone manager
// class JukeBox {
//   // static const String jarringSound = 'assets/jarring.mp3';
//   late FlutterRingtoneManager m;
//   JukeBox(this.m) {}
//   static Future<JukeBox> create() async {
//     return Future.value(JukeBox(FlutterRingtoneManager()));
//   }

//   void playJarringSound() {
//     m.playNotification();
//   }

//   static void jarringSound(BuildContext context) {
//     Provider.of<Future<JukeBox>>(context, listen: false).then((jb) {
//       jb.playJarringSound();
//     });
//   }
// }

// this doesn't even work on arch, trying audioplayers again
// this is different to the above, we don't create an instance of the jukebox, it's all static. Not sure why it shouldn't be. Some of the code still passes us a context we don't need, and we still initialize and instance that doesn't get used
// replace with soloud
// soloud also doesn't work with the most recent flutter nix package
// class JukeBox {
//   static final String pianoSound =
//       'sounds/jarring piano sound 448552__tedagame__g4.ogg';
//   static final String steel15 = 'sounds/jingles_STEEL15_kenney.ogg';
//   static final String forcefield = 'sounds/forceField_002_kenney.ogg';
//   static final Future<sl.AudioSource> briefSound =
//       soloud.then((s) => s.loadAsset(steel15));
//   static final Future<sl.SoLoud> soloud = Future.microtask(() {
//     WidgetsFlutterBinding.ensureInitialized();
//     final r = sl.SoLoud.instance;
//     r.init();
//     return r;
//   });

//   static Future<JukeBox> create() async {
//     return Future.value(JukeBox());
//   }

//   static void jarringSound(BuildContext contex) {
//     soloud.then((s) {
//       briefSound.then((so) {
//         s.play(so);
//       });
//     });
//   }
// }

// mock
// class JukeBox {
//   // static final String pianoSound =
//   //     'sounds/jarring piano sound 448552__tedagame__g4.ogg';
//   // static final String steel15 = 'sounds/jingles_STEEL15_kenney.ogg';
//   // static final String forcefield = 'sounds/forceField_002_kenney.ogg';

//   static Future<JukeBox> create() async {
//     return Future.value(JukeBox());
//   }

//   static void jarringSound(BuildContext contex) {
//     // ideally there'd be a visual indicator when the sound is made
//   }
// }

Rect? boxRect(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) {
    return null;
  } else {
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

// disabled because it couldn't find its plugin .so, see pubspec
// class SoloudJukebox {
//   late Future<SL.AudioSource> forcefield;
//   SoloudJukebox() {
//     final si = SL.SoLoud.instance;
//     forcefield = si.loadAsset('sounds/forceField_002_kenney.ogg');
//   }

//   static void jarringSound(BuildContext context) {
//     context.read<SoloudJukebox>().forcefield.then((f) {
//       SL.SoLoud.instance.play(f);
//     });
//   }
// }

/// only defers once, assumes it'll be there on the next frame
void getStateMaybeDeferring<T extends State>(
    GlobalKey<T> k, void Function(T) to) {
  final tk = k.currentState;
  if (tk == null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      to(k.currentState!);
    });
  } else {
    to(tk);
  }
}

/// a FutureBuilder that basically assumes it wont have to show a loading image, and has a way of displaying errors.
/// shows a red screen on error or during loading. (I'll probably change the loading behavior)
class FutureAssumer<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  const FutureAssumer({super.key, required this.future, required this.builder});
  @override
  build(BuildContext context) => FutureBuilder(
      future: future,
      builder: (context, snapshot) {
        final theme = Theme.of(context);
        return snapshot.hasError
            ? Container(
                color: theme.colorScheme.errorContainer,
                child: Text(snapshot.error.toString()))
            : snapshot.hasData
                ? builder(context, snapshot.data as T)
                : Container(color: theme.colorScheme.errorContainer);
      });
}

class DraggableWidget<T> extends StatefulWidget {
  final Widget child;
  final T? data;
  const DraggableWidget({super.key, required this.child, this.data});
  @override
  State<DraggableWidget> createState() => _DraggableWidgetState();
}

Duration normalizeDuration(Duration duration, Duration interval) {
  final totalMs = duration.inMicroseconds;
  final intervalMs = interval.inMicroseconds;
  // Proper modulo that handles negatives: ((n % m) + m) % m
  final normalizedMs = ((totalMs % intervalMs) + intervalMs) % intervalMs;
  return Duration(microseconds: normalizedMs);
}

class PeriodicTimerFromEpoch implements Timer {
  final Duration period;

  /// epoch is allowed to be in the past, we'll correctly trigger on the modulo since then
  final DateTime epoch;
  final Function(Timer) callback;
  Timer? firstTickTimer;
  Timer? periodicTimer;
  PeriodicTimerFromEpoch(
      {required this.period, required this.epoch, required this.callback}) {
    firstTickTimer =
        Timer(normalizeDuration(epoch.difference(DateTime.now()), period), () {
      firstTickTimer = null;
      periodicTimer = Timer.periodic(period, (timer) {
        callback(this);
      });
    });
  }

  @override
  bool get isActive => true;

  @override
  int get tick => periodicTimer?.tick ?? 0;

  @override
  void cancel() {
    firstTickTimer?.cancel();
    periodicTimer?.cancel();
    periodicTimer = null;
  }
}

List<T> generatedReverseIfNot<T>(
    bool condition, int length, T Function(int) generator) {
  return condition
      ? List.generate(length, (i) => generator(i))
      : List.generate(length, (i) => generator(length - i - 1));
}

void moveAnimationTowardsState(AnimationController animation, bool forward) {
  if (forward) {
    animation.forward();
  } else {
    animation.reverse();
  }
}

// automatically removes children when the associated animation is dismissed
class EphemeralAnimationHost extends StatefulWidget {
  final List<Widget> children;
  final Widget Function(List<Widget>, BuildContext) builder;
  const EphemeralAnimationHost(
      {super.key, this.children = const [], required this.builder});
  @override
  State<EphemeralAnimationHost> createState() => EphemeralAnimationHostState();
}

class EphemeralAnimationHostState extends State<EphemeralAnimationHost> {
  List<Widget> ephemeralChildren = [];

  /// adds a child to this that's removed when the animation completes
  void add(Widget child, Animation animation) {
    ephemeralChildren.add(child);
    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          ephemeralChildren.remove(child);
        });
      }
    });
  }

  /// use this when the animation completion isn't really the trigger of removal. In this case, you might wonder what EphemeralAnimationHost is even providing, but imo what it provides is a State type that helps you find the right removal host when you do the removal.
  void addWithoutAutomaticRemoval(Widget child) {
    setState(() {
      ephemeralChildren.add(child);
    });
  }

  bool remove(Widget child) {
    if (ephemeralChildren.remove(child)) {
      setState(() {});
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(widget.children + ephemeralChildren, context);
  }
}

void addToEphemeralAnimatioHost(
    GlobalKey key, Widget child, Animation animation) {
  (key.currentState! as EphemeralAnimationHostState).add(child, animation);
}

//produces a drag anchor strategy that captures the offset of the drag start so that we can animate from it.
DragAnchorStrategy dragAnchorStrategy(ValueNotifier<Offset> dragStartOffset) =>
    (Draggable<Object> draggable, BuildContext context, Offset position) {
      dragStartOffset.value =
          (context.findRenderObject() as RenderBox).globalToLocal(position);
      return Offset.zero;
    };

class _DraggableWidgetState<T extends Object> extends State<DraggableWidget<T>>
    with TickerProviderStateMixin {
  final previousSize = ValueNotifier<Size>(Size.zero);
  final dragStartOffset = ValueNotifier<Offset>(Offset.zero);
  late final AnimationController popAnimation;
  @override
  void initState() {
    super.initState();
    popAnimation =
        AnimationController(vsync: this, duration: Duration(milliseconds: 100));
  }

  @override
  Widget build(BuildContext context) {
    // don't really need this to be a valuelisteable, but it's easier for dragAnchorStrategy to pass it to us through that
    return ValueListenableBuilder(
      valueListenable: dragStartOffset,
      builder: (context, offset, child) {
        return ValueListenableBuilder(
          valueListenable: previousSize,
          builder: (context, size, child) {
            return LongPressDraggable<T>(
                delay: Duration(milliseconds: 180),
                data: widget.data,
                // this parameter isn't really supposed to do a mutation when called, but I don't know how else to get the touch point offset
                dragAnchorStrategy: dragAnchorStrategy(dragStartOffset),
                // the Material is a workaround for https://github.com/flutter/flutter/issues/39379
                feedback: Material(
                  color: Colors.transparent,
                  child: AnimatedBuilder(
                    animation: popAnimation,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: lerpOffset(
                                -dragStartOffset.value,
                                -sizeToOffset(previousSize.value / 2),
                                popAnimation.value) +
                            Offset(
                                0,
                                Curves.easeInOut.transform(popAnimation.value) *
                                    20),
                        child: widget.child,
                      );
                    },
                  ),
                ),
                onDragStarted: () {
                  previousSize.value = context.size ?? Size(30, 30);
                  popAnimation.forward(from: 0);
                },
                // onDragEnd: (details) {
                // },
                childWhenDragging:
                    SizedBox(width: size.width, height: size.height),
                child: widget.child);
          },
        );
      },
    );
  }

  @override
  void dispose() {
    previousSize.dispose();
    super.dispose();
  }
}

Offset widgetCenter(GlobalKey k) {
  final cpro = k.currentContext?.findRenderObject() as RenderBox?;
  if (cpro == null) {
    return Offset.zero;
  }
  return cpro.localToGlobal(Offset.zero) + sizeToOffset(cpro.size / 2);
}

class EnspiralPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    // Top half circle (full width)
    final Path topPath = Path()
      ..moveTo(0, size.height / 2)
      ..arcTo(
        Rect.fromLTWH(0, 0, size.width, size.height),
        pi,
        pi,
        false,
      )
      ..lineTo(size.width, size.height / 2)
      ..close();

    // Bottom half circle (smaller and right-justified)
    final double bottomWidth = size.width * 0.86; // 80% of the full width
    final double bottomOffset = size.width - bottomWidth; // Right justify
    final Path bottomPath = Path()
      ..moveTo(bottomOffset, size.height / 2)
      ..arcTo(
        Rect.fromLTWH(bottomOffset, bottomOffset / 2, bottomWidth, bottomWidth),
        pi,
        -pi,
        false,
      )
      ..lineTo(size.width, size.height / 2)
      ..close();

    canvas.drawPath(topPath, paint);
    canvas.drawPath(bottomPath, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

/// Calculates the angle in radians from the center point to the given point.
/// The angle is measured clockwise from the positive x-axis.
double angleFrom(Offset from, Offset to) {
  return offsetAngle(to - from);
}

Offset angleToOffset(double angle) {
  return Offset(cos(angle), sin(angle));
}

Offset orthClockwise(Offset v) {
  return Offset(-v.dy, v.dx);
}

double offsetAngle(Offset offset) {
  return atan2(offset.dy, offset.dx);
}

/// Converts a Size to an Offset by using the width as x and height as y.
Offset sizeToOffset(Size size) {
  return Offset(size.width, size.height);
}

/// Calculates the shortest angle distance between two angles in radians.
double shortestAngleDistance(double from, double to) {
  double diff = ((to % tau) - (from % tau)) % tau;
  return diff <= pi ? diff : -(tau - diff);
}

// (double, double) bothAngleDifferences(double from, double to) {
//   double a = to - from;
//   double b = from - to;
//   return (a, b);
// }

double lerp(double a, double b, double t) {
  return a + (b - a) * t;
}

Offset lerpOffset(Offset a, Offset b, double t) {
  return Offset(lerp(a.dx, b.dx, t), lerp(a.dy, b.dy, t));
}

/// ceilab is better for interpollation but in most cases it doesn't matter and also the cielab library I tried seemed to have compilation errros in it
Color lerpColor(Color a, Color b, double t) {
  return Color.from(
    alpha: lerp(a.a, b.a, t),
    red: lerp(a.r, b.r, t),
    green: lerp(a.g, b.g, t),
    blue: lerp(a.b, b.b, t),
  );
}

Color darkenColor(Color c, double amount) {
  final hsl = HSLuvColor.fromColor(c);
  return hsl.addLightness(-amount * 100).toColor();
}

Color grey(double v) {
  final vo = (255 * v).toInt();
  return Color.fromARGB(255, vo, vo, vo);
}

double unlerp(double a, double b, double t) {
  return (t - a) / (b - a);
}

/// the inverse of lerp, clamped to 0-1. returns how far along the travel between a and b t is.
double unlerpUnit(double a, double b, double t) {
  return clampUnit(unlerp(a, b, t));
}

double clampUnit(double t) {
  if (t < 0) {
    return 0;
  } else if (t > 1) {
    return 1;
  } else {
    return t;
  }
}

double clampDouble(double t, double min, double max) {
  if (t < min) {
    return min;
  } else if (t > max) {
    return max;
  } else {
    return t;
  }
}

double moduloProperly(double t, double m) {
  return ((t % m) + m) % m;
}

/// tracks two components, a rise time and a fall time. Sometimes you want an animation to look different on the way down. Use the second component (the falling one) of the animation value to smoothly overrule the rising component so that there's no stutter or interruption when the animation changes direction. However, when the animation goes from falling to rising, there will be a discontinuity.
/// when you call forward(), the rise component will start to move towards 1. When you call reverse(), the fall component will start to move towards 1. The next time you call forward, the rise component will start from roughly min(rise, fall), and the fall component will be 0.
class UpDownAnimationController extends ValueListenable<(double, double)>
    with ChangeNotifier
    implements Animation<(double, double)> {
  DateTime? _riseTime;
  DateTime? _fallTime;
  final Duration riseDuration;
  final Duration fallDuration;
  final List<AnimationStatusListener> _statusListeners = [];
  AnimationStatus _lastStatus = AnimationStatus.dismissed;
  late final Ticker _ticker;

  UpDownAnimationController({
    required this.riseDuration,
    required this.fallDuration,
    required TickerProvider vsync,
  }) {
    _ticker = vsync.createTicker(_tick);
  }

  void _tick(Duration elapsed) {
    notifyListeners();
    _updateStatus();

    // Stop ticker when animation completes
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _ticker.stop();
    }
  }

  void forward({double? from}) {
    if (_riseTime == null) {
      _riseTime = DateTime.now();
      if (from != null) {
        _riseTime = DateTime.now().subtract(Duration(
            milliseconds: (from * riseDuration.inMilliseconds).toInt()));
      }
    } else {
      // tries to start from where it currently is.
      double riseProgress =
          durationToSeconds(DateTime.now().difference(_riseTime!));
      double fallProgress = _fallTime != null
          ? durationToSeconds(DateTime.now().difference(_fallTime!))
          : 0;
      double forwardPosition = max(
          0,
          min(
                  riseProgress,
                  durationToSeconds(riseDuration) -
                      fallProgress /
                          durationToSeconds(fallDuration) *
                          durationToSeconds(riseDuration)) /
              durationToSeconds(riseDuration));
      _riseTime = DateTime.now().subtract(secondsToDuration(forwardPosition));
    }
    _fallTime = null;
    if (!_ticker.isActive) {
      _ticker.start();
    }
    notifyListeners();
    _updateStatus();
  }

  void reverse() {
    // do nothing if already falling
    if (_fallTime != null) {
      return;
    }
    _fallTime = DateTime.now();
    if (!_ticker.isActive) {
      _ticker.start();
    }
    notifyListeners();
    _updateStatus();
  }

  void reset() {
    _riseTime = null;
    _fallTime = null;
    _ticker.stop();
    notifyListeners();
    _updateStatus();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  (double, double) get value {
    final now = DateTime.now();

    double riseValue = 0.0;
    if (_riseTime != null) {
      final elapsed = now.difference(_riseTime!);
      riseValue = clampUnit(elapsed.inMicroseconds.toDouble() /
          riseDuration.inMicroseconds.toDouble());
    }

    double fallValue = 0.0;
    if (_fallTime != null) {
      final elapsed = now.difference(_fallTime!);
      fallValue = clampUnit(elapsed.inMicroseconds.toDouble() /
          fallDuration.inMicroseconds.toDouble());
    }

    return (riseValue, fallValue);
  }

  @override
  AnimationStatus get status {
    if (_fallTime != null) {
      final elapsed = DateTime.now().difference(_fallTime!);
      if (elapsed >= fallDuration) {
        return AnimationStatus.dismissed;
      }
      return AnimationStatus.reverse;
    }

    if (_riseTime != null) {
      final elapsed = DateTime.now().difference(_riseTime!);
      if (elapsed >= riseDuration) {
        return AnimationStatus.completed;
      }
      return AnimationStatus.forward;
    }

    return AnimationStatus.dismissed;
  }

  void _updateStatus() {
    final newStatus = status;
    if (newStatus != _lastStatus) {
      _lastStatus = newStatus;
      for (final listener in _statusListeners.toList()) {
        listener(newStatus);
      }
    }
  }

  @override
  void addStatusListener(AnimationStatusListener listener) {
    _statusListeners.add(listener);
  }

  @override
  void removeStatusListener(AnimationStatusListener listener) {
    _statusListeners.remove(listener);
  }

  @override
  bool get isAnimating =>
      status == AnimationStatus.forward || status == AnimationStatus.reverse;

  @override
  bool get isCompleted => status == AnimationStatus.completed;

  @override
  bool get isDismissed => status == AnimationStatus.dismissed;

  @override
  bool get isForwardOrCompleted =>
      status == AnimationStatus.forward || status == AnimationStatus.completed;

  @override
  String toStringDetails() {
    final (rise, fall) = value;
    return '${super.toString()} rise: ${rise.toStringAsFixed(3)}, fall: ${fall.toStringAsFixed(3)}, $status';
  }

  @override
  Animation<U> drive<U>(Animatable<U> child) {
    return child.animate(_UpDownToDoubleAdapter(this));
  }
}

/// Adapter that converts Animation<(double, double)> to Animation<double>
/// by computing min(rise, 1 - fall)
class _UpDownToDoubleAdapter extends Animation<double>
    with AnimationWithParentMixin<(double, double)> {
  _UpDownToDoubleAdapter(this.parent);

  @override
  final Animation<(double, double)> parent;

  @override
  double get value {
    final (rise, fall) = parent.value;
    return min(rise, 1 - fall);
  }
}

const List<int> datetimeSectionLengths = [2, 2, 2, 3, 4];
const List<int> datetimeSectionOffsets = [0, 2, 4, 6, 9];
const List<int> datetimeMaxima = [60, 60, 24, 365];

const appName = "mako timer";

/// I'm not sure users really want an explanation. For an explanation to be present suggests that the user ought to read it, which is an unnecessary imposition.
const foregroundNotificationText = "";

int padLevelFor(int digitLength) {
  return datetimeSectionOffsets.indexWhere((s) => s >= digitLength);
}

/// if d is greater than the number of given padLevel, eg, if it's 25 hours and place is 3 (which means show seconds, minutes and hours), it will still automatically show 1 day, 1 hour, and zero minutes and seconds. padLevel is for making sure enough places are shown in numbers that are too low.
String formatTime(List<int> digits, {int padLevel = 0}) {
  String ret = "";
  // the index of the next digit to be printe
  int underLevel = max(
      0,
      max(padLevel - 1,
          datetimeSectionOffsets.lastIndexWhere((s) => s < digits.length)));
  int di = max(
          underLevel + 1 < datetimeSectionOffsets.length
              ? datetimeSectionOffsets[underLevel + 1]
              : digits.length,
          digits.length) -
      1;

  underLevel = max(padLevel, underLevel);
  while (di >= 0) {
    if (di < datetimeSectionOffsets[underLevel]) {
      --underLevel;
      ret += ":";
    }
    if (di < digits.length) {
      ret += digits[digits.length - di - 1].toString();
    } else {
      ret += "0";
    }
    --di;
  }
  return ret;
}

///returns the index of the angleRadius segment that angle intersects, otherwise, returns -1
int radialDragResult(List<double> angleRadius, double angle,

    /// hitspan is the span of the radial drag targets, if a drag is within this span, it will be considered a hit.
    {double hitSpan = double.infinity}) {
  int closestAngle = -1;
  double closestDistance = double.infinity;
  for (int i = 0; i < angleRadius.length; i++) {
    final angleCenter = angleRadius[i];
    double d = shortestAngleDistance(angleCenter, angle);
    if (d.abs() <= hitSpan / 2 && d.abs() < closestDistance) {
      closestAngle = i;
      closestDistance = d.abs();
    }
  }
  return closestAngle;
}

// assumes angle is in [0, tau)
double flipAngleHorizontally(double angle) =>
    angle < pi ? pi - angle : tau - (angle - pi);

T getReversedIfNot<T>(bool condition, List<T> list, int index) =>
    !condition ? list[index] : list[list.length - index - 1];

T conditionallyApplyIf<T>(bool condition, T Function(T) function, T value) =>
    condition ? function(value) : value;

// format is highest significance digit to lowest significance digit, the order in which they'd be typed or displayed
void pushDigits(List<int> digitsOut, int number, int digitsInSection,
    {int base = 10, bool indefinite = false}) {
  int digitsWritten;
  if (!indefinite) {
    if (number > pow(base, digitsInSection)) {
      throw ArgumentError(
          "number exceeds the max number of digits assigned for this digit slot");
    }
    digitsWritten = digitsInSection;
    for (int i = 0; i < digitsInSection; i++) {
      int cp = pow(base, digitsInSection - i - 1).toInt();
      digitsOut.add(number ~/ cp);
      number = number % cp;
    }
  } else {
    // indefinite
    digitsWritten = 0;
    while (number > 0) {
      digitsOut.add(number % base);
      ++digitsWritten;
      number = number ~/ base;
    }
    // Since this was adding digits from least to most significant, we need to reverse them to get the correct order
    // the reason it had to do it in that order is that we don't know how many digits there were going to be, unlike in the below
    int start = digitsOut.length - digitsWritten;
    int end = digitsOut.length - 1;
    while (start < end) {
      int temp = digitsOut[start];
      digitsOut[start] = digitsOut[end];
      digitsOut[end] = temp;
      start++;
      end--;
    }
  }
}

Function() cancellableFutureThen<T>(Future<T> future, Function(T) then) {
  bool cancelled = false;
  future.then((value) {
    if (!cancelled) {
      then(value);
    }
  }).catchError((error) {
    if (!cancelled) {
      throw error;
    }
  });
  return () {
    cancelled = true;
  };
}

/// where padLevel is the number of figures to include as 0 values if the duration isn't really that long
List<int> durationToDigits(double d, {int padLevel = 1}) {
  List<int> digits = [];
  bool started = false;
  Duration dur = Duration(microseconds: (d * 1000000).toInt());
  int days = dur.inDays;
  // Years
  if (days >= 365 || padLevel > 4) {
    pushDigits(digits, days ~/ 365, 4, indefinite: true);
    days = days % 365;
    started = true;
  }
  // Days
  if (started || days > 0 || padLevel > 3) {
    pushDigits(digits, days, 3);
    started = true;
  }
  // Hours
  if (started || dur.inHours % 24 > 0 || padLevel > 2) {
    pushDigits(digits, dur.inHours % 24, 2);
    started = true;
  }
  // Minutes
  if (started || dur.inMinutes % 60 > 0 || padLevel > 1) {
    pushDigits(digits, dur.inMinutes % 60, 2);
    started = true;
  }
  // Seconds
  if (started || dur.inSeconds % 60 > 0 || padLevel > 0) {
    pushDigits(digits, dur.inSeconds % 60, 2);
  }

  return digits;
}

/// in seconds, computed from digits
Duration digitsToDuration(List<int> digits) {
  if (digits.isEmpty) {
    return Duration.zero;
  }

  int seconds = 0;
  int i = digits.length - 1;

  // seconds
  int secondsi = 0;
  while (i >= 0 && secondsi < 2) {
    seconds += digits[i] * pow(10, secondsi).toInt();
    ++secondsi;
    --i;
  }
  // minutes
  int minutesi = 0;
  while (i >= 0 && minutesi < 2) {
    seconds += digits[i] * 60 * pow(10, minutesi).toInt();
    ++minutesi;
    --i;
  }
  // hours
  int hoursi = 0;
  while (i >= 0 && hoursi < 2) {
    seconds += digits[i] * 60 * 60 * pow(10, hoursi).toInt();
    ++hoursi;
    --i;
  }
  // days
  int daysi = 0;
  while (i >= 0 && daysi < 3) {
    seconds += digits[i] * 60 * 60 * 24 * pow(10, daysi).toInt();
    ++daysi;
    --i;
  }
  // years
  int yearsi = 0;
  while (i >= 0) {
    seconds += digits[i] * 60 * 60 * 24 * 365 * pow(10, yearsi).toInt();
    ++yearsi;
    --i;
  }

  return Duration(seconds: seconds);
}

double durationToSeconds(Duration v) {
  return v.inMicroseconds / 1000000;
}

Duration secondsToDuration(double v) {
  return Duration(microseconds: (v * 1000000).toInt());
}

/// the number of logical pixels per degree, like, from the user's eye, a degree over from the center of the screen, the number of pixels that would be in that arc. This is *the* salient metric for deciding how big to make things, logical pixels are *supposed* to track along with it, but they're actually wildly inaccurate so we might want a better metric at some point.
double lpixPerDegree(BuildContext context) {
  return 30;
}

double lpixPerMM(BuildContext context) {
  // consider using a package like device_info, or millimeters

  // final dpi = MediaQuery.devicePixelRatioOf(context);
  // final s = MediaQuery.sizeOf(context);
  // return s.width / mm * 25.4 * dpi;
  // return px / mm * 25.4 * dpi;

  // source: https://api.flutter.dev/flutter/dart-ui/FlutterView/devicePixelRatio.html
  final double officialValue = 3.8;
  final double samsungS9PlusValue = 411.4 / 70; // = 5.877
  return samsungS9PlusValue;
}

void considerUpdating<T, P>(T? prev, T next, P Function(T) property,
    void Function({required T? from, required T to}) update) {
  if (prev == null || property(prev) != property(next)) {
    update(from: prev, to: next);
  }
}

/// the span of the user's thumbtip in logical pixels. Defaults to 17mm*lpixPerMM (the span of mako's thumb on a samsung s9+)
/// use this when you're thinking about touch ergonomics, like, how big should a button be? How accurately can the user click things? How far should they have to drag before something will activate?
double lpixPerThumbspan(BuildContext context) {
  // todo: get device info and provide upper and lower bounds using those
  return 17 * lpixPerMM(context);
}

List<int> stripZeroes(List<int> digits) {
  int i = 0;
  while (i < digits.length && digits[i] == 0) {
    i++;
  }
  return digits.sublist(i);
}

void testTimeConversions() {
  final sd = Duration(days: 1 + 20173 * 365, hours: 2, minutes: 3, seconds: 4);
  final int padLevel = 3;
  List<int> digits =
      durationToDigits(durationToSeconds(sd), padLevel: padLevel);
  String formatted = formatTime(digits, padLevel: padLevel);
  assert(formatted == '20173:001:02:03:04');

  final d = Duration(days: 1 + 2017 * 365, hours: 2, minutes: 3, seconds: 4);
  final ndigits = durationToDigits(durationToSeconds(d));
  final convertedBack = digitsToDuration(ndigits);
  assert(d == convertedBack);
}

double sq(double p) => p * p;
double easeOut(double p) => 1 - sq(1 - p);
double easeIn(double p) => sq(p);
double bounceCurve(double p) => (1 - sq((p - 0.5) * 2)) * (1 - easeIn(p));
const double _bumpMidpoint = 0.17;
double defaultPulserFunction(double v) => v < _bumpMidpoint
    ? sq(v / _bumpMidpoint)
    : 1 - (v - _bumpMidpoint) / (1 - _bumpMidpoint);

class PiePainter extends CustomPainter {
  final double value;
  final Color color;

  PiePainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Draw filled portion
    if (value > 0) {
      final fillPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      // Convert value to sweepAngle (in radians)
      final sweepAngle = 2 * 3.14159 * value;

      // Draw the pie segment
      canvas.drawArc(
        rect,
        -3.14159 / 2, // Start from top (negative PI/2)
        sweepAngle,
        true,
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(PiePainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.color != color;
  }
}

List<T> reverseIfNot<T>(bool condition, List<T> list) =>
    !condition ? list.reversed.toList() : list;

class SweepGradientCirclePainter extends CustomPainter {
  final Color a;
  final Color b;
  final double angle;
  final double holeRadius;
  SweepGradientCirclePainter(
    this.a,
    this.b, {
    this.angle = 0,
    this.holeRadius = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final double blurAngle = 0.007;
    final hc = Color.lerp(a, b, 0.5)!;
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [hc, a, b, hc],
        stops: [0.0, blurAngle, 1.0 - blurAngle, 1.0],
        tileMode: TileMode.mirror,
        transform: GradientRotation(angle),
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    final Path path = Path();

    // Add outer circle
    path.addOval(rect);

    // If holeRadius is greater than 0, create a hole in the center
    if (holeRadius > 0) {
      // Add inner circle (the hole)
      path.addOval(Rect.fromCircle(
        center: center,
        radius: radius * holeRadius,
      ));

      // Use even-odd fill type to create the hole effect
      path.fillType = PathFillType.evenOdd;
    }

    // Draw the path with the gradient
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(SweepGradientCirclePainter oldDelegate) {
    return oldDelegate.a != a ||
        oldDelegate.b != b ||
        oldDelegate.angle != angle ||
        oldDelegate.holeRadius != holeRadius;
  }
}

class Pie extends StatelessWidget {
  final double value;
  final Color backgroundColor;
  final Color color;
  final double size;

  const Pie({
    super.key,
    required this.value,
    required this.backgroundColor,
    required this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          CustomPaint(
            // size: Size(size, size),
            painter: PiePainter(
              value: 1.0, // Full circle for the background
              color: backgroundColor,
            ),
          ),
          CustomPaint(
            // size: Size(size, size),
            painter: PiePainter(
              value: value.clamp(0.0, 1.0),
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class DragIndicatorPainter extends CustomPainter {
  final Color color;
  final double radius;

  DragIndicatorPainter({
    required this.color,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final Path path = Path();
    path.moveTo(-radius, 0);
    path.lineTo(0, -radius);
    path.lineTo(radius, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(DragIndicatorPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

int? recognizeDigitPress(LogicalKeyboardKey k) {
  switch (k) {
    case LogicalKeyboardKey.digit0:
      return 0;
    case LogicalKeyboardKey.digit1:
      return 1;
    case LogicalKeyboardKey.digit2:
      return 2;
    case LogicalKeyboardKey.digit3:
      return 3;
    case LogicalKeyboardKey.digit4:
      return 4;
    case LogicalKeyboardKey.digit5:
      return 5;
    case LogicalKeyboardKey.digit6:
      return 6;
    case LogicalKeyboardKey.digit7:
      return 7;
    case LogicalKeyboardKey.digit8:
      return 8;
    case LogicalKeyboardKey.digit9:
      return 9;
    default:
      return null;
  }
}

double calcMaxRadiusForPointWithinRectangle(Size size, Offset center) {
  final w = max(center.dx, size.width - center.dx);
  final h = max(center.dy, size.height - center.dy);
  return sqrt(w * w + h * h);
}

/// Circular reveal clipper adapted from circular_reveal_animation package
/// Copyright 2021 Alexander Zhdanov
/// Licensed under Apache 2.0: http://www.apache.org/licenses/LICENSE-2.0
/// Custom clipper for circular/oval reveal effect. Circle grows/shrinks from a center point.
class CircularRevealClipper extends CustomClipper<Path> {
  final double fraction;
  final Alignment? centerAlignment;
  final Offset? centerOffset;
  final double? minRadius;
  final double? maxRadius;

  CircularRevealClipper({
    required this.fraction,
    this.centerAlignment,
    this.centerOffset,
    this.minRadius,
    this.maxRadius,
  });

  @override
  Path getClip(Size size) {
    final Offset center = centerAlignment?.alongSize(size) ??
        centerOffset ??
        Offset(size.width / 2, size.height / 2);
    final minRadius = this.minRadius ?? 0;
    final maxRadius =
        this.maxRadius ?? calcMaxRadiusForPointWithinRectangle(size, center);

    return Path()
      ..addOval(
        Rect.fromCircle(
          center: center,
          radius: lerp(minRadius, maxRadius, fraction),
        ),
      );
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => true;
}

/// Custom page route that combines circular reveal animation with translation
class CircularRevealRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  final Widget page;
  final Offset? buttonCenter;
  final GlobalKey? iconKey;

  CircularRevealRoute({
    required this.page,
    this.buttonCenter,
    this.iconKey,
  });

  @override
  Widget buildContent(BuildContext context) => page;

  @override
  bool get opaque => animation?.isCompleted ?? false;

  // Force our own duration, don't let mixin override it
  @override
  Duration get transitionDuration => const Duration(milliseconds: 350);

  @override
  Duration get reverseTransitionDuration => Duration(milliseconds: 350);

  @override
  bool get maintainState => true;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => true;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // Incorporate screen corner scale-down with secondaryAnimation,
    // and primary animation is still circular reveal.
    return AnimatedBuilder(
      animation: secondaryAnimation,
      builder: (context, child_) {
        final corners = getCachedCornerRadius();
        double scale;
        if (platformIsDesktop()) {
          scale = 1.0;
        } else {
          scale =
              1.0 - Curves.easeOut.transform(secondaryAnimation.value) * 0.13;
        }

        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(corners.topLeft),
              topRight: Radius.circular(corners.topRight),
              bottomLeft: Radius.circular(corners.bottomLeft),
              bottomRight: Radius.circular(corners.bottomRight),
            ),
            child: _CircularRevealTransition(
              animation: animation,
              transitionOrigin: buttonCenter ?? Offset.zero,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Route for pages that should clip to screen corners and scale when covered
class ScreenCornerClippedRoute extends MaterialPageRoute {
  ScreenCornerClippedRoute({required super.builder});

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // First apply default MaterialPageRoute transition
    // final materialTransition =
    //     super.buildTransitions(context, animation, secondaryAnimation, child);

    // When another route is pushed on top, clip to screen corners and scale down
    return AnimatedBuilder(
      animation: secondaryAnimation,
      builder: (context, child) {
        if (secondaryAnimation.value == 0.0) {
          return child!;
        }
        final corners = getCachedCornerRadius();
        final double scale;
        if (platformIsDesktop()) {
          // scale animations look bad on desktop
          scale = 1.0;
        } else {
          scale =
              1.0 - Curves.easeIn.transform(secondaryAnimation.value) * 0.13;
        }
        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(corners.topLeft),
              topRight: Radius.circular(corners.topRight),
              bottomLeft: Radius.circular(corners.bottomLeft),
              bottomRight: Radius.circular(corners.bottomRight),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class FuzzyEdgeShader {
  /// Creates a radial gradient shader with a fuzzy edge for circular reveal effects
  static Shader createRadialRevealShader({
    required Rect bounds,

    /// relative to bounds origin
    required Offset center,
    required double fraction,
    double fuzzyEdgeWidth = 20.0,
    double? maxRadius,
  }) {
    final calculatedMaxRadius = maxRadius ??
        (calcMaxRadiusForPointWithinRectangle(bounds.size, center) +
            fuzzyEdgeWidth);
    final currentRadius = calculatedMaxRadius * fraction;

    return RadialGradient(
      center: Alignment(
        (center.dx / bounds.width) * 2 - 1,
        (center.dy / bounds.height) * 2 - 1,
      ),
      radius: currentRadius / min(bounds.width, bounds.height),
      colors: const [
        Colors.white,
        Colors.white,
        Colors.transparent,
      ],
      stops: [
        0.0,
        max(0.0, currentRadius / (currentRadius + fuzzyEdgeWidth)),
        1.0,
      ],
    ).createShader(bounds);
  }
}

class _CircularRevealTransition extends StatefulWidget {
  final Animation<double> animation;
  final Offset transitionOrigin;

  final Widget child;

  const _CircularRevealTransition({
    required this.animation,
    required this.transitionOrigin,
    required this.child,
  });

  @override
  State<_CircularRevealTransition> createState() =>
      _CircularRevealTransitionState();
}

class _CircularRevealTransitionState extends State<_CircularRevealTransition> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color backgroundColor = theme.colorScheme.surfaceContainerHigh;
    final Color fadedOfBackgroundColor = backgroundColor.withAlpha(117);
    final Color transparentOfBackgroundColor = backgroundColor.withAlpha(0);

    return Stack(
      children: [
        // Black circular gradient
        Positioned.fill(
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              final screenSize = MediaQuery.of(context).size;
              final progress =
                  // Curves.easeInOutCubic.transform(
                  unlerpUnit(0.0, 0.8, widget.animation.value);
              // );

              final c = Offset(
                (widget.transitionOrigin.dx / screenSize.width - 0.5) * 2.0,
                (widget.transitionOrigin.dy / screenSize.height - 0.5) * 2.0,
              );

              return IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: progress * 3.0,
                      center: Alignment(c.dx, c.dy),
                      focal: Alignment(c.dx, c.dy),
                      colors: [
                        fadedOfBackgroundColor,
                        fadedOfBackgroundColor,
                        transparentOfBackgroundColor
                      ],
                      stops: [0.0, progress, progress * 2],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        AnimatedBuilder(
          animation: widget.animation,
          builder: (context, child) {
            final fraction = Curves.easeOut.transform(
              unlerpUnit(0.14, 1.0, widget.animation.value),
            );

            return ShaderMask(
              shaderCallback: (Rect bounds) {
                return FuzzyEdgeShader.createRadialRevealShader(
                  bounds: bounds,
                  center: widget.transitionOrigin,
                  fraction: fraction,
                  fuzzyEdgeWidth: 20.0,
                );
              },
              blendMode: BlendMode.dstIn,
              child: child,
            );
          },
          child: widget.child,
        ),
      ],
    );
  }
}
