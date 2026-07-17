// the boring file is where we put things that're either self-explanatory or just small and fragmented and not very relevant to understanding the core structure of the application

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart' hide tau;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
// import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/margin_shader_mask.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:signals/signals_flutter.dart';
import 'package:vibration/vibration.dart';
import 'package:vibration/vibration_presets.dart';
// import 'package:flutter_soloud/flutter_soloud.dart' as sl;

import 'platform_audio.dart';
import 'main.dart'
    show getCachedCornerRadius, getReasonableAestheticBottomCornerRadius;

const double tau = 2 * pi;
const double backingIndicatorGap = 8.0;

/// Lightweight effect-lifecycle helper for [State] objects. Replaces the
/// effect-tracking half of the now-deprecated `SignalsMixin`: [createEffect]
/// registers a live `effect()` and the cleanups are disposed automatically when
/// the State unmounts. (Implicit `.value` build tracking is provided separately
/// by [SignalStatefulWidget].)
mixin EffectsMixin<T extends StatefulWidget> on State<T> {
  final List<EffectCleanup> _effects = [];

  EffectCleanup createEffect(dynamic Function() compute) {
    final cleanup = effect(compute);
    _effects.add(cleanup);
    return cleanup;
  }

  @override
  void dispose() {
    for (final cleanup in _effects) {
      cleanup();
    }
    _effects.clear();
    super.dispose();
  }
}

/// A [Computed] that owns disposable values. [disposer] is run on every value
/// [compute] produces: on the previous value when a dependency change replaces
/// it, and on the current value when this cell itself is [dispose]d. The value
/// is otherwise retained — [compute] only re-runs when a signal it read changes,
/// so unrelated rebuilds reuse it. Reads of [value] register a dependency, so a
/// reactive context re-runs when the value is replaced.
class ComputedWithDisposer<T> {
  final void Function(T value) _disposer;
  late final Computed<T> _computed;
  bool _hasValue = false;
  late T _value;

  ComputedWithDisposer(this._disposer, T Function() compute) {
    _computed = Computed(() {
      if (_hasValue) {
        _disposer(_value);
        _hasValue = false;
      }
      _value = compute();
      _hasValue = true;
      return _value;
    });
  }

  T get value => _computed.value;

  /// The current value without registering a dependency (recomputing if a
  /// dependency changed).
  T peek() => _computed.peek();

  void dispose() {
    if (_hasValue) {
      _disposer(_value);
      _hasValue = false;
    }
    _computed.dispose();
  }
}

bool platformIsDesktop() =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

void scrollToWithPadding(
  BuildContext context,
  ScrollController scrollController, {
  Duration duration = const Duration(milliseconds: 700),
  Curve curve = const Interval(0.4, 1.0, curve: Curves.easeInOutCubic),
}) {
  final object = context.findRenderObject()!;
  final viewport = RenderAbstractViewport.maybeOf(object);
  final position = scrollController.position;

  if (viewport == null) {
    Scrollable.ensureVisible(
      context,
      duration: duration,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      curve: curve,
    );
    return;
  }

  final revealed = viewport.getOffsetToReveal(
    object,
    1.0,
    rect: null,
    axis: Axis.vertical,
  );
  final padding = MediaQuery.of(context).padding.bottom;
  final baseTarget = revealed.offset;
  final target =
      (baseTarget >= position.pixels ? baseTarget + padding : baseTarget).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
  position.animateTo(target, duration: duration, curve: curve);
}

// Using platform audio for content:// URI support (for using system ringtones)
// On Linux, uses audioplayers instead since platform_audio doesn't work there, though audioplayers doesn't work perfectly, we're not actually doing a linux target, linux is just for testing
class JukeBox {
  static final AssetSource _defaultSound = AssetSource(
    'sounds/jingles_STEEL16.ogg',
  );
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
      if (a.url == null) {
        return;
      }

      // Convert URI to appropriate Source
      Source source;
      if (a.url!.startsWith('asset://')) {
        // Flutter asset
        final assetPath = a.url!.replaceFirst('asset://assets/', '');
        source = AssetSource(assetPath);
      } else if (a.url!.startsWith('file://')) {
        // Local file
        source = DeviceFileSource(a.url!.replaceFirst('file://', ''));
      } else {
        // Try as file path
        source = DeviceFileSource(a.url!);
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

  Future<void> stopAudio() async {
    if (platformIsDesktop()) {
      await _audioPlayer!.stop();
      await _audioPlayer!.setReleaseMode(ReleaseMode.release);
    } else {
      await PlatformAudio.stopAudio();
    }
  }

  Future<void> playAudioLooping(AudioInfo a) async {
    if (platformIsDesktop()) {
      if (a.url == null) {
        return;
      }
      Source source;
      if (a.url!.startsWith('asset://')) {
        final assetPath = a.url!.replaceFirst('asset://assets/', '');
        source = AssetSource(assetPath);
      } else if (a.url!.startsWith('file://')) {
        source = DeviceFileSource(a.url!.replaceFirst('file://', ''));
      } else {
        source = DeviceFileSource(a.url!);
      }
      await _audioPlayer!.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer!.play(source);
    } else {
      await PlatformAudio.playAudioLooping(a);
    }
  }

  Future<void> playJarringSound() async {
    if (platformIsDesktop()) {
      // Use default asset sound on Linux
      await _audioPlayer!.play(_defaultSound);
    } else {
      // Get the user's actual default notification sound
      final defaultSound = await PlatformAudio.getDefaultAudio(
        PlatformAudioType.notification,
      );
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
  double.infinity,
  double.infinity,
  -double.infinity,
  -double.infinity,
);

double totalDuration(TimerData d) {
  if (d.kind == TimerKind.series || d.kind == TimerKind.loop) {
    if (d.children.isEmpty) {
      return 0;
    }
    double sum = 0;
    for (final childId in d.children) {
      final child = Mobj.seekAlreadyLoaded(childId, TimerDataType())?.peek();
      if (child != null) {
        sum += totalDuration(child);
      }
    }
    return sum;
  } else if (d.kind == TimerKind.parallelStartJustified ||
      d.kind == TimerKind.parallelEndJustified) {
    if (d.children.isEmpty) {
      return 0;
    }
    double maxDuration = 0;
    for (final childId in d.children) {
      final child = Mobj.seekAlreadyLoaded(childId, TimerDataType())?.peek();
      if (child != null) {
        maxDuration = max(maxDuration, totalDuration(child));
      }
    }
    return maxDuration;
  } else {
    return d.duration.inMicroseconds / 1000000.0;
  }
}

Rect rectFromAlign({
  required Alignment align,
  required Offset anchor,
  required double width,
  required double height,
}) {
  return Rect.fromCenter(
    center: anchor - Offset(width * align.x / 2, height * align.y / 2),
    width: width,
    height: height,
  );
}

Rect? boxRect(GlobalKey? key) {
  if (key == null) {
    return null;
  }
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) {
    return null;
  } else {
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

RenderBox? renderBox(GlobalKey key) {
  return key.currentContext?.findRenderObject() as RenderBox?;
}

/// Gets the Rect of a widget relative to an ancestor RenderBox
/// This avoids distortion from route transforms by not using global coordinates
Rect? boxRectRelativeTo(RenderBox? key, RenderBox? ancestor) {
  if (key == null || ancestor == null) {
    return null;
  }
  final globalPos = key.localToGlobal(Offset.zero);
  final localPos = ancestor.globalToLocal(globalPos);
  return localPos & key.size;
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
  GlobalKey<T> k,
  void Function(T) to,
) {
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
              child: Text(snapshot.error.toString()),
            )
          : snapshot.hasData
          ? builder(context, snapshot.data as T)
          : Container(color: theme.colorScheme.errorContainer);
    },
  );
}

class DraggableWidget<T> extends StatefulWidget {
  final Widget child;
  final T? data;
  final Function()? onDragStarted;
  final Function()? onDragEnd;
  const DraggableWidget({
    super.key,
    required this.child,
    this.data,
    this.onDragStarted,
    this.onDragEnd,
  });
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
  PeriodicTimerFromEpoch({
    required this.period,
    required this.epoch,
    required this.callback,
  }) {
    firstTickTimer = Timer(
      normalizeDuration(epoch.difference(DateTime.now()), period),
      () {
        firstTickTimer = null;
        periodicTimer = Timer.periodic(period, (timer) {
          callback(this);
        });
      },
    );
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
  bool condition,
  int length,
  T Function(int) generator,
) {
  return condition
      ? List.generate(length, (i) => generator(i))
      : List.generate(length, (i) => generator(length - i - 1));
}

/// not sure whether this is really faster than [...v]..removeWhere(p). But it could be!
List<T> copyWithout<T>(List<T> v, bool Function(T) p) {
  final List<T> ret = [];
  for (T t in v) {
    if (!p(t)) {
      ret.add(t);
    }
  }
  return ret;
}

void moveAnimationTowardsState(AnimationController animation, bool forward) {
  if (forward) {
    animation.forward();
  } else {
    animation.reverse();
  }
}

// automatically removes children when the associated animation is dismissed
class SelfRemovalHost extends StatefulWidget {
  final List<Widget> initialChildren;
  final Widget Function(List<Widget>, BuildContext) builder;
  const SelfRemovalHost({
    super.key,
    this.initialChildren = const [],
    required this.builder,
  });
  @override
  State<SelfRemovalHost> createState() => SelfRemovalHostState();
}

class SelfRemovalHostState extends State<SelfRemovalHost> {
  List<Widget> children = [];
  void add(Widget child) {
    setState(() {
      children.add(child);
    });
  }

  bool remove(Widget child) {
    if (children.remove(child)) {
      setState(() {});
      return true;
    }
    return false;
  }

  bool removeByKey(Key key) {
    final matchingChildIndex = children.indexWhere((c) => c.key == key);
    if (matchingChildIndex != -1) {
      setState(() {
        children.removeAt(matchingChildIndex);
      });
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
    return widget.builder(widget.initialChildren + children, context);
  }
}

// takes ownership of animation/dispose it on statusForRemoval
void addEphemeralAnimation(
  GlobalKey<SelfRemovalHostState> hostKey,
  Widget child,
  AnimationController animation, {
  AnimationStatus statusForRemoval = AnimationStatus.completed,
}) {
  hostKey.currentState!.add(child);
  animation.addStatusListener((status) {
    if (status == statusForRemoval) {
      hostKey.currentState?.remove(child);
      animation.dispose();
    }
  });
}

//produces a drag anchor strategy that captures the offset of the drag start so that we can animate from it.
DragAnchorStrategy dragAnchorStrategy(ValueNotifier<Offset> dragStartOffset) =>
    (Draggable<Object> draggable, BuildContext context, Offset position) {
      dragStartOffset.value = (context.findRenderObject() as RenderBox)
          .globalToLocal(position);
      return Offset.zero;
    };

class _DraggableWidgetState<T extends Object> extends State<DraggableWidget<T>>
    with TickerProviderStateMixin {
  /// when it's positioned normally, it reports to this, when it's being dragged, it restricts size to this
  final previousSize = ValueNotifier<Size>(Size.zero);
  final dragStartOffset = ValueNotifier<Offset>(Offset.zero);
  late final AnimationController popAnimation;
  @override
  void initState() {
    super.initState();
    popAnimation = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 100),
    );
  }

  @override
  Widget build(BuildContext context) {
    // don't really need this to be a valuelisteable, but it's easier for dragAnchorStrategy to pass it to us through that
    return ValueListenableBuilder(
      valueListenable: dragStartOffset,
      builder: (context, offset, child) {
        return LongPressDraggable<T>(
          delay: Duration(milliseconds: 180),
          data: widget.data,
          // this parameter isn't really supposed to do a mutation when called, but I don't know how else to get the touch point offset
          dragAnchorStrategy: dragAnchorStrategy(dragStartOffset),
          // the Material is a workaround for https://github.com/flutter/flutter/issues/39379
          feedback: ValueListenableBuilder(
            valueListenable: previousSize,
            builder: (context, psize, child) {
              return Material(
                color: Colors.transparent,
                child: AnimatedBuilder(
                  animation: popAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset:
                          lerpOffset(
                            -dragStartOffset.value,
                            -sizeToOffset(psize / 2),
                            popAnimation.value,
                          ) +
                          Offset(
                            0,
                            Curves.easeInOut.transform(popAnimation.value) * 20,
                          ),
                      child: child,
                    );
                  },
                  child: SizedBox(
                    width: psize.width,
                    height: psize.height,
                    child: widget.child,
                  ),
                ),
              );
            },
          ),
          onDragStarted: () {
            popAnimation.forward(from: 0);
            widget.onDragStarted?.call();
          },
          onDragEnd: (details) {
            widget.onDragEnd?.call();
          },
          childWhenDragging: ValueListenableBuilder(
            valueListenable: previousSize,
            builder: (context, value, child) {
              return SizedBox(width: value.width, height: value.height);
            },
          ),
          child: SizeReporter(previousSize: previousSize, child: widget.child),
        );
      },
    );
  }

  @override
  void dispose() {
    previousSize.dispose();
    popAnimation.dispose();
    dragStartOffset.dispose();
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
      ..arcTo(Rect.fromLTWH(0, 0, size.width, size.height), pi, pi, false)
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

double dot(Offset a, Offset b) {
  return a.dx * b.dx + a.dy * b.dy;
}

double offsetAngle(Offset offset) {
  return atan2(offset.dy, offset.dx);
}

Offset norm(Offset v) {
  final vd = v.distance;
  if (vd == 0) {
    return Offset(1, 0);
  }
  return v / vd;
}

Offset mirrorx(Offset v) {
  return Offset(-v.dx, v.dy);
}

Offset sizeToOffset(Size size) => Offset(size.width, size.height);

Size offsetToSize(Offset v) => Size(v.dx, v.dy);

/// Calculates the shortest angle distance between two angles in radians.
double shortestAngleDistance(double from, double to) {
  double diff = ((to % tau) - (from % tau)) % tau;
  return diff <= pi ? diff : -(tau - diff);
}

extension PathOffsetDrawing on Path {
  /// If [start] and [end] have different distances from [centerPoint], this
  /// uses [start]'s distance as the arc radius.
  void arcBetweenOffsets({
    required Offset start,
    required Offset end,
    required Offset centerPoint,
    required bool clockwise,
    bool forceMoveTo = false,
  }) {
    final startDelta = start - centerPoint;
    final endDelta = end - centerPoint;
    final startAngle = offsetAngle(startDelta);
    final endAngle = offsetAngle(endDelta);
    final sweepAngle = clockwise
        ? moduloProperly(endAngle - startAngle, tau)
        : -moduloProperly(startAngle - endAngle, tau);
    arcTo(
      Rect.fromCircle(center: centerPoint, radius: startDelta.distance),
      startAngle,
      sweepAngle,
      forceMoveTo,
    );
  }

  void moveToOffset(Offset offset) => moveTo(offset.dx, offset.dy);

  void lineToOffset(Offset offset) => lineTo(offset.dx, offset.dy);
}

Offset topLeftManhattanCenter(Rect r) {
  return Offset(
    r.left + min(r.width, r.height) / 2,
    r.top + min(r.width, r.height) / 2,
  );
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

double softmax(double a, double b) {
  return 1 - (1 - a) * (1 - b);
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
  return hsl.addLightness(-amount * hsl.lightness).toColor();
}

Color lightenColor(Color c, double amount) {
  final hsl = HSLuvColor.fromColor(c);
  return hsl.addLightness(amount * (100 - hsl.lightness)).toColor();
}

Color saturateColor(Color c, double amount) {
  final hsl = HSLuvColor.fromColor(c);
  return hsl.addSaturation(amount * (100 - hsl.saturation)).toColor();
}

Color desaturateColor(Color c, double amount) {
  final hsl = HSLuvColor.fromColor(c);
  return hsl.addSaturation(-amount * hsl.saturation).toColor();
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

double clampSignedUnit(double t) {
  if (t < -1) {
    return -1;
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

double progressOverInterval(Duration interval, DateTime startTime) {
  return clampUnit(
    DateTime.now().difference(startTime).inMicroseconds.toDouble() /
        interval.inMicroseconds.toDouble(),
  );
}

/// tracks two components, a rise time and a fall time. Sometimes you want an animation to look different on the way down. Use the second component (the falling one) of the animation value to smoothly overrule the rising component so that there's no stutter or interruption when the animation changes direction. However, when the animation goes from falling to rising, there will be a discontinuity.
/// when you call forward(), the rise component will start to move towards 1. When you call reverse(), the fall component will start to move towards 1. The next time you call forward, the rise component will start from roughly min(rise, fall), and the fall component will be 0.
class UpDownAnimationController extends ValueListenable<(double, double)>
    with ChangeNotifier
    implements Animation<(double, double)> {
  // falltime overrides risetime, so reversing while the forward is still happening always looks fine (special), but there can be glitches when going forward while reverse is in progress.
  DateTime? _riseTime;
  DateTime? _fallTime;
  final Duration rawRiseDuration;
  final Duration rawFallDuration;
  // durations scaled by devtools' slow-animations factor
  Duration get riseDuration => rawRiseDuration * timeDilation;
  Duration get fallDuration => rawFallDuration * timeDilation;
  final List<AnimationStatusListener> _statusListeners = [];
  AnimationStatus _lastStatus = AnimationStatus.dismissed;
  late final Ticker _ticker;

  UpDownAnimationController({
    required Duration riseDuration,
    required Duration fallDuration,
    required TickerProvider vsync,
  }) : rawRiseDuration = riseDuration,
       rawFallDuration = fallDuration {
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

  void towards(
    bool direction, {
    Duration? forwardDelay,
    Duration? reverseDelay,
  }) {
    if (direction) {
      forward(delay: forwardDelay);
    } else {
      reverse(delay: reverseDelay);
    }
  }

  /// does nothing if forward is already running
  void forward({double? from, Duration? delay}) {
    Duration dd = delay ?? Duration.zero;
    if (from != null) {
      _riseTime = DateTime.now()
          .add(dd)
          .subtract(
            Duration(
              milliseconds: (from * riseDuration.inMilliseconds).toInt(),
            ),
          );
    } else if (_riseTime == null) {
      _riseTime = DateTime.now().add(dd);
    } else {
      if (_fallTime != null) {
        // tries to start from where it currently is (this may not work if you're using heterogenous easers on rise and fall)
        double riseProgress = durationToSeconds(
          DateTime.now().difference(_riseTime!),
        );
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
                        durationToSeconds(riseDuration),
              ) /
              durationToSeconds(riseDuration),
        );
        if (forwardPosition > 0) {
          _riseTime = DateTime.now().subtract(
            secondsToDuration(forwardPosition),
          );
        } else {
          _riseTime = DateTime.now().add(dd);
        }
      } else {
        // else already going forward, so just keeps going forward
        // but may need to bump the delay forward
        if (delay != null && DateTime.now().compareTo(_riseTime!) < 0) {
          _riseTime = DateTime.now().add(delay);
        }
      }
    }
    _fallTime = null;
    if (!_ticker.isActive) {
      _ticker.start();
    }
    notifyListeners();
    _updateStatus();
  }

  void reverse({Duration? delay}) {
    // do nothing if already falling
    if (_fallTime != null) {
      return;
    }
    _fallTime = delay != null ? DateTime.now().add(delay) : DateTime.now();
    if (!_ticker.isActive) {
      _ticker.start();
    }
    notifyListeners();
    _updateStatus();
  }

  /// you may wish to use this to do something different on the first run
  bool get hasntCycled => _fallTime == null;

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

  double get scalarValue {
    final (rise, fall) = value;
    return rise * (1 - fall);
  }

  /// (rise, fall)
  @override
  (double, double) get value {
    final now = DateTime.now();
    double riseValue = 0.0;
    if (_riseTime != null) {
      final elapsed = now.difference(_riseTime!).inMicroseconds;
      riseValue = clampUnit(
        elapsed.toDouble() / riseDuration.inMicroseconds.toDouble(),
      );
    }

    double fallValue = 0.0;
    if (_fallTime != null) {
      final elapsed = now.difference(_fallTime!).inMicroseconds;
      fallValue = clampUnit(
        elapsed.toDouble() / fallDuration.inMicroseconds.toDouble(),
      );
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

/// Adapter that converts Animation<(double, double)> to Animation<double> by computing min(rise, 1 - fall)
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

/// Critically-damped spring with an initial-velocity kick on forward-from-rest so the response shape resembles easeOut instead of the lazy exponential critical damping gives a step input. Mid-flight re-targets preserve velocity.
class SpringExpansionController extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  final SpringDescription spring;
  final double kickSpeed;
  final double restThreshold;
  late final AnimationController _controller;
  final List<VoidCallback> _closedListeners = [];
  double _target = 0;
  bool _settledAtZero = true;
  static const defaultSpring = SpringDescription(
    mass: 1,
    stiffness: 625,
    damping: 50,
  );

  SpringExpansionController({
    required TickerProvider vsync,
    this.spring = defaultSpring,
    this.kickSpeed = 25.0,
    this.restThreshold = 0.01,
  }) {
    _controller = AnimationController.unbounded(vsync: vsync);
    _controller.addListener(_onTick);
  }

  void _onTick() {
    notifyListeners();
    final isSettledAtZero =
        _target == 0 &&
        _controller.value.abs() < restThreshold &&
        _controller.velocity.abs() < restThreshold;
    if (isSettledAtZero && !_settledAtZero) {
      _settledAtZero = true;
      for (final cb in _closedListeners.toList()) {
        cb();
      }
    } else if (!isSettledAtZero) {
      _settledAtZero = false;
    }
  }

  void _launch(double target) {
    _target = target;
    final v = _controller.value.abs() < restThreshold && target != 0
        ? kickSpeed
        : _controller.velocity;
    _controller.animateWith(
      SpringSimulation(spring, _controller.value, target, v),
    );
  }

  void forward() => _launch(1);
  void reverse() => _launch(0);

  void towards(bool direction) {
    if (direction) {
      forward();
    } else {
      reverse();
    }
  }

  void addClosedListener(VoidCallback listener) =>
      _closedListeners.add(listener);
  void removeClosedListener(VoidCallback listener) =>
      _closedListeners.remove(listener);

  @override
  double get value => _controller.value;

  @override
  AnimationStatus get status => _settledAtZero
      ? AnimationStatus.dismissed
      : (_target >= 0.5 ? AnimationStatus.forward : AnimationStatus.reverse);

  void dispose() {
    _controller.dispose();
  }

  @override
  void didStartListening() {}

  @override
  void didStopListening() {}
}

/// A label's fade, a spring that runs 0↔1 with a velocity kick on forward-from-rest. [forward] waits [delay] before launching the rise (a real timer — the spring just sits at 0 until it fires), modelling the old delayed entrance without rescaling reads. [reverse] cancels any pending rise and falls immediately; if the rise was still waiting, the spring never left 0 so it just stays shut.
/// the same spring at [factor] of its speed, preserving its damping character
/// (over/under/critically damped stays the same). Frequency scales with
/// sqrt(stiffness/mass) and the damping ratio with damping/sqrt(stiffness), so
/// scaling stiffness by factor² and damping by factor stretches the timescale
/// without changing the shape of the response.
SpringDescription defaultReverseSpringFor(
  SpringDescription spring, {
  double factor = 1.6,
}) => SpringDescription(
  mass: spring.mass,
  stiffness: spring.stiffness * factor * factor,
  damping: spring.damping * factor,
);

class LabelSpring extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  final SpringDescription spring;

  /// the spring used for the fall toward 0. Defaults to
  /// [defaultReverseSpringFor] of [spring] (1.6 the speed). Pass it explicitly
  /// to give the reverse a different feel.
  final SpringDescription reverseSpring;
  final double kickSpeed;

  /// how long [forward] waits before the rise actually launches.
  final Duration delay;
  late final AnimationController _controller;
  Timer? _delayTimer;
  double _target = 0;

  LabelSpring({
    required TickerProvider vsync,
    SpringDescription spring = const SpringDescription(
      mass: 1,
      stiffness: 625,
      damping: 40,
    ),
    SpringDescription? reverseSpring,
    this.kickSpeed = 0.0,
    this.delay = Duration.zero,
  }) : spring = spring,
       reverseSpring = reverseSpring ?? defaultReverseSpringFor(spring) {
    _controller = AnimationController.unbounded(vsync: vsync);
    _controller.addListener(notifyListeners);
    _controller.addStatusListener(_handleControllerStatus);
  }

  /// fired whenever the spring comes to rest (either fully open or fully shut).
  /// Distinct from the status-listener machinery of the mixin (which reflects
  /// [_target], not settling); used by consumers that need to react only once a
  /// rise/fall has actually finished playing out.
  final List<VoidCallback> _settleListeners = [];
  void addSettleListener(VoidCallback listener) =>
      _settleListeners.add(listener);
  void removeSettleListener(VoidCallback listener) =>
      _settleListeners.remove(listener);
  void _handleControllerStatus(AnimationStatus status) {
    // animateWith runs "forward", so every settled simulation reports completed.
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    for (final listener in List.of(_settleListeners)) {
      listener();
    }
  }

  void _launch(double target) {
    _target = target;
    final v = _controller.value.abs() < 0.01 && target != 0
        ? kickSpeed
        : _controller.velocity;
    _controller.animateWith(
      SpringSimulation(
        target == 0 ? reverseSpring : spring,
        _controller.value,
        target,
        v,
        snapToEnd: true,
      ),
    );
  }

  /// rise toward 1, after [delay]. Re-forwarding while the rise is still pending
  /// just keeps waiting (the timer isn't restarted).
  void forward() {
    if (_target == 1) return;
    _target = 1;
    if (delay == Duration.zero) {
      _launch(1);
    } else {
      _delayTimer?.cancel();
      _delayTimer = Timer(delay, () {
        _delayTimer = null;
        _launch(1);
      });
    }
  }

  /// fall toward 0, cancelling any pending rise. If the rise hadn't launched yet
  /// the spring is still at 0, so this just keeps it shut.
  void reverse() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _launch(0);
  }

  void reset() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _target = 0;
    _controller.value = 0;
    notifyListeners();
  }

  @override
  double get value => _controller.value;

  @override
  AnimationStatus get status =>
      _target >= 0.5 ? AnimationStatus.forward : AnimationStatus.reverse;

  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
  }

  @override
  void didStartListening() {}

  @override
  void didStopListening() {}
}

/// Spring-driven scalar that tracks an arbitrary target — like [SpringExpansionController] but the target isn't pinned to 0 or 1. Useful for chasing a position (e.g. an angle) where the rest value can be anywhere on the number line. Mid-flight retargets preserve velocity; retargets from rest get a velocity kick in the direction of motion so the response leads instead of dribbling out of the slow exponential a critically damped spring gives a step input.
class TargetSpring extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  final SpringDescription spring;
  final double kickSpeed;
  final double restThreshold;
  late final AnimationController _controller;
  double _target;

  TargetSpring({
    required TickerProvider vsync,
    required double initial,
    this.spring = const SpringDescription(mass: 1, stiffness: 625, damping: 50),
    this.kickSpeed = 8.0,
    this.restThreshold = 0.001,
  }) : _target = initial {
    _controller = AnimationController.unbounded(value: initial, vsync: vsync);
    _controller.addListener(notifyListeners);
  }

  double get target => _target;

  set target(double newTarget) {
    if (newTarget == _target && !_controller.isAnimating) return;
    _target = newTarget;
    final delta = newTarget - _controller.value;
    final v = _controller.velocity.abs() < restThreshold && delta != 0
        ? kickSpeed * delta.sign
        : _controller.velocity;
    _controller.animateWith(
      SpringSimulation(spring, _controller.value, newTarget, v),
    );
  }

  /// Retarget, but when launching from rest use [kickVelocity] for the initial
  /// velocity instead of the default axis-aligned [kickSpeed] * sign(delta).
  /// For a single scalar the two are equivalent, but a 2D spring pair needs the
  /// kick split along the true direction of travel — otherwise each axis kicks
  /// at full speed and the combined velocity points at the quadrant corner
  /// (45°), adding an off-axis component whenever the target isn't diagonal.
  void retargetWithKick(double newTarget, double kickVelocity) {
    if (newTarget == _target && !_controller.isAnimating) return;
    _target = newTarget;
    final v = _controller.velocity.abs() < restThreshold
        ? kickVelocity
        : _controller.velocity;
    _controller.animateWith(
      SpringSimulation(spring, _controller.value, newTarget, v),
    );
  }

  /// Jump immediately to [v] with zero velocity, cancelling any in-flight simulation.
  void jump(double v) {
    _target = v;
    _controller.value = v;
  }

  @override
  double get value => _controller.value;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  void dispose() {
    _controller.dispose();
  }

  @override
  void didStartListening() {}

  @override
  void didStopListening() {}
}

const List<int> datetimeSectionLengths = [2, 2, 2, 3, 4];
const List<int> datetimeSectionOffsets = [0, 2, 4, 6, 9];
const List<int> datetimeMaxima = [60, 60, 24, 365];
const List<String> datetimeMaximaInitial = ["s", "m", "h", "d", "y"];

const appName = "mako timer";

/// I'm not sure users really want an explanation. For an explanation to be present suggests that the user ought to read it, which is an unnecessary imposition.
const foregroundNotificationText = "";

int padLevelFor(int digitLength) {
  return datetimeSectionOffsets.lastIndexWhere((s) => s < digitLength);
}

/// if digits.length is greater than the number of given padLevel, eg, if it's 25 hours and place is 3 (which means show seconds, minutes and hours), it will still automatically show 1 day, 1 hour, and zero minutes and seconds. padLevel is for making sure enough places are shown in numbers that are too low.
String formatTime(List<int> digits, {int padLevel = 0}) {
  String ret = "";
  formatTimeFull(
    digits,
    padLevel: padLevel,
    onDigit: (d) => ret += d.toString(),
    onSeparator: () => ret += ':',
  );
  return ret;
}

/// displays the time with a "d" or "y" or "m" or "h" under the first section to make the meaning of the number easily felt. Doesn't show an "s", I think the seconds level is always clear enough..
Text formatTimeWithTimeLevel(
  List<int> digits, {
  int padLevel = 0,
  int? centiseconds,
}) {
  List<String> parts = [""];
  int highestLevel = formatTimeFull(
    digits,
    padLevel: padLevel,
    onDigit: (d) => parts.last += d.toString(),
    onSeparator: () => parts.add(""),
  );
  List<InlineSpan> spans = [];
  for (int i = 0; i < parts.length; i++) {
    spans.add(TextSpan(text: parts[i]));
    if (highestLevel > 0 && i == 0) {
      spans.add(
        WidgetSpan(
          // I don't know why this required a stack positioned, I tried Container(clipBehavior: Clip.none, alignment: Alignment.topRight), for some reason it was always 0 size.. and also seemingly positioned in the wrong place
          child: SizedBox(
            width: 0,
            height: 0,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: -4,
                  right: 0,
                  child: Text(
                    datetimeMaximaInitial[highestLevel],
                    style: TextStyle(fontSize: 7),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (i < parts.length - 1) {
      spans.add(TextSpan(text: ":"));
    }
  }
  if (centiseconds != null) {
    spans.add(TextSpan(text: ".${centiseconds.toString().padLeft(2, '0')}"));
  }

  return Text.rich(TextSpan(children: spans), overflow: TextOverflow.visible);
}

/// see the above formatTime to understand what this is used for
int formatTimeFull(
  List<int> digits, {
  int padLevel = 0,
  required Function(int) onDigit,
  required Function() onSeparator,
}) {
  // the index of the current time level (where time levels indicate seconds, minutes, hours, days, years)
  int initialUnderLevel = max(
    0,
    max(
      padLevel - 1,
      datetimeSectionOffsets.lastIndexWhere((s) => s < digits.length),
    ),
  );
  int di =
      max(
        initialUnderLevel + 1 < datetimeSectionOffsets.length
            ? datetimeSectionOffsets[initialUnderLevel + 1]
            : digits.length,
        digits.length,
      ) -
      1;

  int underLevel = max(padLevel, initialUnderLevel);
  while (di >= 0) {
    if (di < datetimeSectionOffsets[underLevel]) {
      --underLevel;
      onSeparator();
    }
    if (di < digits.length) {
      onDigit(digits[digits.length - di - 1]);
    } else {
      onDigit(0);
    }
    --di;
  }
  return initialUnderLevel;
}

Widget ignoreVerticalHeight(
  Widget child, {
  Alignment alignment = Alignment.centerLeft,
}) {
  return Container(
    clipBehavior: .none,
    height: 0,
    padding: EdgeInsets.only(right: 5),
    child: OverflowBox(
      alignment: alignment,
      maxHeight: double.infinity,
      fit: .deferToChild,
      child: child,
    ),
  );
}

///returns the index of the angleRadius segment that angle intersects, otherwise, returns -1
int radialDragResult(
  List<double> angleRadius,
  double angle, {

  /// hitspan is the span of the radial drag targets, if a drag is within this span, it will be considered a hit.
  double hitSpan = double.infinity,
}) {
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
void pushDigits(
  List<int> digitsOut,
  int number,
  int digitsInSection, {
  int base = 10,
  bool indefinite = false,
}) {
  int digitsWritten;
  if (!indefinite) {
    if (number > pow(base, digitsInSection)) {
      throw ArgumentError(
        "number exceeds the max number of digits assigned for this digit slot",
      );
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
  future
      .then((value) {
        if (!cancelled) {
          then(value);
        }
      })
      .catchError((error) {
        if (!cancelled) {
          throw error;
        }
      });
  return () {
    cancelled = true;
  };
}

/// where padLevel is the index of the number of figures to include as 0 values if the duration isn't really that long, eg, 0 is seconds, so 2 figures, 1 is minutes, 4 figures.
/// isNegative just adds a second. I can't exactly explain why countdowns feel better with an extra second added, so that they end at 0 instead of lingering at a 0 for a second before triggering. I think it has something to do with rounding. Rounding down properly generally means negative numbers go more negative, rather than going towards zero, and if we did this without the added second the second place would be as if it were rounding up. Indeed, if this supported centiseconds, you'd want to add an extra centisecond instead of a second. But we shouldn't show centiseconds in any countdowns in practice, so we'll keep it crude like this.
List<int> durationToDigits(
  double d, {
  int padLevel = 0,
  bool isNegative = false,
}) {
  List<int> digits = [];
  bool started = false;
  Duration dur = Duration(
    microseconds: ((d + (isNegative ? 1 : 0)) * 1000000).toInt(),
  );
  int days = dur.inDays;
  // Years
  if (days >= 365 || padLevel >= 4) {
    pushDigits(digits, days ~/ 365, 4, indefinite: true);
    days = days % 365;
    started = true;
  }
  // Days
  if (started || days > 0 || padLevel >= 3) {
    pushDigits(digits, days, 3);
    started = true;
  }
  // Hours
  if (started || dur.inHours % 24 > 0 || padLevel >= 2) {
    pushDigits(digits, dur.inHours % 24, 2);
    started = true;
  }
  // Minutes
  if (started || dur.inMinutes % 60 > 0 || padLevel >= 1) {
    pushDigits(digits, dur.inMinutes % 60, 2);
    started = true;
  }
  // Seconds
  if (started || dur.inSeconds % 60 > 0 || padLevel >= 0) {
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

Duration? maxRemainingDurationOfList(List<Duration?> durations) {
  Duration max = Duration.zero;
  for (final duration in durations) {
    if (duration == null) continue;
    if (duration > max) {
      max = duration;
    }
  }
  return max;
}

Duration maxDuration(Duration a, Duration b) => a > b ? a : b;

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

void considerUpdating<T, P>(
  T? prev,
  T next,
  P Function(T) property,
  void Function({required T? from, required T to}) update,
) {
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
  List<int> digits = durationToDigits(
    durationToSeconds(sd),
    padLevel: padLevel,
  );
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

/// Animates multiple overlapping pulses triggered by events from a stream.
/// Each pulse progresses from 0 to 1 over [duration], and is removed once complete.
class PulserAnimation extends StatefulWidget {
  final Stream<void> pulses;
  final Duration duration;
  final Widget? child;
  final Widget Function(
    BuildContext context,
    Widget? child,
    List<double> progresses,
  )
  builder;

  const PulserAnimation({
    super.key,
    required this.pulses,
    required this.duration,
    this.child,
    required this.builder,
  });

  @override
  State<PulserAnimation> createState() => _PulserAnimationState();
}

class _PulserAnimationState extends State<PulserAnimation>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  StreamSubscription<void>? _subscription;
  final List<DateTime> _pulseStartTimes = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _subscription = widget.pulses.listen(_onPulse);
  }

  @override
  void didUpdateWidget(PulserAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulses != oldWidget.pulses) {
      _subscription?.cancel();
      _subscription = widget.pulses.listen(_onPulse);
    }
  }

  void _onPulse(_) {
    _pulseStartTimes.add(DateTime.now());
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    final durationMicros = widget.duration.inMicroseconds;

    _pulseStartTimes.removeWhere((startTime) {
      final elapsed = now.difference(startTime).inMicroseconds;
      return elapsed >= durationMicros;
    });

    if (_pulseStartTimes.isEmpty) {
      _ticker.stop();
    }

    setState(() {});
  }

  List<double> _computeProgresses() {
    final now = DateTime.now();
    final durationMicros = widget.duration.inMicroseconds;
    return _pulseStartTimes.map((startTime) {
      final elapsed = now.difference(startTime).inMicroseconds;
      return clampUnit(elapsed / durationMicros);
    }).toList();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, widget.child, _computeProgresses());
  }
}

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
    // oh this would need to be stateful to work
    // // only repaint if the value is different enough to be noticeable, (or if the color is different)
    // return (((value - oldDelegate.value).abs() > 0.004) ||
    //         (value == 0 && oldDelegate.value != 0) ||
    //         (value == 1 && oldDelegate.value != 1)) ||
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
      path.addOval(
        Rect.fromCircle(center: center, radius: radius * holeRadius),
      );

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

  /// the proportion of the radius of the filled pie relative to the background
  final double innerRadp;
  const Pie({
    super.key,
    required this.value,
    required this.backgroundColor,
    required this.color,
    this.innerRadp = 1,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final halfDevicePixel = 0.5 / devicePixelRatio;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // slight (imperceptible)padding to prevent antialiasing artifacts
          Padding(
            padding: EdgeInsets.all(halfDevicePixel),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: backgroundColor,
              ),
            ),
          ),
          Transform.scale(
            scale: innerRadp,
            child: CustomPaint(
              // size: Size(size, size),
              painter: PiePainter(value: value.clamp(0.0, 1.0), color: color),
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

  DragIndicatorPainter({required this.color, required this.radius});

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

double distanceToRectangle(double width, double height, Offset fromTopLeft) {
  final dx = max(0.0, max(-fromTopLeft.dx, fromTopLeft.dx - width));
  final dy = max(0.0, max(-fromTopLeft.dy, fromTopLeft.dy - height));
  return sqrt(dx * dx + dy * dy);
}

double rectPointDistance(Rect r, Offset p) {
  return distanceToRectangle(r.width, r.height, p - r.topLeft);
}

/// A RectTween that wraps another RectTween but delays the start of movement,
/// staying at `begin` until `delay` fraction of the animation has passed.
class DelayedRectTween extends Tween<Rect?> {
  final double delay;
  final RectTween _innerTween;

  DelayedRectTween({
    required super.begin,
    required super.end,
    this.delay = 0.0,
    RectTween? innerTween,
  }) : _innerTween = innerTween ?? MaterialRectArcTween(begin: begin, end: end);

  @override
  Rect? lerp(double t) {
    if (t <= delay) {
      return begin;
    }
    final adjustedT = (t - delay) / (1.0 - delay);
    return _innerTween.lerp(adjustedT);
  }
}

/// Factory for Hero.createRectTween that delays movement by a fraction of the animation.
/// Uses MaterialRectArcTween internally for the same curved path as default Hero.
/// Usage: `Hero(createRectTween: delayedHeroRectTween(0.1), ...)`
CreateRectTween delayedHeroRectTween(double delay) {
  return (Rect? begin, Rect? end) =>
      DelayedRectTween(begin: begin, end: end, delay: delay);
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
    final Offset center =
        centerAlignment?.alongSize(size) ??
        centerOffset ??
        Offset(size.width / 2, size.height / 2);
    final minRadius = this.minRadius ?? 0;
    final maxRadius =
        this.maxRadius ?? calcMaxRadiusForPointWithinRectangle(size, center);

    return Path()..addOval(
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
  final Widget Function(BuildContext context) builder;
  final Offset? buttonCenter;
  final GlobalKey? iconOriginKey;
  final Duration _transitionDuration;
  final Duration _reverseTransitionDuration;

  CircularRevealRoute({
    required this.builder,
    this.buttonCenter,
    this.iconOriginKey,
    Duration transitionDuration = const Duration(milliseconds: 380),
    Duration reverseTransitionDuration = const Duration(milliseconds: 270),
  }) : _transitionDuration = transitionDuration,
       _reverseTransitionDuration = reverseTransitionDuration;

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  bool get opaque => animation?.isCompleted ?? false;

  // Force our own duration, don't let mixin override it
  @override
  Duration get transitionDuration => _transitionDuration;

  @override
  Duration get reverseTransitionDuration => _reverseTransitionDuration;

  @override
  bool get maintainState => true;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => true;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Incorporate screen corner scale-down with secondaryAnimation,
    // and primary animation is still circular reveal.
    final screenSize = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: secondaryAnimation,
      builder: (context, child_) {
        final corners = getCachedCornerRadius();
        double scale;
        if (platformIsDesktop()) {
          scale = 1.0;
        } else {
          scale =
              1.0 - 0.13 * Curves.easeIn.transform(secondaryAnimation.value);
        }

        final revealOrigin =
            boxRect(iconOriginKey)?.center ??
            buttonCenter ??
            Offset(screenSize.width / 2, screenSize.height * 2.4);

        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(corners.topLeft),
              topRight: Radius.circular(corners.topRight),
              bottomLeft: Radius.circular(corners.bottomLeft),
              bottomRight: Radius.circular(corners.bottomRight),
            ),
            child: _CircularRevealRouteTransition(
              animation: animation,
              revealOrigin: revealOrigin,
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
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
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

Shader createRadialRevealShader({
  required Rect bounds,
  required Alignment center,
  required double fraction,
  double fuzzyEdgeWidth = 20.0,
  double? minRadius,
  double? maxRadius,
  bool invert = false,
}) {
  final centerOffset = center.alongSize(bounds.size);
  final calculatedMinRadius =
      minRadius ??
      distanceToRectangle(bounds.width, bounds.height, centerOffset);
  final calculatedMaxRadius =
      maxRadius ??
      (calcMaxRadiusForPointWithinRectangle(bounds.size, centerOffset) +
          fuzzyEdgeWidth);
  final effectiveFraction = invert ? 1.0 - fraction : fraction;
  final currentRadius = lerp(
    calculatedMinRadius,
    calculatedMaxRadius,
    effectiveFraction,
  );

  final colors = invert
      ? const [Colors.transparent, Colors.transparent, Colors.white]
      : const [Colors.white, Colors.white, Colors.transparent];

  final transitionStop = max(
    0.0,
    currentRadius / (currentRadius + fuzzyEdgeWidth),
  );
  final stops = [0.0, transitionStop, 1.0];

  return RadialGradient(
    center: center,
    radius: currentRadius / min(bounds.width, bounds.height),
    colors: colors,
    stops: stops,
  ).createShader(bounds);
}

/// Creates a linear gradient shader with a fuzzy edge for directional reveal effects.
/// The gradient progresses in the direction specified by [angle] (in radians).
/// Angle of 0 is left-to-right, π/2 is top-to-bottom, π is right-to-left, etc.
Shader linearRevealShader({
  required Rect bounds,
  required double angle,
  required double fraction,
  double fuzzyEdgeWidth = 20.0,
  // how long is the path over which the animation moves? Whether to use the full diagonal or else whether to just use the shortest possible sweep for which the animation will start at the nearest corner of the bounds and finish at the furthest (which will have inconsistent travel time when the angle is changed)
  bool sphericalSweepLength = false,
}) {
  // Calculate the diagonal length to ensure full coverage regardless of angle
  final boundsSize = bounds.size;
  final diagonal = sqrt(
    boundsSize.width * boundsSize.width + boundsSize.height * boundsSize.height,
  );

  Offset begin;
  Offset end;

  final direction = angleToOffset(angle);
  final center = sizeToOffset(boundsSize) / 2;
  if (sphericalSweepLength) {
    // calculate start and finish on the assumption of a roughly circular bounds shape
    final halfDiagonal = diagonal / 2;
    begin = center - direction * (halfDiagonal + fuzzyEdgeWidth);
    end = center + direction * (halfDiagonal + fuzzyEdgeWidth);
  } else {
    // calculate begin and end to minimize the distance of travel
    double nearestBegin = double.infinity;
    double furthestEnd = -double.infinity;
    for (final corner in [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      final distance = dot(direction, (corner - center));
      if (distance < nearestBegin) {
        nearestBegin = distance;
      }
      if (distance > furthestEnd) {
        furthestEnd = distance;
      }
    }
    begin = center + direction * (nearestBegin - fuzzyEdgeWidth);
    end = center + direction * (furthestEnd + fuzzyEdgeWidth);
  }

  final colors = const [Colors.white, Colors.white, Colors.transparent];

  final fuzzyRatio = fuzzyEdgeWidth / diagonal;
  final p = (1 - fuzzyRatio) * fraction;
  final stops = [0.0, p, p + fuzzyRatio];

  return LinearGradient(
    begin: Alignment(
      (begin.dx / boundsSize.width) * 2 - 1,
      (begin.dy / boundsSize.height) * 2 - 1,
    ),
    end: Alignment(
      (end.dx / boundsSize.width) * 2 - 1,
      (end.dy / boundsSize.height) * 2 - 1,
    ),
    colors: colors,
    stops: stops,
  ).createShader(bounds);
}

class RelAlignment {
  /// Alignment value (-1 to 1 on each axis, where 0 means center)
  final double? originAlignX;

  /// Alignment value (-1 to 1 on each axis, where 0 means center)
  final double? originAlignY;

  /// Origin rightwards from the left edge of the child (can be negative)
  final double? originLeft;

  /// Origin leftwards from the right edge of the child (can be negative)
  final double? originRight;

  /// Origin downwards from the top edge of the child (can be negative)
  final double? originTop;

  /// Origin upwards from the bottom edge of the child (can be negative)
  final double? originBottom;

  static const center = RelAlignment();

  const RelAlignment({
    this.originAlignX,
    this.originAlignY,
    this.originLeft,
    this.originRight,
    this.originTop,
    this.originBottom,
  });

  static RelAlignment fromOffset(Offset offset) {
    return RelAlignment(originLeft: offset.dx, originTop: offset.dy);
  }

  void check() {
    assert(
      !(originAlignX != null && originLeft != null),
      'Values given for both originAlignX and originLeft, which would contradict.',
    );
    assert(
      !(originAlignX != null && originRight != null),
      'Values given for both originAlignX and originRight, which would contradict.',
    );
    assert(
      !(originLeft != null && originRight != null),
      'Values given for both originLeft and originRight, which would contradict.',
    );
    assert(
      !(originAlignY != null && originTop != null),
      'Values given for both originAlignY and originTop, which would contradict.',
    );
    assert(
      !(originAlignY != null && originBottom != null),
      'Values given for both originAlignY and originBottom, which would contradict.',
    );
    assert(
      !(originTop != null && originBottom != null),
      'Values given for both originTop and originBottom, which would contradict.',
    );
  }

  Alignment computeCenterOver(Size size) {
    double x;
    if (originAlignX != null) {
      x = originAlignX!;
    } else if (originLeft != null) {
      x = (originLeft! / size.width) * 2 - 1;
    } else if (originRight != null) {
      x = 1 - (originRight! / size.width) * 2;
    } else {
      x = 0;
    }

    double y;
    if (originAlignY != null) {
      y = originAlignY!;
    } else if (originTop != null) {
      y = (originTop! / size.height) * 2 - 1;
    } else if (originBottom != null) {
      y = 1 - (originBottom! / size.height) * 2;
    } else {
      y = 0;
    }

    return Alignment(x, y);
  }

  Alignment computeAlignment(Size size) {
    return Alignment(
      computeAlignmentAxis(size.width, originLeft, originRight, originAlignX),
      computeAlignmentAxis(size.height, originTop, originBottom, originAlignY),
    );
  }
}

class FuzzyCircleReveal extends StatelessWidget {
  /// where the reveal emanates from
  final RelAlignment origin;
  final Animation<double> animation;
  final Widget child;
  final double fuzzyEdgeWidth;

  /// Minimum radius to start from. Defaults to distance from center to nearest edge.
  final double? minRadius;

  /// inverts the gradient so that the transparent side is inside the focus. The smaller side of the animation is still the fully transparent state.
  final bool invertGradient;

  // ignore: prefer_const_constructors_in_immutables, we have to do the asserts
  FuzzyCircleReveal({
    super.key,
    required this.origin,
    required this.animation,
    required this.child,
    this.fuzzyEdgeWidth = 20.0,
    this.minRadius,
    this.invertGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return ClipRect(
          child: ShaderMask(
            shaderCallback: (Rect bounds) {
              return createRadialRevealShader(
                bounds: bounds,
                center: origin.computeCenterOver(bounds.size),
                fraction: animation.value,
                fuzzyEdgeWidth: fuzzyEdgeWidth,
                minRadius: minRadius,
                invert: invertGradient,
              );
            },
            blendMode: BlendMode.dstIn,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

double computeAlignmentAxis(
  double size,
  double? fromLeft,
  double? fromRight,
  double? alignX,
) {
  if (fromLeft != null) {
    return (fromLeft / size) * 2 - 1;
  } else if (fromRight != null) {
    return 1 - (fromRight / size) * 2;
  } else {
    return alignX ?? 0;
  }
}

class FuzzyCircleClip extends StatelessWidget {
  final double progress;
  final RelAlignment origin;
  final double? fuzzyEdgeWidth;
  final double? minRadius;
  final bool invertGradient;
  final Widget child;
  // ignore: prefer_const_constructors_in_immutables, we have to do the asserts
  FuzzyCircleClip({
    super.key,
    required this.origin,
    required this.progress,
    required this.child,
    this.fuzzyEdgeWidth = 20.0,
    this.minRadius,
    this.invertGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    if (progress == 0.0) {
      return Opacity(opacity: 0.0, child: child);
    } else if (progress == 1.0) {
      return child;
    } else {
      return ClipRect(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          child: child,
          shaderCallback: (Rect bounds) {
            return createRadialRevealShader(
              bounds: bounds,
              fraction: progress,
              fuzzyEdgeWidth: fuzzyEdgeWidth ?? 20.0,
              minRadius: minRadius,
              invert: invertGradient,
              center: origin.computeAlignment(bounds.size),
            );
          },
        ),
      );
    }
  }
}

class FuzzyLinearClip extends StatelessWidget {
  final double progress;
  final double angle; // angle in radians
  final double? fuzzyEdgeWidth;
  final bool sphericalSweepLength;
  final double margin;
  final Widget child;

  /// [margin] currently isn't actually working it seems.
  // ignore: prefer_const_constructors_in_immutables
  FuzzyLinearClip({
    super.key,
    required this.angle,
    required this.progress,
    required this.child,
    this.margin = 0.0,
    this.fuzzyEdgeWidth = 20.0,
    this.sphericalSweepLength = false,
  });

  @override
  Widget build(BuildContext context) {
    if (progress == 0.0) {
      return Opacity(opacity: 0.0, child: child);
    } else if (progress == 1.0) {
      return child;
    } else {
      return MarginShaderMask(
        blendMode: BlendMode.dstIn,
        margin: margin,
        shaderCallback: (Rect bounds) {
          return linearRevealShader(
            bounds: bounds,
            fraction: progress,
            fuzzyEdgeWidth: fuzzyEdgeWidth ?? 20.0,
            angle: angle,
            sphericalSweepLength: sphericalSweepLength,
          );
        },
        child: child,
      );
    }
  }
}

class _CircularRevealRouteTransition extends StatefulWidget {
  final Animation<double> animation;
  final Offset revealOrigin;

  final Widget child;

  const _CircularRevealRouteTransition({
    // super.key,
    required this.animation,
    required this.revealOrigin,
    required this.child,
  });

  @override
  State<_CircularRevealRouteTransition> createState() =>
      _CircularRevealRouteTransitionState();
}

/// mostly linear
double circularRevealRouteCurve(double v) =>
    lerp(v, Curves.easeOut.transform(v), 0.2);

class _CircularRevealRouteTransitionState
    extends State<_CircularRevealRouteTransition> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color backgroundColor = theme.colorScheme.primary;
    final Color fadedOfBackgroundColor = backgroundColor.withAlpha(14);
    final Color transparentOfBackgroundColor = backgroundColor.withAlpha(0);
    // the interior of the reveal starts filled with the highest mako
    // background color and fades away to expose the new screen.
    final Color interiorVeilColor = OurThemeData.fromTheme(theme).foreBackColor;

    return Stack(
      children: [
        // circular shadow gradient moving in advance of the clip
        Positioned.fill(
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              final screenSize = MediaQuery.of(context).size;
              final progress = circularRevealRouteCurve(
                unlerpUnit(0.0, 0.8, widget.animation.value),
              );

              final c = Alignment(
                (widget.revealOrigin.dx / screenSize.width - 0.5) * 2.0,
                (widget.revealOrigin.dy / screenSize.height - 0.5) * 2.0,
              );

              return IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: Curves.easeOut.transform(progress) * 3.0,
                      center: c,
                      focal: c,
                      colors: [
                        fadedOfBackgroundColor,
                        fadedOfBackgroundColor,
                        transparentOfBackgroundColor,
                      ],
                      stops: [0.0, progress, progress * 2],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              final screenSize = MediaQuery.of(context).size;

              final expansionp = circularRevealRouteCurve(
                unlerpUnit(0.07, 0.8, widget.animation.value),
              );
              // if (fraction == 1.0) {
              //   return child!;
              // }
              final centerAlignment = Alignment(
                (widget.revealOrigin.dx / screenSize.width - 0.5) * 2.0,
                (widget.revealOrigin.dy / screenSize.height - 0.5) * 2.0,
              );

              // The revealed interior is initially veiled with the highest
              // background color, fading down to expose the new screen
              // gradually at first then quickly by the time expansion ends.
              final veilOpacity =
                  1.0 -
                  Curves.easeIn.transform(
                    unlerpUnit(0.2, 0.85, widget.animation.value),
                  );

              return ClipRect(
                child: ShaderMask(
                  shaderCallback: (Rect bounds) {
                    return createRadialRevealShader(
                      bounds: bounds,
                      center: centerAlignment,
                      fraction: expansionp,
                      fuzzyEdgeWidth: 20.0,
                    );
                  },
                  // no shader if complete
                  // blendMode: fraction == 1.0 ? BlendMode.dst: BlendMode.dstIn,
                  blendMode: BlendMode.dstIn,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      child!,
                      if (veilOpacity > 0.0)
                        IgnorePointer(
                          child: ColoredBox(
                            color: interiorVeilColor.withValues(
                              alpha: veilOpacity,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

void multimapAdd<K, V>(Map<K, List<V>> map, K key, V value) {
  if (!map.containsKey(key)) {
    map[key] = [];
  }
  map[key]!.add(value);
}

/// calls removed first
void diffListsets<T>(
  List<T> earlier,
  List<T> newer, {
  void Function(T item)? added,
  void Function(T item)? removed,
}) {
  final earlierSet = earlier.toSet();
  final newerSet = newer.toSet();
  for (final et in earlier) {
    if (!newerSet.contains(et)) {
      removed?.call(et);
    }
  }
  for (final nt in newer) {
    if (!earlierSet.contains(nt)) {
      added?.call(nt);
    }
  }
}

/// abstractions for timer list management
List<MobjID<TimerData>> childrenOf(Mobj host) {
  if (host is Mobj<TimerData>) {
    return host.peek()!.children;
  }
  if (host is Mobj<List<MobjID<TimerData>>>) {
    return host.peek()!;
  }
  throw StateError("host is not a timer or timer list");
}

void writeBackChildren(Mobj host, List<MobjID<TimerData>> children) {
  if (host is Mobj<TimerData>) {
    host.value = host.peek()!.withChanges(children: children);
  } else if (host is Mobj<List<MobjID<TimerData>>>) {
    host.value = children;
  } else {
    throw StateError("host is not a timer or timer list");
  }
}

/// A widget that maintains aspect ratio using visual scaling instead of layout constraints.
/// Unlike AspectRatio which constrains the child during layout, this widget:
/// 1. Lays out the child to determine its natural size
/// 2. Calculates a scale factor to maintain the desired aspect ratio
/// 3. Applies the scale transformation during painting
///
/// The widget itself takes up the full space given by its parent constraints,
/// but the child is visually scaled to maintain the aspect ratio.
class ScalingAspectRatio extends SingleChildRenderObjectWidget {
  final double aspectRatio;
  final Alignment alignment;

  const ScalingAspectRatio({
    super.key,
    this.aspectRatio = 1,
    required Widget child,
    this.alignment = Alignment.center,
  }) : super(child: child);

  @override
  RenderScalingAspectRatio createRenderObject(BuildContext context) {
    return RenderScalingAspectRatio(
      aspectRatio: aspectRatio,
      alignment: alignment,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderScalingAspectRatio renderObject,
  ) {
    renderObject
      ..aspectRatio = aspectRatio
      ..alignment = alignment;
  }
}

class RenderScalingAspectRatio extends RenderProxyBox {
  RenderScalingAspectRatio({
    required double aspectRatio,
    Alignment alignment = Alignment.center,
  }) : _aspectRatio = aspectRatio,
       _alignment = alignment;

  double _aspectRatio;
  double get aspectRatio => _aspectRatio;
  set aspectRatio(double value) {
    if (_aspectRatio == value) return;
    _aspectRatio = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Alignment _alignment;
  Alignment get alignment => _alignment;
  set alignment(Alignment value) {
    if (_alignment == value) return;
    _alignment = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void performLayout() {
    if (child != null) {
      // Let the child lay itself out with loose constraints to get its natural size
      child!.layout(constraints.loosen(), parentUsesSize: true);
      // This widget takes up the full space given by parent
      size = constraints.biggest;
    } else {
      size = constraints.smallest;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) {
      final Size childSize = child!.size;

      // Calculate the scale factor to maintain aspect ratio within our bounds
      final double childAspectRatio = childSize.width / childSize.height;
      final double scale;

      if (childAspectRatio > aspectRatio) {
        // Child is wider than target aspect ratio, scale based on width
        scale = (size.width / childSize.width);
      } else {
        // Child is taller than target aspect ratio, scale based on height
        scale = (size.height / childSize.height);
      }

      // Calculate the scaled size
      final Size scaledSize = childSize * scale;

      // Calculate the offset to align the scaled child
      final Size remainingSpace = Size(
        size.width - scaledSize.width,
        size.height - scaledSize.height,
      );
      final Offset alignmentOffset = alignment.alongSize(remainingSpace);

      // Apply the transformation
      final Matrix4 transform = Matrix4.identity()
        ..translateByDouble(alignmentOffset.dx, alignmentOffset.dy, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);

      context.pushTransform(needsCompositing, offset, transform, (
        context,
        offset,
      ) {
        context.paintChild(child!, offset);
      });
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (child == null) return false;

    final Size childSize = child!.size;
    final double childAspectRatio = childSize.width / childSize.height;
    final double scale;

    if (childAspectRatio > aspectRatio) {
      scale = (size.width / childSize.width);
    } else {
      scale = (size.height / childSize.height);
    }

    final Size scaledSize = childSize * scale;
    final Size remainingSpace = Size(
      size.width - scaledSize.width,
      size.height - scaledSize.height,
    );
    final Offset alignmentOffset = alignment.alongSize(remainingSpace);

    // Transform the hit test position to child coordinates
    final Matrix4 transform = Matrix4.identity()
      ..translateByDouble(alignmentOffset.dx, alignmentOffset.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);

    final Matrix4 inverse = Matrix4.identity();
    if (transform.invert() == 0.0) {
      return false;
    }
    inverse.copyInverse(transform);

    final Offset childPosition = MatrixUtils.transformPoint(inverse, position);

    return result.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        return child!.hitTest(result, position: childPosition);
      },
    );
  }
}

/// A button with fuzzy circle ink animation. Ink wells from touch point on press,
/// fades out on tap confirm. Behaves like a proper button (cancels on drag out, etc).
/// todo: remove the automatic downfade at the end of the initial well animation, supercede with one that happens at max(animation end, finger release)
class InkButton extends StatefulWidget {
  final Color? backgroundColor;
  final Widget? child;
  final Widget Function(BuildContext context, bool isOn)? builder;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onTapUpGlobalPosition;
  final Duration wellDuration;
  final Duration fadeDuration;
  final double fuzzyEdgeWidth;
  final Color? inkColor;
  final Color? inkColorFaded;
  final earlyFadeDuration = const Duration(milliseconds: 170);
  final BorderRadius? borderRadius;
  final Duration fadeDelay;
  InkButton({
    super.key,
    this.onTap,
    this.onTapUpGlobalPosition,
    this.wellDuration = const Duration(milliseconds: 290),
    this.fadeDuration = const Duration(milliseconds: 170),
    this.fadeDelay = const Duration(milliseconds: 50),
    this.fuzzyEdgeWidth = 12.0,
    this.backgroundColor,
    this.inkColor,
    this.inkColorFaded,
    this.borderRadius,
    this.child,
    this.builder,
  }) {
    if (builder != null && child != null) {
      throw ArgumentError.value(
        child,
        'child',
        'Cannot provide both builder and child',
      );
    } else if (builder == null && child == null) {
      throw ArgumentError.value(
        child,
        'child',
        'Must provide either builder or child',
      );
    }
  }

  @override
  State<InkButton> createState() => _InkButtonState();
}

class _InkButtonState extends State<InkButton> with TickerProviderStateMixin {
  final List<InkWelling> _wells = [];

  void _handleTapDown(TapDownDetails details) {
    final touchPoint = RelAlignment.fromOffset(details.localPosition);
    final key = UniqueKey();
    setState(() {
      _wells.add(
        InkWelling(
          key: key,
          origin: touchPoint,
          fadeColor:
              widget.inkColorFaded ??
              (Theme.of(context).colorScheme.primary.withAlpha(40)),
          color:
              widget.inkColor ??
              Theme.of(context).colorScheme.primary.withAlpha(40),
          fuzzyEdgeWidth: widget.fuzzyEdgeWidth,
          borderRadius: widget.borderRadius,
          onFinished: () {
            setState(() {
              _wells.removeWhere((e) => e.key == key);
            });
          },
          bloomController: AnimationController(
            vsync: this,
            duration:
                widget.wellDuration + widget.fadeDelay + widget.fadeDuration,
          )..forward(),
          fadeController: AnimationController(
            vsync: this,
            duration: widget.fadeDuration,
          ),
          child: widget.builder?.call(context, true),
        ),
      );
    });
  }

  void _handleTapUp(TapUpDetails details) {
    _wells.lastOrNull?.confirm();
    widget.onTapUpGlobalPosition?.call(details.globalPosition);
    widget.onTap?.call();
  }

  void _handleTapCancel() {
    _wells.lastOrNull?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    Widget clipIfNeeded(Widget child) {
      if (widget.borderRadius != null) {
        return ClipRRect(borderRadius: widget.borderRadius!, child: child);
      }
      return child;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap != null ? _handleTapDown : null,
      onTapUp: widget.onTap != null ? _handleTapUp : null,
      onTapCancel: widget.onTap != null ? _handleTapCancel : null,
      child: IgnorePointer(
        child: clipIfNeeded(
          ColoredBox(
            color:
                widget.backgroundColor ??
                Theme.of(context).colorScheme.surfaceContainerLowest,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                // if there's a builder, then child should be obscured by the inks, as it will also be rendered inverted within them. (maybe it should be obscured anyway, maybe this should just be a distinct setting)
                if (widget.builder != null) widget.builder!(context, false),
                for (final ink in _wells) ink,
                if (widget.builder == null) widget.child!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InkWelling extends StatefulWidget {
  final RelAlignment origin;
  final Color color;
  final double fuzzyEdgeWidth;
  final AnimationController bloomController;
  final AnimationController fadeController;
  final Widget? child;
  final Color? fadeColor;
  final BorderRadius? borderRadius;
  final VoidCallback onFinished;

  const InkWelling({
    super.key,
    required this.origin,
    required this.color,
    this.fuzzyEdgeWidth = 12.0,
    this.borderRadius,
    this.fadeColor,
    required this.onFinished,
    required this.bloomController,
    required this.fadeController,
    this.child,
  });

  /// Reverse the bloom iff the bloom is still visible (early cancel).
  void cancel() {
    // if (bloomController.value < 0.5) {
    //   bloomController.reverse();
    // }
    fadeController.forward();
  }

  /// Fade opacity to zero (mouse release or late cancel).
  void confirm() => fadeController.forward();

  @override
  State<InkWelling> createState() => InkWellingState();
}

class InkWellingState extends State<InkWelling> with TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    void considerFinishing() {
      if (widget.fadeController.status == AnimationStatus.completed &&
          widget.bloomController.status == AnimationStatus.completed) {
        widget.onFinished();
      }
    }

    widget.fadeController.addStatusListener((_) {
      considerFinishing();
    });
    widget.bloomController.addStatusListener((_) {
      considerFinishing();
    });
  }

  @override
  void dispose() {
    widget.bloomController.dispose();
    widget.fadeController.dispose();
    super.dispose();
  }

  double colorFadep() {
    return unlerpUnit(0.6, 1, widget.bloomController.value);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          widget.bloomController,
          widget.fadeController,
        ]),
        builder: (context, child) {
          final color = lerpColor(
            widget.color,
            widget.fadeColor ?? widget.color,
            colorFadep(),
          );
          return Opacity(
            opacity:
                (1.0 -
                (widget.fadeController.value *
                    Curves.easeIn.transform(colorFadep()))),
            child: FuzzyCircleClip(
              progress: Curves.easeOutCubic.transform(
                unlerpUnit(0, 0.5, widget.bloomController.value),
              ),
              origin: widget.origin,
              fuzzyEdgeWidth: widget.fuzzyEdgeWidth,
              child: ColoredBox(color: color, child: child),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// animates from the previous state using an inkwell from epicenter
/// trivial to implement, so included mostly for illustrative purposes, but also because a lot of you are going to want it
class InvertToggleButton extends StatelessWidget {
  final bool isOn;

  /// the place at which the toggle was touched, or from which the
  final RelAlignment? epicenter;
  final Duration duration;
  final Widget Function(BuildContext context, bool isOn) builder;
  const InvertToggleButton({
    super.key,
    this.duration = const Duration(milliseconds: 140),
    required this.isOn,
    this.epicenter,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final animation = Tween<double>(begin: 0.0, end: 1.0);
    return TweenAnimationReplacementStack(
      animation: animation,
      duration: duration,
      builder: (context, progress, child) {
        return FuzzyCircleClip(
          fuzzyEdgeWidth: 6,
          progress: Curves.easeOutCubic.transform(progress),
          origin: epicenter ?? RelAlignment.center,
          child: child!,
        );
      },
      child: builder(context, isOn),
    );
  }
}

/// animates over the previous content, then when the animation is done, drops the previous contents from the state/build
class TweenAnimationReplacementStack extends StatefulWidget {
  final Tween animation;
  final ValueWidgetBuilder builder;
  final Duration duration;
  final Widget? child;
  const TweenAnimationReplacementStack({
    super.key,
    required this.animation,
    required this.builder,
    required this.duration,
    this.child,
  });

  @override
  State<TweenAnimationReplacementStack> createState() =>
      _TweenAnimationReplacementStackState();
}

class _TweenAnimationReplacementStackState
    extends State<TweenAnimationReplacementStack> {
  List<TweenAnimationReplacementStack> stack = [];

  /// The layer present at mount. It represents the resting state, so it must
  /// not play the entry/reveal animation the first time it appears (otherwise
  /// every one of these buttons animates in on its first build).
  TweenAnimationReplacementStack? _initial;

  @override
  didUpdateWidget(TweenAnimationReplacementStack oldWidget) {
    if (widget.animation != oldWidget.animation ||
        widget.builder != oldWidget.builder) {
      stack.add(widget);
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    super.initState();
    _initial = widget;
    stack = [widget];
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: stack
          .map(
            (e) => TweenAnimationBuilder(
              // The initial layer starts already at its end value so it shows
              // statically; later layers animate from begin to end as usual.
              tween: identical(e, _initial)
                  ? (Tween(begin: e.animation.end, end: e.animation.end))
                  : e.animation,
              duration: e.duration,
              builder: e.builder,
              child: e.child,
              onEnd: () {
                // remove all those prior to us when we complete
                int i = 0;
                for (final w in stack) {
                  if (w == e) {
                    break;
                  }
                  ++i;
                }
                setState(() {
                  stack.removeRange(0, i);
                });
              },
            ),
          )
          .toList(),
    );
  }
}

class RadioItem<T> extends StatefulWidget {
  final Function()? onTap;
  final Widget Function(BuildContext context, bool isOn) builder;
  final bool Function(T a, T b)? equalityComparison;
  final Signal<T> selection;
  final T me;
  final Duration duration;
  const RadioItem({
    super.key,
    this.onTap,
    required this.builder,
    required this.selection,
    this.duration = const Duration(milliseconds: 170),
    required this.me,
    this.equalityComparison,
  });
  @override
  State<RadioItem<T>> createState() => _RadioItemState<T>();
}

class _RadioItemState<T> extends State<RadioItem<T>> {
  bool isOn = false;
  Offset? tapUpPosition;
  Function() subscription = () {};
  @override
  void dispose() {
    subscription();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isOn =
        widget.equalityComparison?.call(widget.selection.peek(), widget.me) ??
        (widget.selection.peek() == widget.me);
    if (isOn) {
      subscription = widget.selection.subscribe((selection) {
        if (selection != widget.me) {
          setState(() {});
        }
        subscription();
      });
    }
    return GestureDetector(
      onTapUp: (details) => tapUpPosition = details.localPosition,
      onTap: () {
        widget.onTap?.call();
        if (widget.selection.value != widget.me) {
          widget.selection.value = widget.me;
          setState(() {});
        }
      },
      child: InvertToggleButton(
        isOn: isOn,
        duration: widget.duration,
        epicenter: tapUpPosition != null
            ? RelAlignment.fromOffset(tapUpPosition!)
            : RelAlignment.center,
        builder: widget.builder,
      ),
    );
  }
}

// I wish copyWith wasn't a huge operation
TextStyle textThemeFor(ThemeData theme, bool isOn) {
  return isOn
      ? theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onPrimary)
      : theme.textTheme.bodyMedium!;
}

Color foregroundColorFor(ThemeData theme, bool isOn) {
  return isOn ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
}

Color backgroundColorFor(ThemeData theme, bool isOn) {
  return isOn
      ? theme.colorScheme.primary
      : theme.colorScheme.surfaceContainerHigh;
}

class OurThemeData {
  Color lowestBackColor;

  /// indent colors are for subtle details like dividers, they don't have to contrast very well, only enough to *acknowledge*.
  Color lowestIndentColor;
  Color midBackColor;
  Color foreBackColor;
  Color foreIndentColor;
  Color inkColor;
  Color reducedProminenceColor;
  // todo: remove?
  Color harderForeIndentColor;
  Color hintTextColor;
  Color veryLowProminenceColor;
  bool hardEdges;

  /// Fill for a liquid-glass surface (the timer menu, drag rings). Already
  /// carries the translucency a glass tint wants, so it goes straight into a
  /// [GlassBlob]/fill — no extra alpha juggling. Content on top uses
  /// [onGlassColor]. When glass is off, use [nonGlassColor] instead; see
  /// [glassFill].
  Color glassColor;
  Color onGlassColor;

  /// Solid fill for those same surfaces when liquid glass is switched off:
  /// black on light theme, white on dark theme. Content on top uses
  /// [nonGlassOnSurface].
  Color nonGlassColor;
  Color nonGlassOnSurface;

  /// Corner radius of a timercule's backing panel. Roughly a quarter of a
  /// timercule's height; decoupled from buttonSpan so it doesn't scale with the
  /// control buttons.
  double timerculeBackingCornerRadius;

  /// Backdrop blur radius for liquid-glass surfaces; feed into [ourGlassOptions]
  /// so the app's glass look stays themeable rather than hardcoded per call site.
  double glassBlurRadius;

  /// Rim-darkening tint for liquid-glass surfaces; feed into [ourGlassOptions]'s
  /// [GlassOptions.edgeTint].
  Color edgeTint;

  OurThemeData({
    required this.lowestBackColor,
    required this.lowestIndentColor,
    required this.midBackColor,
    required this.foreBackColor,
    required this.foreIndentColor,
    required this.reducedProminenceColor,
    required this.inkColor,
    required this.harderForeIndentColor,
    required this.veryLowProminenceColor,
    required this.hintTextColor,
    required this.glassColor,
    required this.onGlassColor,
    required this.nonGlassColor,
    required this.nonGlassOnSurface,
    this.hardEdges = false,
    this.timerculeBackingCornerRadius = 23,
    this.glassBlurRadius = 13,
    this.edgeTint = const Color(0x26000000),
  });

  /// Fill for a glass-like surface: the translucent [glassColor] when liquid
  /// glass is on, the solid [nonGlassColor] when it's off.
  Color glassFill(bool glassOn) => glassOn ? glassColor : nonGlassColor;

  /// Content color to draw on top of [glassFill].
  Color onGlassFill(bool glassOn) => glassOn ? onGlassColor : nonGlassOnSurface;

  static OurThemeData fromContext(BuildContext context) {
    return fromTheme(Theme.of(context));
  }

  static OurThemeData fromTheme(ThemeData theme, {Brightness? brightness}) {
    return (brightness ?? theme.brightness) == Brightness.dark
        ? OurThemeData(
            lowestBackColor: theme.colorScheme.surfaceContainerLowest,
            midBackColor: theme.colorScheme.surfaceContainerLow,
            foreBackColor: theme.colorScheme.surfaceContainerHighest,
            reducedProminenceColor: darkenColor(
              theme.colorScheme.onSurface,
              0.27,
            ),
            veryLowProminenceColor: darkenColor(
              theme.colorScheme.onSurface,
              0.67,
            ),
            lowestIndentColor: lightenColor(
              theme.colorScheme.surfaceContainerLowest,
              0.03,
            ),
            foreIndentColor: darkenColor(
              theme.colorScheme.surfaceContainerHighest,
              0.03,
            ),
            harderForeIndentColor: darkenColor(
              theme.colorScheme.surfaceContainerHighest,
              0.35,
            ),
            inkColor: theme.colorScheme.primary.withAlpha(30),
            hintTextColor: darkenColor(theme.colorScheme.onSurface, 0.4),
            glassColor: lightenColor(
              theme.colorScheme.surfaceContainerHighest,
              0.1,
            ).withValues(alpha: 0.65),
            onGlassColor: theme.colorScheme.onSurface,
            nonGlassColor: Colors.white,
            nonGlassOnSurface: Colors.black,
            edgeTint: Colors.white.withValues(alpha: 0.7),
          )
        : OurThemeData(
            lowestBackColor: theme.colorScheme.surfaceContainerHighest,
            midBackColor: theme.colorScheme.surfaceContainerHigh,
            foreBackColor: theme.colorScheme.surfaceContainerLowest,
            reducedProminenceColor: lightenColor(
              theme.colorScheme.onSurface,
              0.66,
            ),
            veryLowProminenceColor: lightenColor(
              theme.colorScheme.onSurface,
              0.86,
            ),
            lowestIndentColor: darkenColor(
              theme.colorScheme.surfaceContainerHighest,
              0.05,
            ),
            foreIndentColor: darkenColor(
              theme.colorScheme.surfaceContainerLowest,
              0.03,
            ),
            harderForeIndentColor: darkenColor(
              theme.colorScheme.surfaceContainerLowest,
              0.1,
            ),
            inkColor: theme.colorScheme.primary.withAlpha(30),
            hintTextColor: lightenColor(theme.colorScheme.onSurface, 0.375),
            // glassColor: theme.colorScheme.primary.withValues(alpha: 0.8),
            // glassBlurRadius: 14,
            // onGlassColor: theme.colorScheme.onPrimary,
            glassColor: HSLColor.fromAHSL(0.45, 0, 0, 1).toColor(),
            onGlassColor: theme.colorScheme.onSurfaceVariant,
            // onGlassColor: theme.colorScheme.onSurface,
            nonGlassColor: Colors.black,
            nonGlassOnSurface: Colors.white,
            edgeTint: HSLColor.fromAHSL(0.2, 0, 0, 0.4).toColor(),
          );
  }

  /// The two background tones menu/settings-style screens use: content sits on
  /// [menuSurfaceFore], the heading band / page chrome on the slightly raised
  /// [menuSurfaceBack].
  Color get menuSurfaceFore => foreBackColor;
  Color get menuSurfaceBack => midBackColor;

  Color timerculeHighlightBackground(double depth) {
    final highlightLevels = <Color>[foreBackColor, harderForeIndentColor];
    final depthi = depth.floor();
    final depthp = (depth - depthi) % 1;
    final firstColor = highlightLevels[depthi % highlightLevels.length];
    final secondColor = highlightLevels[(depthi + 1) % highlightLevels.length];
    return lerpColor(firstColor, secondColor, depthp);
  }
}

/// Our standard [GlassOptions]. Differs from the package defaults only in a
/// crisper backdrop [blurRadius]; go through this so the app's glass look stays
/// consistent across the timer menu and drag rings. [blurRadius] and [edgeTint]
/// should come from [OurThemeData.glassBlurRadius] and [OurThemeData.edgeTint]
/// so they stay themeable.
GlassOptions ourGlassOptions({
  required double blurRadius,
  required Color edgeTint,
  GlassMode mode = GlassMode.glass,
  double blendRadius = 18,
}) => GlassOptions(
  mode: mode,
  blendRadius: blendRadius,
  blurRadius: blurRadius,
  edgeTint: edgeTint,
);

/// Eases [options] between a flat fill and full glass: at [glassiness] 0 the
/// refraction, shine, blur and bevel all vanish, leaving just the blobs' flat
/// tint color; at 1 it's the full glass in [options]. Lets a reveal solidify
/// the glass in without callers hand-multiplying each intensity.
GlassOptions glassLerpedToFlat(GlassOptions options, double glassiness) =>
    GlassOptions(
      mode: options.mode,
      blendRadius: options.blendRadius,
      shineDirection: options.shineDirection,
      motionShine: options.motionShine,
      shineIntensity: options.shineIntensity * glassiness,
      refractionIntensity: options.refractionIntensity * glassiness,
      blurRadius: options.blurRadius * glassiness,
      edgeTint: options.edgeTint.withValues(
        alpha: options.edgeTint.a * glassiness,
      ),
      bevelThickness: options.bevelThickness * glassiness,
    );

Positioned positionedAt(Offset offset, Widget child) {
  return Positioned(left: offset.dx, top: offset.dy, child: child);
}

class BoolSignalTween extends StatelessWidget {
  final ReadonlySignal<bool> signal;
  final Duration duration;
  final Widget Function(BuildContext context, double value, Widget? child)
  builder;
  final Widget? child;
  const BoolSignalTween({
    super.key,
    required this.signal,
    required this.builder,
    this.child,
    this.duration = const Duration(milliseconds: 300),
  });
  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) => TweenAnimationBuilder(
        tween: Tween<double>(
          begin: signal.value ? 1.0 : 0.0,
          end: signal.value ? 1.0 : 0.0,
        ),
        duration: duration,
        builder: builder,
        child: child,
      ),
    );
  }
}

class PinAnimation extends StatelessWidget {
  final Widget child;
  final ReadonlySignal<bool> isPinned;
  const PinAnimation({super.key, required this.child, required this.isPinned});
  @override
  Widget build(BuildContext context) {
    return BoolSignalTween(
      signal: isPinned,
      builder: (context, progress, child) {
        // final distance = 50 + squareRad + gap;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final r =
                      min(constraints.maxWidth, constraints.maxHeight) / 2;
                  final mt = OurThemeData.fromContext(context);
                  final movementp = Curves.easeOutCubic.transform(
                    unlerpUnit(0.4, 1, progress),
                  );
                  final revealp = unlerpUnit(0, 0.3, progress);
                  final squareRad = 7.0;
                  // it dawns on me that the pin is going to be kinda hard, since the easiest way to position it places it outside of the layout bounds of the parent, which means the pin will be outside of the linear clip.
                  // final pinThicknessr = 2.0;
                  // final pinLength = 15.0;
                  // final pinLengthTotal = pinThicknessr + pinLength;
                  final gap = 3;
                  final stabDistance = 20;
                  // final pinRetraction =
                  //     unlerpUnit((pinLength + gap) / pinLengthTotal, 1, movementp) *
                  //         pinLength;
                  final center = Offset(r, r);
                  final distance =
                      (lerp(r + stabDistance, r, movementp) + squareRad + gap) /
                      sqrt(2);
                  return SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        positionedAt(
                          center + Offset(-distance, -distance),
                          // I don't understand why the transforms need to be applied in this order
                          Transform.translate(
                            offset: Offset(-squareRad, -squareRad),
                            child: Transform.rotate(
                              origin: Offset(0, 0),
                              angle: -pi / 4,
                              child: FuzzyLinearClip(
                                angle: pi / 2,
                                fuzzyEdgeWidth: 3,
                                progress: revealp,
                                // the box
                                child: Container(
                                  alignment: Alignment.bottomCenter,
                                  decoration: BoxDecoration(
                                    color: mt.foreBackColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  width: squareRad * 2,
                                  height: squareRad * 2,
                                  // the pin
                                  // child: Transform.translate(
                                  //   offset: Offset(
                                  //       0,
                                  //       pinLength -
                                  //           pinThicknessr -
                                  //           pinRetraction),
                                  //   child: Container(
                                  //       width: pinThicknessr * 2,
                                  //       height: pinLengthTotal,
                                  //       decoration: BoxDecoration(
                                  //         borderRadius: BorderRadius.circular(
                                  //             pinThicknessr),
                                  //         color: mt.foreBackColor,
                                  //       )),
                                  // )
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            child!,
          ],
        );
      },
      child: child,
    );
  }
}

/// just spares you from needing to indent further and further
T nesting<T>(List<T Function(T)> nestingLevels, T deepestChild) {
  T result = deepestChild;
  for (final builder in nestingLevels.reversed) {
    result = builder(result);
  }
  return result;
}

List<T> intersperse<T>(T spacer, List<T> between) {
  List<T> ret = [];
  for (int i = 0; i < between.length - 1; ++i) {
    ret.add(between[i]);
    ret.add(spacer);
  }
  if (between.isNotEmpty) {
    ret.add(between.last);
  }
  return ret;
}

/// Places [container] within padding of [shrunkBy], but positions [child]
/// so that it overflows the container by [shrunkBy] on all sides,
/// effectively filling the original (pre-shrunk) space.
class ContainerShrunk extends StatelessWidget {
  final Widget Function(Widget child) container;
  final Widget child;
  final double shrunkBy;

  const ContainerShrunk({
    super.key,
    required this.container,
    required this.child,
    required this.shrunkBy,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Padding(
          padding: EdgeInsets.all(shrunkBy),
          child: container(
            OverflowBox(
              alignment: Alignment.center,
              maxWidth: constraints.maxWidth,
              maxHeight: constraints.maxHeight,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Same role as [Padding], but [EdgeInsets] may be negative on any edge.
/// [RenderPadding] requires [EdgeInsets.isNonNegative] (`shifted_box.dart`).
///
/// The child is laid out with minima from the deflated constraints and maxima
/// from the incoming constraints (same idea as wrapping it in [OverflowBox] with
/// [maxWidth]/[maxHeight] set to the parent's max). It is then centered in the
/// slot whose width/height are the deflated max when that axis is bounded, and
/// the child's size when unbounded—so small children sit centered when there is
/// slack (including from negative insets opening extra space), instead of
/// top-start alignment at [EdgeInsets.left]/[top] alone.
class SignedPadding extends SingleChildRenderObjectWidget {
  final EdgeInsets insets;

  const SignedPadding({super.key, required this.insets, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSignedPadding(padding: insets);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSignedPadding).padding = insets;
  }
}

class _RenderSignedPadding extends RenderShiftedBox {
  _RenderSignedPadding({required EdgeInsets padding, RenderBox? child})
    : _padding = padding,
      super(child);

  EdgeInsets get padding => _padding;
  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) {
      return;
    }
    _padding = value;
    markNeedsLayout();
  }

  BoxConstraints _childConstraints(BoxConstraints parent, EdgeInsets inset) {
    final inner = parent.deflate(inset);
    // For positive insets `inner.max <= parent.max`, so the child may grow to
    // the parent's max (the centering-overflow behavior described above). For
    // negative insets `deflate` *inflates* both min and max (it does
    // `min - horizontal` with horizontal < 0); capping max at `parent.max`
    // would then leave `inner.minWidth > parent.maxWidth` under a tight parent,
    // producing an invalid `minWidth > maxWidth` constraint. Taking the larger
    // of the two keeps the constraint valid and lets the child exceed the
    // parent by the negative inset, like OverflowBox.
    return BoxConstraints(
      minWidth: inner.minWidth,
      maxWidth: max(parent.maxWidth, inner.maxWidth),
      minHeight: inner.minHeight,
      maxHeight: max(parent.maxHeight, inner.maxHeight),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    if (child != null) {
      return child!.getMinIntrinsicWidth(max(0.0, height - _padding.vertical)) +
          _padding.horizontal;
    }
    return _padding.horizontal;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    if (child != null) {
      return child!.getMaxIntrinsicWidth(max(0.0, height - _padding.vertical)) +
          _padding.horizontal;
    }
    return _padding.horizontal;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    if (child != null) {
      return child!.getMinIntrinsicHeight(
            max(0.0, width - _padding.horizontal),
          ) +
          _padding.vertical;
    }
    return _padding.vertical;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    if (child != null) {
      return child!.getMaxIntrinsicHeight(
            max(0.0, width - _padding.horizontal),
          ) +
          _padding.vertical;
    }
    return _padding.vertical;
  }

  @override
  @protected
  Size computeDryLayout(covariant BoxConstraints constraints) {
    if (child == null) {
      return constraints.constrain(
        Size(_padding.horizontal, _padding.vertical),
      );
    }
    final inner = constraints.deflate(_padding);
    final childConstraints = _childConstraints(constraints, _padding);
    final Size childSize = child!.getDryLayout(childConstraints);
    final slotW = inner.hasBoundedWidth ? inner.maxWidth : childSize.width;
    final slotH = inner.hasBoundedHeight ? inner.maxHeight : childSize.height;
    return constraints.constrain(
      Size(_padding.horizontal + slotW, _padding.vertical + slotH),
    );
  }

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    if (child == null) {
      return null;
    }
    final inner = constraints.deflate(_padding);
    final childConstraints = _childConstraints(constraints, _padding);
    final Size childSize = child!.getDryLayout(childConstraints);
    final slotH = inner.hasBoundedHeight ? inner.maxHeight : childSize.height;
    final dy = _padding.top + (slotH - childSize.height) / 2;
    final BaselineOffset result =
        BaselineOffset(child!.getDryBaseline(childConstraints, baseline)) + dy;
    return result.offset;
  }

  @override
  void performLayout() {
    final BoxConstraints c = constraints;
    final EdgeInsets inset = _padding;
    if (child == null) {
      size = c.constrain(Size(inset.horizontal, inset.vertical));
      return;
    }
    final inner = c.deflate(inset);
    child!.layout(_childConstraints(c, inset), parentUsesSize: true);
    final slotW = inner.hasBoundedWidth ? inner.maxWidth : child!.size.width;
    final slotH = inner.hasBoundedHeight ? inner.maxHeight : child!.size.height;
    final BoxParentData childParentData = child!.parentData! as BoxParentData;
    childParentData.offset = Offset(
      inset.left + (slotW - child!.size.width) / 2,
      inset.top + (slotH - child!.size.height) / 2,
    );
    size = c.constrain(Size(inset.horizontal + slotW, inset.vertical + slotH));
  }
}

/// Tells a child what each of its edges abuts inside the enclosing
/// [EvenPadColumn]/[EvenPadRow], plus the flex's `padEdge`/`padSibling`
/// amounts. Each edge either abuts the flex's outer edge (`true`) or a
/// neighbouring child (`false`). On the main axis that's position: in a column
/// the leading child's [top] is an edge and its [bottom] a sibling (and vice
/// versa for the trailing child); interior children are siblings on both. On
/// the cross axis every child reports edges. With no enclosing flex everything
/// reads as a sibling.
///
/// The point: when you want a list to look evenly spaced, the end items usually
/// want a little extra space beyond them. The usual fix (padding on the
/// container) creates dead, unclickable space that looks wrong the moment the
/// end item is highlighted, and it puts the spacing decision in a different
/// place than the item. Instead, hand each item its edge-ness and let *it* pad
/// itself, keeping the padding part of the (clickable, highlightable) item.
/// Reporting the cross edges too means a child can absorb *all* of what would
/// have been container padding, not just the end caps. Reporting sibling edges
/// (with [padSibling]) lets the inter-item gaps live inside the items too.
@immutable
class ExtraPadding {
  /// Whether each edge abuts the flex's outer edge (`true`) rather than a
  /// neighbouring child (`false`).
  final bool top;
  final bool bottom;
  final bool left;
  final bool right;

  /// Amount applied to edge sides (unless [resolve] overrides it).
  final double padEdge;

  /// The *full* gap between two neighbours. Each of the two abutting children
  /// gets half of it (they share the gap), so a [padSibling] equal to [padEdge]
  /// makes the inter-item gaps match the end caps.
  final double padSibling;

  const ExtraPadding({
    this.top = false,
    this.bottom = false,
    this.left = false,
    this.right = false,
    this.padEdge = 0,
    this.padSibling = 0,
  });

  /// The fallback when there's no enclosing flex: every edge a sibling.
  static const outsideFlex = ExtraPadding();

  /// A copy with [padEdge]/[padSibling] swapped in where non-null — the hook an
  /// [EvenPadding] uses to override the flex's amounts.
  ExtraPadding withAmounts({double? padEdge, double? padSibling}) =>
      ExtraPadding(
        top: top,
        bottom: bottom,
        left: left,
        right: right,
        padEdge: padEdge ?? this.padEdge,
        padSibling: padSibling ?? this.padSibling,
      );

  /// The amount for an edge: a sibling edge takes half of [padSibling] (the gap
  /// is split between the two neighbours that share it); an edge side takes
  /// [override] if one was given, else [padEdge]. (Overrides only reach edge
  /// sides — that's what makes a per-edge `top:` bump the leading item's cap
  /// without also bumping every interior sibling.)
  double _amount(bool isEdge, double? override) =>
      isEdge ? (override ?? padEdge) : padSibling / 2;

  /// The inset for each edge — handy as the `padding` of the item itself.
  /// Edge sides default to [padEdge] but can be overridden by the most specific
  /// param given: per-edge [top]/[bottom]/[left]/[right] win, else per-axis
  /// [vertical]/[horizontal], else [all]. Sibling sides always take half of
  /// [padSibling].
  EdgeInsets resolve({
    double? all,
    double? horizontal,
    double? vertical,
    double? top,
    double? bottom,
    double? left,
    double? right,
  }) => EdgeInsets.only(
    top: _amount(this.top, top ?? vertical ?? all),
    bottom: _amount(this.bottom, bottom ?? vertical ?? all),
    left: _amount(this.left, left ?? horizontal ?? all),
    right: _amount(this.right, right ?? horizontal ?? all),
  );

  @override
  bool operator ==(Object other) =>
      other is ExtraPadding &&
      other.top == top &&
      other.bottom == bottom &&
      other.left == left &&
      other.right == right &&
      other.padEdge == padEdge &&
      other.padSibling == padSibling;

  @override
  int get hashCode =>
      Object.hash(top, bottom, left, right, padEdge, padSibling);
}

/// Per-slot scope an [EvenPadFlex] wraps around each child, carrying that
/// child's [ExtraPadding]. Interior children get one too so an [EvenPadBuilder]
/// always reads the *nearest* flex, never a farther ancestor.
class _EvenPadScope extends InheritedWidget {
  final ExtraPadding padding;
  const _EvenPadScope({required this.padding, required super.child});

  static ExtraPadding of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_EvenPadScope>()?.padding ??
      ExtraPadding.outsideFlex;

  @override
  bool updateShouldNotify(_EvenPadScope oldWidget) =>
      oldWidget.padding != padding;
}

/// Reads the [ExtraPadding] from the nearest enclosing [EvenPadColumn]/
/// [EvenPadRow] and hands it to [builder]. Outside any of those it gets
/// [ExtraPadding.outsideFlex].
class EvenPadBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, ExtraPadding extraPadding)
  builder;
  const EvenPadBuilder(this.builder, {super.key});

  @override
  Widget build(BuildContext context) =>
      builder(context, _EvenPadScope.of(context));
}

/// Pads [child] on the edges that abut the EvenPadFlex it's inside: outer edges
/// by the flex's `padEdge`, edges abutting a neighbour by its `padSibling` (a
/// no-op outside any flex). [padEdge]/[padSibling] here override the flex's
/// amounts for this child; the per-edge/per-axis/[all] amounts further override
/// the edge-side amount, with the same priority as [ExtraPadding.resolve]. This
/// is just [EvenPadBuilder] + that call without the closure.
class EvenPadding extends StatelessWidget {
  final double? padEdge;
  final double? padSibling;
  final double? all;
  final double? horizontal;
  final double? vertical;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final Widget child;
  const EvenPadding({
    super.key,
    this.padEdge,
    this.padSibling,
    this.all,
    this.horizontal,
    this.vertical,
    this.top,
    this.bottom,
    this.left,
    this.right,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: _EvenPadScope.of(context)
        .withAmounts(padEdge: padEdge, padSibling: padSibling)
        .resolve(
          all: all,
          horizontal: horizontal,
          vertical: vertical,
          top: top,
          bottom: bottom,
          left: left,
          right: right,
        ),
    child: child,
  );
}

/// A [Flex] whose children can ask (via [EvenPadBuilder]) whether they're the
/// leading/trailing item, so the ends can pad themselves. See [ExtraPadding].
/// Prefer the [EvenPadColumn]/[EvenPadRow] aliases.
///
/// Children may still be [Expanded]/[Flexible] — the per-slot scope is an
/// [InheritedWidget] (no render object), so flex parent data still reaches the
/// [RenderFlex] unchanged.
class EvenPadFlex extends StatelessWidget {
  final Axis direction;
  final List<Widget> children;
  final MainAxisAlignment mainAxisAlignment;
  final MainAxisSize mainAxisSize;
  final CrossAxisAlignment crossAxisAlignment;
  final TextDirection? textDirection;
  final VerticalDirection verticalDirection;
  final TextBaseline? textBaseline;

  /// [padEdge] is the space beyond each end item (the edges that abut this
  /// flex's outer edge); [padSibling] is the *full* gap between two neighbours,
  /// split half to each so it's directly comparable to [padEdge]. Either one
  /// defaults to the other when null, and both default to `0` — so passing just
  /// [padEdge] caps the ends only, just [padSibling] spaces between items only,
  /// and one value for both makes the end caps and inter-item gaps match. A
  /// child's [EvenPadding] can override these per item.
  final double? padEdge;
  final double? padSibling;

  const EvenPadFlex({
    super.key,
    required this.direction,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.mainAxisSize = MainAxisSize.max,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.textDirection,
    this.verticalDirection = VerticalDirection.down,
    this.textBaseline,
    this.padEdge,
    this.padSibling,
    this.children = const [],
  });

  double get _edge => padEdge ?? padSibling ?? 0;
  double get _sibling => padSibling ?? padEdge ?? 0;

  ExtraPadding _edgeFor(int i, int n, TextDirection textDirection) {
    final isLeading = i == 0;
    final isTrailing = i == n - 1;
    final ltr = textDirection == TextDirection.ltr;
    final down = verticalDirection == VerticalDirection.down;
    // A main-axis edge abuts the flex's end when it's the leading/trailing one,
    // otherwise the next child along; cross edges always abut the flex.
    if (direction == Axis.vertical) {
      // main = vertical (position), cross = horizontal (alignment).
      return ExtraPadding(
        top: down ? isLeading : isTrailing,
        bottom: down ? isTrailing : isLeading,
        left: true,
        right: true,
        padEdge: _edge,
        padSibling: _sibling,
      );
    }
    // main = horizontal (position), cross = vertical (alignment).
    return ExtraPadding(
      left: ltr ? isLeading : isTrailing,
      right: ltr ? isTrailing : isLeading,
      top: true,
      bottom: true,
      padEdge: _edge,
      padSibling: _sibling,
    );
  }

  @override
  Widget build(BuildContext context) {
    final td =
        textDirection ?? Directionality.maybeOf(context) ?? TextDirection.ltr;
    final n = children.length;
    return Flex(
      direction: direction,
      mainAxisAlignment: mainAxisAlignment,
      mainAxisSize: mainAxisSize,
      crossAxisAlignment: crossAxisAlignment,
      textDirection: td,
      verticalDirection: verticalDirection,
      textBaseline: textBaseline,
      children: [
        for (var i = 0; i < n; i++)
          _EvenPadScope(padding: _edgeFor(i, n, td), child: children[i]),
      ],
    );
  }
}

/// A [Column] whose leading/trailing children can pad themselves via
/// [EvenPadBuilder]. See [EvenPadFlex]/[ExtraPadding].
class EvenPadColumn extends EvenPadFlex {
  const EvenPadColumn({
    super.key,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.padEdge,
    super.padSibling,
    super.children,
  }) : super(direction: Axis.vertical);
}

/// A [Row] whose leading/trailing children can pad themselves via
/// [EvenPadBuilder]. See [EvenPadFlex]/[ExtraPadding].
class EvenPadRow extends EvenPadFlex {
  const EvenPadRow({
    super.key,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.padEdge,
    super.padSibling,
    super.children,
  }) : super(direction: Axis.horizontal);
}

void vibrationSampleBoard() async {
  Future<void> pause() => Future.delayed(const Duration(milliseconds: 2000));
  await Vibration.vibrate(
    pattern: [100, 100, 100, 100],
    intensities: [128, 64, 32, 16],
  );
  await pause();
  await Vibration.vibrate(
    pattern: [60, 60, 60, 60],
    intensities: [128, 64, 32, 16],
  );

  for (final preset in presets.keys) {
    await pause();
    await Vibration.vibrate(preset: preset);
  }
}

// we call it once at app start so that it doesn't check/delay every time
Future<bool> platformHasVibrator = Vibration.hasVibrator();

/// I'm fairly sure the returned future is meaningless, vibrationSampleBoard seemed to indicate that it resolves as soon as the vibration starts rather than when it ends
void vibrateAlertOnce() async {
  // await Vibration.vibrate(preset: VibrationPreset.pulseWave);
  if (await platformHasVibrator) {
    await Vibration.vibrate(
      pattern: [0, 120, 80, 50, 80, 120, 80, 120],
      intensities: [0, 200, 0, 255, 0, 200, 0, 200],
    );
  }
}

class HintToast extends SignalStatefulWidget {
  final Widget? child;
  final String? message;
  final ReadonlySignal<bool> showCondition;
  final bool startOpen;

  const HintToast({
    super.key,
    this.child,
    required this.showCondition,
    this.message,
    this.startOpen = false,
  });

  @override
  State<HintToast> createState() => _HintToastState();
}

/// A way of producing show conditions for hints that're shown one at a time, in sequence, each one until its underlying show condition turns false (ie, until the user takes the action that demonstrates that they've understood the lesson of the hint, so don't need to be shown it any more).
Computed<bool> addToSequence(
  Signal<int> sequenceCounter,
  List<Function()> effectDisposers,
  int ni,
  ReadonlySignal<bool> showCondition, {
  ReadonlySignal<bool>? urgentShow,
}) {
  // advance the sequence counter when our condition is complete and the sequence counter is with us
  effectDisposers.add(
    effect(() {
      if (sequenceCounter.value == ni && !showCondition.value) {
        sequenceCounter.value += 1;
      }
    }),
  );
  return Computed(
    () =>
        (urgentShow?.value ?? false) ||
        (sequenceCounter.value == ni && showCondition.value),
    autoDispose: true,
  );
}

class _HintToastState extends State<HintToast>
    with TickerProviderStateMixin, EffectsMixin<HintToast> {
  late AnimationController animation;

  @override
  void initState() {
    super.initState();

    animation = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 280),
    )..value = 0;
    Timer(Duration(milliseconds: 520), () {
      if (widget.showCondition.peek()) {
        animation.forward();
      }
    });

    createEffect(() {
      if (widget.showCondition.value) {
        animation.forward();
      } else {
        animation.reverse();
      }
    });
  }

  Widget infoText(BuildContext context, String content) {
    final hintColor = OurThemeData.fromContext(context).hintTextColor;
    final hintTextStyle = Theme.of(
      context,
    ).textTheme.bodyMedium!.copyWith(color: hintColor);
    return RichText(
      text: TextSpan(
        children: [
          WidgetSpan(
            child: Icon(Icons.info_rounded, size: 16, color: hintColor),
          ),
          WidgetSpan(child: SizedBox(width: 4)),
          TextSpan(style: hintTextStyle, text: content),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final v = animation.value;
        final isReversing = animation.status == AnimationStatus.reverse;
        final animateHeight = !widget.startOpen || isReversing;

        final double heightFraction;
        final double opacity;

        if (animateHeight) {
          heightFraction = unlerpUnit(0, 0.5, v);
          opacity = Curves.easeInOutCubic.transform(unlerpUnit(0.5, 1, v));
        } else {
          heightFraction = 1.0;
          opacity = Curves.easeInOutCubic.transform(unlerpUnit(0, 0.5, v));
        }

        return ClipRect(
          child: Align(
            heightFactor: heightFraction,
            alignment: Alignment.bottomCenter,
            child: Opacity(opacity: opacity, child: child),
          ),
        );
      },
      child: widget.child ?? infoText(context, widget.message!),
    );
  }
}

class SeparatorGradient extends StatelessWidget {
  final Color? color;
  final double height;
  const SeparatorGradient({super.key, this.color, this.height = 14});

  static double _easeInOut(double t) =>
      t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;

  static LinearGradient _gradient(Color col) {
    const steps = 4;
    final transparent = col.withAlpha(0);
    final colors = <Color>[];
    final stops = <double>[];
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      colors.add(Color.lerp(transparent, col, _easeInOut(t))!);
      stops.add(t * 0.5);
    }
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      colors.add(Color.lerp(transparent, col, _easeInOut(1 - t))!);
      stops.add(0.5 + t * 0.5);
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: colors,
      stops: stops,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = OurThemeData.fromContext(context);
    final col = color ?? theme.foreIndentColor;
    return Container(
      height: height,
      decoration: BoxDecoration(gradient: _gradient(col)),
    );
  }
}

// Returns the (circular radius, rectangle length) for a given progress, for animating a vertically-growing progress bar
(double, double) fluidBarRadiusAndHeightForProgress(
  double width,
  double height,
  double p,
) {
  // Compute geometric area allocations as above
  final circularArea = pi * width / 2 * width / 2;
  final rectangularArea = width * (height - width / 2);
  final totalArea = rectangularArea + circularArea;

  // circular phase
  double circularp = unlerpUnit(0, circularArea / totalArea, p);
  double radius = sqrt((circularp * circularArea) / pi);
  // rectangle "vertical" phase, after circle is fully grown
  double rectp = unlerpUnit(circularArea / totalArea, 1, p);
  double rectHeight = lerp(radius * 2, height, rectp);

  return (radius, rectHeight);
}

/// Geometry of a fluid bar: a rounded bar that first grows as a circle, then
/// lengthens along its longer axis into a line. Returns the bar's rounded-rect
/// and its corner radius.
///
/// Two independent alignments shape it:
///   * [lineOrigin] — its component along the longer axis
///     picks which end the circle sits at, and so which way the bar lengthens
///     from there. Its cross-axis component is ignored; the bar is always
///     centred on the cross axis.
///   * [circleOrigin] — a direction, within the circle's own radius, for where
///     the circle grows *out of*: while still small the circle pins its edge in
///     that direction and balloons away from it, easing back to concentric as it
///     reaches full radius. [Alignment.center] gives plain concentric growth.
(Rect, double) fluidBarGeometry(
  Size size,
  double progress, {
  Alignment lineOrigin = Alignment.center,
  Alignment circleOrigin = Alignment.center,
}) {
  final bool longIsHorizontal = size.width >= size.height;
  final double smallerDim = longIsHorizontal ? size.height : size.width;
  final double largerDim = longIsHorizontal ? size.width : size.height;
  final double maxRadius = smallerDim / 2;

  final (radius, length) = fluidBarRadiusAndHeightForProgress(
    smallerDim,
    largerDim,
    progress,
  );

  // How far the still-small circle clings off-centre; melts to 0 at full radius,
  // which keeps its [circleOrigin]-facing edge pinned as it grows.
  final double bias = maxRadius - radius;

  final double lineLong = longIsHorizontal ? lineOrigin.x : lineOrigin.y;
  final double circLong = longIsHorizontal ? circleOrigin.x : circleOrigin.y;
  final double circCross = longIsHorizontal ? circleOrigin.y : circleOrigin.x;

  // Long axis: the disc sits one max-radius in from the [lineOrigin] end, and the
  // bar lengthens from there toward the far side. [circleOrigin] nudges the small
  // circle along this axis too.
  final double dot =
      maxRadius + (lineLong + 1) / 2 * (largerDim - 2 * maxRadius);
  final double longTL = (dot - length / 2 + circLong * bias).clamp(
    0.0,
    largerDim - length,
  );
  // Cross axis: centred, with [circleOrigin]'s cross nudge.
  final double crossTL = (bias + circCross * bias).clamp(
    0.0,
    smallerDim - 2 * radius,
  );

  final Rect rect = longIsHorizontal
      ? Rect.fromLTWH(longTL, crossTL, length, 2 * radius)
      : Rect.fromLTWH(crossTL, longTL, 2 * radius, length);
  return (rect, radius);
}

Positioned fluidBar({
  required Size size,
  required double progress,
  required Alignment alignment,
  required Widget child,
}) {
  final (rect, _) = fluidBarGeometry(size, progress, lineOrigin: alignment);
  return Positioned(
    left: rect.left,
    top: rect.top,
    child: SizedBox(width: rect.width, height: rect.height, child: child),
  );
}

Positioned extrudedPositioned({
  required double extrusion,
  required Widget child,
}) {
  return Positioned(
    left: -extrusion,
    top: -extrusion,
    right: -extrusion,
    bottom: -extrusion,
    child: child,
  );
}

/// Shared layout for [TimerculeParallelPainter] and [TimerculeSerialPainter].
/// [Timerculedter] uses [timerculeIconRectHeight] as ring thickness.
const double timerculeIconRounding = 3;
const double timerculeIconRectHeight = 11;
const double timerculeIconRectWidth = 15;
const double timerculeIconGap = 3;
void timerculeIconScaling(Canvas canvas, Size size) {
  final parallelHeight = 2 * timerculeIconRectHeight + timerculeIconGap;
  final scale = min(size.width, size.height) / parallelHeight;
  canvas.translate(size.width / 2, size.height / 2);
  canvas.scale(scale, scale);
}

class TimerculeParallelPainter extends CustomPainter {
  final bool? rightJustified;
  TimerculeParallelPainter({this.color = Colors.black, this.rightJustified});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final contentH = 2 * timerculeIconRectHeight + timerculeIconGap;
    final topWidth = rightJustified == null
        ? timerculeIconRectWidth
        : timerculeIconRectHeight * 2 + timerculeIconGap;
    final bottomWidth = rightJustified == null ? topWidth : topWidth * 2 / 3;
    final bottomOffset = (rightJustified == null || !rightJustified!)
        ? -topWidth / 2
        : topWidth / 2 - bottomWidth;
    final cr = timerculeIconRounding;

    timerculeIconScaling(canvas, size);
    _drawRoundedPolygon(
      canvas,
      rightwardsArrowBox(
        Offset(-topWidth / 2, -contentH / 2),
        Size(topWidth, timerculeIconRectHeight),
        cr,
      ),
      color,
      cr,
    );
    _drawRoundedPolygon(
      canvas,
      rightwardsArrowBox(
        Offset(bottomOffset, timerculeIconGap / 2),
        Size(bottomWidth, timerculeIconRectHeight),
        cr,
      ),
      color,
      cr,
    );

    // canvas.drawRRect(
    //   RRect.fromRectAndRadius(
    //     Rect.fromLTWH(
    //       -topWidth / 2,
    //       -contentH / 2,
    //       topWidth,
    //       timerculeRectHeight,
    //     ),
    //     Radius.circular(timerculeCornerRadius),
    //   ),
    //   paint,
    // );
    // canvas.drawRRect(
    //   RRect.fromRectAndRadius(
    //     Rect.fromLTWH(
    //       bottomOffset,
    //       timerculeGap / 2,
    //       bottomWidth,
    //       timerculeRectHeight,
    //     ),
    //     Radius.circular(timerculeCornerRadius),
    //   ),
    //   paint,
    // );
  }

  @override
  bool shouldRepaint(TimerculeParallelPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.rightJustified != rightJustified;
}

class TimerculeSerialPainter extends CustomPainter {
  TimerculeSerialPainter({this.color = Colors.black});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // decided we want them to be square
    double w = timerculeIconRectHeight;
    timerculeIconScaling(canvas, size);
    _drawRoundedPolygon(
      canvas,
      rightwardsArrowBox(
        Offset(-w - timerculeIconGap / 2, -timerculeIconRectHeight / 2),
        Size(w, timerculeIconRectHeight),
        timerculeIconRounding,
      ),
      color,
      timerculeIconRounding,
    );
    _drawRoundedPolygon(
      canvas,
      rightwardsArrowBox(
        Offset(timerculeIconGap / 2, -timerculeIconRectHeight / 2),
        Size(w, timerculeIconRectHeight),
        timerculeIconRounding,
      ),
      color,
      timerculeIconRounding,
    );
  }

  @override
  bool shouldRepaint(TimerculeSerialPainter oldDelegate) =>
      oldDelegate.color != color;
}

Offset leftTangentPoint(Offset p, {required double r}) {
  final d2 = p.dx * p.dx + p.dy * p.dy;

  if (d2 <= r * r) {
    throw ArgumentError('Point must be outside the circle.');
  }

  final s = sqrt(d2 - r * r);

  final gx = (r * r * p.dx - r * p.dy * s) / d2;
  final gy = (r * r * p.dy + r * p.dx * s) / d2;

  return Offset(gx, gy);
}

double? rayCircleIntersectionDistance(
  Offset p, {
  required Offset dir,
  required double r,
}) {
  final pd = p.dx * dir.dx + p.dy * dir.dy;
  final pp = p.dx * p.dx + p.dy * p.dy;

  final discriminant = pd * pd - (pp - r * r);

  if (discriminant < 0) {
    return null; // no intersection
  }

  final s = sqrt(discriminant);

  final t1 = -pd - s;
  final t2 = -pd + s;

  // first positive intersection along the ray
  if (t1 >= 0) return t1;
  if (t2 >= 0) return t2;

  return null;
}

Offset? rayCircleIntersection(
  Offset p, {
  required Offset dir,
  required double r,
}) {
  final d = rayCircleIntersectionDistance(p, dir: dir, r: r);
  if (d == null) return null;
  return p + dir * d;
}

class TimerculeCyclePainter extends CustomPainter {
  TimerculeCyclePainter({this.color = Colors.black});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cr = timerculeIconRounding;
    final cr2 = cr * 2;
    // parameters
    final innerR = timerculeIconGap * 1.6 + cr;
    final topThickness = 0;
    final trs = 0.95 * timerculeIconRectHeight - cr2;
    final outerR = (topThickness + innerR * 2 + trs) / 2;
    final slotSpan = timerculeIconGap * 1.6 + cr2;

    final arrowProjection = sqrt(trs * trs / 3);
    final innerCenter = Offset(0, -outerR + topThickness + innerR);
    final arrowTipFromCenter = slotSpan / 2 - arrowProjection;
    final rightSlotTop =
        innerCenter +
        Offset(slotSpan / 2, sqrt(innerR * innerR - slotSpan * slotSpan / 4));
    final rightSlotBottom = Offset(
      slotSpan / 2,
      sqrt(outerR * outerR - slotSpan * slotSpan / 4),
    );
    final bottomArrowPoint = mirrorx(rightSlotBottom);
    final topArrowPoint = mirrorx(rightSlotTop);
    final arrowTip = Offset(
      -arrowTipFromCenter,
      (bottomArrowPoint.dy + topArrowPoint.dy) / 2,
    );

    final path = Path()
      ..moveToOffset(rightSlotTop)
      ..lineToOffset(rightSlotBottom)
      ..arcBetweenOffsets(
        start: rightSlotBottom,
        end: bottomArrowPoint,
        centerPoint: Offset.zero,
        clockwise: false,
      )
      ..lineToOffset(arrowTip)
      ..lineToOffset(topArrowPoint)
      ..arcBetweenOffsets(
        start: topArrowPoint,
        end: rightSlotTop,
        centerPoint: innerCenter,
        clockwise: true,
      );
    timerculeIconScaling(canvas, size);
    _drawRoundedPolygon(canvas, path, color, cr);
  }

  @override
  bool shouldRepaint(TimerculeCyclePainter oldDelegate) =>
      oldDelegate.color != color;
}

class TimerculeFlatterCyclePainter extends CustomPainter {
  TimerculeFlatterCyclePainter({this.color = Colors.black});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset.zero;
    final cr = timerculeIconRounding;
    final boxSize = Size(
      timerculeIconRectWidth * 0.5 - 2 * cr,
      timerculeIconRectHeight - 2 * cr,
    );
    final arcDiameter = 2 * cr + timerculeIconRectHeight * 0.24;
    final height = boxSize.height + arcDiameter;
    final boxPartWidth = boxSize.width + 2 * cr + timerculeIconGap;
    final boxTop = height / 2 - boxSize.height;
    // final width = boxPartWidth + arcDiameter/2;
    final arrowBoxUL =
        c + Offset(-boxPartWidth / 2, height / 2 - boxSize.height);

    void halfCircle(
      Path toPath, {
      required Offset start,
      required Offset end,
      required bool clockwise,
    }) {
      toPath.arcBetweenOffsets(
        start: start,
        end: end,
        centerPoint: (start + end) / 2,
        clockwise: clockwise,
      );
    }

    final r = Path();
    r.addPath(
      rightwardsArrowBoxWithoutCr(arrowBoxUL, boxSize, toClose: false),
      Offset.zero,
    );
    halfCircle(
      r,
      start: c + Offset(-boxPartWidth / 2, height / 2),
      end: c + Offset(-boxPartWidth / 2, -height / 2),
      clockwise: true,
    );
    r.lineToOffset(c + Offset(boxPartWidth / 2, -height / 2));
    halfCircle(
      r,
      start: c + Offset(boxPartWidth / 2, -height / 2),
      end: c + Offset(boxPartWidth / 2, height / 2),
      clockwise: true,
    );
    r.lineToOffset(c + Offset(boxPartWidth / 2, boxTop));
    halfCircle(
      r,
      start: c + Offset(boxPartWidth / 2, boxTop),
      end: c + Offset(boxPartWidth / 2, -height / 2),
      clockwise: false,
    );
    r.lineToOffset(c + Offset(-boxPartWidth / 2, -height / 2));
    halfCircle(
      r,
      start: c + Offset(-boxPartWidth / 2, -height / 2),
      end: c + Offset(-boxPartWidth / 2, boxTop),
      clockwise: false,
    );
    r.close();

    timerculeIconScaling(canvas, size);
    _drawRoundedPolygon(canvas, r, color, cr);
  }

  @override
  bool shouldRepaint(TimerculeFlatterCyclePainter oldDelegate) =>
      oldDelegate.color != color;
}

Widget timerKindIcon(
  TimerKind kind, {
  Color color = Colors.black,
  double size = 20,
}) {
  switch (kind) {
    case TimerKind.loop:
      return CustomPaint(
        size: Size(size, size),
        painter: TimerculeFlatterCyclePainter(color: color),
      );
    case TimerKind.series:
      return CustomPaint(
        size: Size(size, size),
        painter: TimerculeSerialPainter(color: color),
      );
    case TimerKind.parallelStartJustified:
      return CustomPaint(
        size: Size(size, size),
        painter: TimerculeParallelPainter(color: color, rightJustified: false),
      );
    case TimerKind.parallelEndJustified:
      return CustomPaint(
        size: Size(size, size),
        painter: TimerculeParallelPainter(color: color, rightJustified: true),
      );
    case TimerKind.stopwatch:
      return Icon(Icons.square_rounded, color: color, size: size);
    case TimerKind.timer:
      return Icon(Icons.circle_rounded, color: color, size: size);
  }
}

class SquishBoundaryPlane extends StatelessWidget {
  const SquishBoundaryPlane({super.key, required this.theme, required this.mt});

  final ThemeData theme;
  final OurThemeData mt;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 206, 24, 94),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: RotatedBox(
            quarterTurns: 3,
            child: Text(
              List.filled(7, 'SQUISH DANGER EDGE ').join(),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: theme.textTheme.labelSmall!.copyWith(color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }
}

class SpecialTimerShapesPainter extends CustomPainter {
  SpecialTimerShapesPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final hub = Offset(size.width / 2, size.height / 2);
    final scale = min(size.width, size.height) * 0.016;
    final formationRadius = 9.0 * scale;
    final formationStartAngle = -1.77;
    final double squareSide = 14 * scale;
    final double pillWidth = 15 * scale;
    final double pillHeight = 10 * scale;
    final squareRotation = -0.34;
    final triangleCircumradius = 7.6 * scale;
    final triangleGraphicRotation = pi;
    final pillRotation = -pi / 4;

    Offset polarSlot(int slot) {
      final a = formationStartAngle + slot * 2 * pi / 3;
      return hub + Offset(cos(a), sin(a)) * formationRadius;
    }

    final fill = Paint()..color = color;
    final sqC = polarSlot(0) + Offset(-scale * 1, -scale * 0.6) * 2;
    canvas.save();
    canvas.translate(sqC.dx, sqC.dy);
    canvas.rotate(squareRotation);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset.zero,
        width: squareSide,
        height: squareSide,
      ),
      fill,
    );
    canvas.restore();

    final pillC = polarSlot(1);
    canvas.save();
    canvas.translate(pillC.dx, pillC.dy);
    canvas.rotate(pillRotation);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset.zero,
          width: pillWidth,
          height: pillHeight,
        ),
        Radius.circular(pillHeight / 2),
      ),
      fill,
    );
    canvas.restore();

    final triC = polarSlot(2);
    final theta0 = -pi / 2 + triangleGraphicRotation;
    final triPath = Path();
    for (var k = 0; k < 3; k++) {
      final t = theta0 + k * 2 * pi / 3;
      final vx = triC.dx + triangleCircumradius * cos(t);
      final vy = triC.dy + triangleCircumradius * sin(t);
      if (k == 0) {
        triPath.moveTo(vx, vy);
      } else {
        triPath.lineTo(vx, vy);
      }
    }
    triPath.close();
    canvas.drawPath(triPath, fill);
  }

  @override
  bool shouldRepaint(covariant SpecialTimerShapesPainter oldDelegate) =>
      oldDelegate.color != color;
}

class SpecialTimerShapesLabel extends StatelessWidget {
  const SpecialTimerShapesLabel({required super.key});

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return ScalingAspectRatio(
      child: SizedBox(
        width: 50,
        height: 50,
        child: CustomPaint(painter: SpecialTimerShapesPainter(color: color)),
      ),
    );
  }
}

/// Builds the ManyIcon "C" path centered on [center]: an arc band between outer radius [outerR] and inner radius [innerR], with the gap on the right bounded by vertical edges sitting [edgeX] to the right of [center]. Right-handed orientation; mirror with [mirrorPathHorizontally] for left-handed.
Path buildManyIconPath({
  required Offset center,
  required double outerR,
  required double innerR,
  required double edgeX,
}) {
  final outerAngle = acos((edgeX / outerR).clamp(-1.0, 1.0));
  final outerRect = Rect.fromCircle(center: center, radius: outerR);

  final Path path;
  if (innerR >= edgeX) {
    final innerAngle = acos((edgeX / innerR).clamp(-1.0, 1.0));
    final innerRect = Rect.fromCircle(center: center, radius: innerR);
    path = Path()
      ..moveTo(
        center.dx + outerR * cos(-outerAngle),
        center.dy + outerR * sin(-outerAngle),
      )
      ..arcTo(outerRect, -outerAngle, -(tau - 2 * outerAngle), false)
      ..lineTo(
        center.dx + innerR * cos(innerAngle),
        center.dy + innerR * sin(innerAngle),
      )
      ..arcTo(innerRect, innerAngle, tau - 2 * innerAngle, false)
      ..close();
  } else {
    // The inner radius is too small to reach the right edge, so the inner
    // arc becomes a fully enclosed hole punched out of a solid wedge.
    path = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(
        center.dx + outerR * cos(-outerAngle),
        center.dy + outerR * sin(-outerAngle),
      )
      ..arcTo(outerRect, -outerAngle, -(tau - 2 * outerAngle), false)
      ..close();
    if (innerR > 0) {
      path.addOval(Rect.fromCircle(center: center, radius: innerR));
    }
  }
  return path;
}

Path mirrorPathHorizontally(Path path, double axisX) {
  final m = Matrix4.identity()
    ..translateByDouble(axisX, 0, 0, 1)
    ..scaleByDouble(-1.0, 1.0, 1.0, 1.0)
    ..translateByDouble(-axisX, 0, 0, 1);
  return path.transform(m.storage);
}

class ManyIconPainter extends CustomPainter {
  ManyIconPainter({required this.color, required this.isRightHanded});
  final Color color;
  final bool isRightHanded;

  /// Ring thickness as a fraction of the arc's radius: 1 collapses the inner  radius to the center. The right vertical edge of the shape always sits  thickness/2 of the radius to the right of the center.
  static const double thickness = 0.65;

  @override
  void paint(Canvas canvas, Size size) {
    final hub = Offset(size.width / 2, size.height / 2);
    final scale = min(size.width, size.height) * 0.04;
    // commented out: actual european CE logo proportions per https://ux.stackexchange.com/questions/155512/what-are-the-dimensions-proportions-of-the-ce-conformité-européenne-marking-lo/155513
    // final scale = min(size.width, size.height) * 0.024;
    final outerR = 6.0 * scale;
    // final outerR = 10.0 * scale;
    final innerR = outerR * (1 - thickness);
    final edgeX = outerR * thickness / 2;

    final fill = Paint()..color = color;
    final path = buildManyIconPath(
      center: hub,
      outerR: outerR,
      innerR: innerR,
      edgeX: edgeX,
    );
    canvas.drawPath(
      isRightHanded ? path : mirrorPathHorizontally(path, hub.dx),
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant ManyIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.isRightHanded != isRightHanded;
}

class ManyIcon extends SignalWidget {
  const ManyIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    final isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).value ?? true;
    return ScalingAspectRatio(
      child: SizedBox(
        width: 50,
        height: 50,
        child: CustomPaint(
          painter: ManyIconPainter(color: color, isRightHanded: isRightHanded),
        ),
      ),
    );
  }
}

class HamburgerIconPainter extends CustomPainter {
  HamburgerIconPainter({
    required this.color,
    required this.lineWidthp,
    required this.radiusp,
    this.hardEdge = false,
  });
  final Color color;
  final double lineWidthp;
  final double radiusp;

  /// Whether the bars use a square cap (true) or a round cap (false).
  final bool hardEdge;

  @override
  void paint(Canvas canvas, Size size) {
    final md = min(size.width, size.height);
    final radius = md * radiusp;
    final lineWidth = radius * lineWidthp;
    final paint = Paint()
      ..color = color
      ..strokeCap = hardEdge ? StrokeCap.square : StrokeCap.round
      ..strokeWidth = lineWidth;
    final x0 = size.width / 2 - radius;
    final x1 = size.width / 2 + radius;
    double y = size.height / 2 - radius;
    int n = 3;
    double ho = md / n;
    for (var i = 0; i < n; i++) {
      canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
      y += ho;
    }
  }

  @override
  bool shouldRepaint(covariant HamburgerIconPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.lineWidthp != lineWidthp ||
      oldDelegate.radiusp != radiusp ||
      oldDelegate.hardEdge != hardEdge;
}

/// A back chevron rendered as line art — a sideways "v" (`<`) of the given
/// stroke thickness, matching the rest of mako's line-art icons.
class ChevronBackIconPainter extends CustomPainter {
  ChevronBackIconPainter({required this.color, required this.lineWidth});
  final Color color;
  final double lineWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.miter;
    final spacing = 0;
    // scale s so that the icon is 1s w and 2s h, with spacing*s separating it from the edges
    final s = min(
      size.width / (1 + spacing * 2),
      size.height / (2 + spacing * 2),
    );

    final cx = size.width / 2;
    final cy = size.height / 2;
    final path = Path()
      ..moveTo(cx + s / 2, cy - s)
      ..lineTo(cx - s / 2, cy)
      ..lineTo(cx + s / 2, cy + s);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ChevronBackIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.lineWidth != lineWidth;
}

class ChevronBackIcon extends StatelessWidget {
  const ChevronBackIcon({
    super.key,
    required this.lineWidth,
    this.color,
    this.size,
  });
  final double lineWidth;
  final Color? color;
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return CustomPaint(
      size: size ?? Size(24, 24),
      painter: ChevronBackIconPainter(color: c, lineWidth: lineWidth),
    );
  }
}

/// actually only renders two bars rather than 3
class HamburgerIcon extends StatelessWidget {
  const HamburgerIcon({super.key, this.color, this.hardEdge = false});
  // todo: remove
  final Color? color;

  /// Whether the bars use a square cap (true) or a round cap (false).
  final bool hardEdge;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HamburgerIconPainter(
        color:
            color ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface,
        radiusp: 0.36,
        lineWidthp: 0.3,
        hardEdge: hardEdge,
      ),
    );
  }
}

/// Stroke + fill on the same path with rounded joins/caps; corners become arcs of radius [cornerRadius]. The path is inset by [cornerRadius] so the stroke stays inside the canvas.
void _drawRoundedPolygon(
  Canvas canvas,
  Path path,
  Color color,
  double cornerRadius,
) {
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = cornerRadius * 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round,
  );
  canvas.drawPath(path, Paint()..color = color);
}

class PaintedBackspaceIconPainter extends CustomPainter {
  PaintedBackspaceIconPainter({
    required this.color,
    required this.cornerRadius,
  });
  final Color color;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = leftwardsArrowBox(Offset.zero, size, cornerRadius);
    _drawRoundedPolygon(canvas, path, color, cornerRadius);
  }

  @override
  bool shouldRepaint(covariant PaintedBackspaceIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.cornerRadius != cornerRadius;
}

Path leftwardsArrowBox(Offset offset, Size size, double cornerRadius) {
  final left = offset.dx + cornerRadius;
  final right = offset.dx + size.width - cornerRadius;
  final top = offset.dy + cornerRadius;
  final bottom = offset.dy + size.height - cornerRadius;
  final sh = size.height - cornerRadius * 2;
  // (2*triw)^2 = (sh/2)^2 + triw^2
  final triW = sqrt(sh * sh / 12);

  return Path()
    ..moveTo(left + triW, top)
    ..lineTo(left, offset.dy + size.height / 2)
    ..lineTo(left + triW, bottom)
    ..lineTo(right, bottom)
    ..lineTo(right, top)
    ..close();
}

Path rightwardsArrowBox(
  Offset offsetUL,
  Size size,
  double cornerRadius, {
  bool toClose = true,
}) {
  return rightwardsArrowBoxWithoutCr(
    offsetUL + Offset(cornerRadius, cornerRadius),
    offsetToSize(
      sizeToOffset(size) - Offset(2 * cornerRadius, 2 * cornerRadius),
    ),
    toClose: toClose,
  );
}

Path rightwardsArrowBoxWithoutCr(
  Offset offsetUL,
  Size size, {
  bool toClose = true,
}) {
  final left = offsetUL.dx;
  final right = offsetUL.dx + size.width;
  final top = offsetUL.dy;
  final bottom = offsetUL.dy + size.height;
  final sh = size.height;
  // (2*triw)^2 = (sh/2)^2 + triw^2
  final triW = sqrt(sh * sh / 12);

  final r = Path()
    ..moveTo(left, top)
    ..lineTo(right - triW, top)
    ..lineTo(right, offsetUL.dy + size.height / 2)
    ..lineTo(right - triW, bottom)
    ..lineTo(left, bottom);
  if (toClose) {
    r.close();
  }
  return r;
}

class PaintedBackspaceIcon extends StatelessWidget {
  const PaintedBackspaceIcon({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  /// Width as a fraction of [size].
  static const double aspect = 1.2;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size * aspect,
      height: size,
      child: CustomPaint(
        painter: PaintedBackspaceIconPainter(
          color: c,
          cornerRadius: size * 0.2,
        ),
      ),
    );
  }
}

class PaintedPlayIconPainter extends CustomPainter {
  PaintedPlayIconPainter({required this.color, required this.cornerRadius});
  final Color color;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    // Inscribe an equilateral triangle pointing right inside the box.
    final triH = min(size.height, size.width * playIconDimensionRatio);
    final triW = triH / playIconDimensionRatio;
    final strokeSpan = triW * playIconDimensionRoundingp;
    final innerTriH = triH - strokeSpan;
    final innerTriW = triW - strokeSpan;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final baseX = cx - innerTriW / 2;
    final apexX = cx + innerTriW / 2;
    final topY = cy - innerTriH / 2;
    final bottomY = cy + innerTriH / 2;

    final path = Path()
      ..moveTo(baseX, topY)
      ..lineTo(apexX, cy)
      ..lineTo(baseX, bottomY)
      ..close();
    // The triangle is inset by strokeSpan/2 per side, so the stroke half-width
    // must be strokeSpan/2 to fill the box exactly. _drawRoundedPolygon doubles
    // its last arg into the stroke width, so pass strokeSpan/2 (-> width
    // strokeSpan) rather than strokeSpan (which bled strokeSpan/2 past each edge).
    _drawRoundedPolygon(canvas, path, color, strokeSpan / 2);
  }

  @override
  bool shouldRepaint(covariant PaintedPlayIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.cornerRadius != cornerRadius;
}

/// h = w * this
/// strokeWidth = w*roundingp
double playIconDimensionRatioForRoundingp(double roundingp) {
  final sr = sqrt(3 / 4);
  // ret = hp/wp
  // r = wp * roundingp
  // wp - r = sr*(hp - r)
  //   wp = sr*hp + r*(1 - sr)
  //   wp = hp*sr/(1 - rounding*(1 - sr))
  // ret = (1 - rounding*(1 - sr))/sr
  return (1 - roundingp * (1 - sr)) / sr;
}

double playIconDimensionRoundingp = 0.3;
double playIconDimensionRatio = playIconDimensionRatioForRoundingp(
  playIconDimensionRoundingp,
);

class PaintedPlayIcon extends StatelessWidget {
  const PaintedPlayIcon({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size * playIconDimensionRatio,
      child: CustomPaint(
        painter: PaintedPlayIconPainter(color: c, cornerRadius: size * 0.2),
      ),
    );
  }
}

Path _closedPolygon(List<Offset> points) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final p in points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

/// Morphs between a right-pointing play triangle ([t] == 0) and a two-bar
/// pause icon ([t] == 1) sharing the play icon's exact resting geometry, so at
/// [t] == 0 it is pixel-identical to [PaintedPlayIconPainter].
///
/// The triangle is split down the middle into two pieces that pull apart into
/// the two pause bars. The left piece is a 4-corner trapezoid that flattens
/// into the left bar. The right piece is the triangle's tip and carries five
/// vertices: its right side keeps the apex as a (stationary) midpoint, while
/// the two vertices that sit partway down the hypotenuse slide up to become the
/// right bar's top-right and bottom-right corners. The pieces overlap slightly
/// at the seam in the play state so the rounded stroke leaves no notch where it
/// crosses the hypotenuse.
class PausePlayIconPainter extends CustomPainter {
  PausePlayIconPainter({required this.color, required this.t});
  final Color color;

  /// 0 = play triangle, 1 = pause bars.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final triH = min(size.height, size.width * playIconDimensionRatio);
    final triW = triH / playIconDimensionRatio;
    final strokeSpan = triW * playIconDimensionRoundingp;
    final innerTriH = triH - strokeSpan;
    final innerTriW = triW - strokeSpan;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final baseX = cx - innerTriW / 2;
    final apexX = cx + innerTriW / 2;
    final topY = cy - innerTriH / 2;
    final bottomY = cy + innerTriH / 2;
    final apex = Offset(apexX, cy);

    // seam down the middle of the triangle, where the two halves meet
    final splitX = baseX + innerTriW * 0.37;
    double hypoTopY(double x) => lerp(topY, cy, (x - baseX) / innerTriW);
    double hypoBotY(double x) => lerp(bottomY, cy, (x - baseX) / innerTriW);
    final splitTopY = hypoTopY(splitX);
    final splitBotY = hypoBotY(splitX);

    // pause bar width (two bars + gap = three equal thirds of the box width)
    final barW = innerTriW * 0.16;
    // in the play state the left half reaches slightly past the seam so the
    // right half covers its rounded seam corner (and vice versa).
    final seamOverlap = 0;
    final leftSeamX = splitX + seamOverlap;
    // the two "partway down the hypotenuse" vertices, as a fraction from seam
    // to apex along each slanted edge.
    const slantFrac = 0.5;

    Offset lp(Offset play, Offset pause) => lerpOffset(play, pause, t);

    final leftPiece = _closedPolygon([
      lp(Offset(baseX, topY), Offset(baseX, topY)),
      lp(Offset(leftSeamX, hypoTopY(leftSeamX)), Offset(baseX + barW, topY)),
      lp(Offset(leftSeamX, hypoBotY(leftSeamX)), Offset(baseX + barW, bottomY)),
      lp(Offset(baseX, bottomY), Offset(baseX, bottomY)),
    ]);

    final rightPiece = _closedPolygon([
      lp(Offset(splitX, splitTopY), Offset(apexX - barW, topY)),
      lp(
        lerpOffset(Offset(splitX, splitTopY), apex, slantFrac),
        Offset(apexX, topY),
      ),
      lp(apex, Offset(apexX, cy)),
      lp(
        lerpOffset(Offset(splitX, splitBotY), apex, slantFrac),
        Offset(apexX, bottomY),
      ),
      lp(Offset(splitX, splitBotY), Offset(apexX - barW, bottomY)),
    ]);

    _drawRoundedPolygon(canvas, leftPiece, color, strokeSpan / 2);
    _drawRoundedPolygon(canvas, rightPiece, color, strokeSpan / 2);
  }

  @override
  bool shouldRepaint(covariant PausePlayIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.t != t;
}

/// Play icon that tweens to a pause icon while [playing] is true (and back).
class PausePlayIcon extends StatelessWidget {
  const PausePlayIcon({
    super.key,
    required this.playing,
    this.size = 24,
    this.color,
    this.duration = const Duration(milliseconds: 125),
  });
  final bool playing;
  final double size;
  final Color? color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final c =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size * playIconDimensionRatio,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: playing ? 1.0 : 0.0),
        duration: duration,
        curve: Curves.easeInOut,
        builder: (context, t, child) => CustomPaint(
          painter: PausePlayIconPainter(color: c, t: t),
        ),
      ),
    );
  }
}

class Thumbspan {
  /// measured in logical pixels
  double thumbspan;
  Thumbspan(this.thumbspan);
  static double of(BuildContext context, {bool listen = false}) {
    return Provider.of<Thumbspan>(context, listen: listen).thumbspan;
  }
}

/// We use a checkbox other than the native one, because the native one will feel dated due to the slider fad, but we're sure as shit not using sliders
class RoundedCheckbox extends StatelessWidget {
  const RoundedCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.dimWhenFalse = false,
    this.size = 20.0,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final double size;
  final bool dimWhenFalse;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final outlineColor = color;
    final radius = Radius.circular(size * 0.3);
    final innerInset = size * 0.22;
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: value ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 130),
        builder: (context, t, _) {
          final tt = Curves.easeOutExpo.transform(t);
          final borderColor = dimWhenFalse
              ? Color.lerp(Colors.grey, outlineColor, tt)!
              : outlineColor;
          return SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _RoundedCheckboxPainter(
                innerScale: tt,
                color: color,
                borderColor: borderColor,
                radius: radius,
                innerInset: innerInset,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RoundedCheckboxPainter extends CustomPainter {
  const _RoundedCheckboxPainter({
    required this.innerScale,
    required this.color,
    required this.borderColor,
    required this.radius,
    required this.innerInset,
  });

  final double innerScale;
  final Color color;
  final Color borderColor;
  final Radius radius;
  final double innerInset;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.1;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final outerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        strokeWidth / 2,
        strokeWidth / 2,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      radius,
    );
    canvas.drawRRect(outerRect, borderPaint);
    if (innerScale > 0) {
      final fillPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      final maxW = size.width - innerInset * 2;
      final maxH = size.height - innerInset * 2;
      final w = maxW * innerScale;
      final h = maxH * innerScale;
      final innerRect = RRect.fromRectAndRadius(
        Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h),
        Radius.circular(radius.x * 0.6 * innerScale),
      );
      canvas.drawRRect(innerRect, fillPaint);
    }
  }

  @override
  bool shouldRepaint(_RoundedCheckboxPainter old) =>
      old.innerScale != innerScale ||
      old.color != color ||
      old.borderColor != borderColor;
}

/// How a [ManyStateCheckbox] is filled. Each state is the inner fill rectangle
/// expressed as fractions of the inner area (0,0 = top-left, 1,1 =
/// bottom-right), so transitions between any two states animate as a smooth
/// rectangle sweep. [none] collapses to the centre point (invisible).
enum CheckboxFill {
  none(0.5, 0.5, 0.5, 0.5),
  on(0.0, 0.0, 1.0, 1.0),
  smallOn(0.28, 0.28, 0.72, 0.72),
  topHalf(0.0, 0.0, 1.0, 0.5),
  bottomHalf(0.0, 0.5, 1.0, 1.0),
  leftHalf(0.0, 0.0, 0.5, 1.0),
  rightHalf(0.5, 0.0, 1.0, 1.0);

  const CheckboxFill(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;

  Rect get rect => Rect.fromLTRB(left, top, right, bottom);
}

/// A multi-state sibling of [RoundedCheckbox]: instead of a bool it shows one of
/// [CheckboxFill] — empty, fully/partly filled, or a half. Purely
/// presentational; tapping just calls [onTap] and the owner decides the next
/// state.
class ManyStateCheckbox extends StatelessWidget {
  const ManyStateCheckbox({
    super.key,
    required this.fill,
    required this.onTap,
    this.size = 20.0,
  });

  final CheckboxFill fill;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final radius = Radius.circular(size * 0.3);
    final innerInset = size * 0.22;
    final target = fill.rect;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: TweenAnimationBuilder<Rect?>(
        tween: RectTween(begin: target, end: target),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutExpo,
        builder: (context, fillFractions, _) {
          return SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _ManyStateCheckboxPainter(
                fillFractions: fillFractions ?? target,
                color: color,
                borderColor: color,
                radius: radius,
                innerInset: innerInset,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ManyStateCheckboxPainter extends CustomPainter {
  const _ManyStateCheckboxPainter({
    required this.fillFractions,
    required this.color,
    required this.borderColor,
    required this.radius,
    required this.innerInset,
  });

  /// The fill rectangle in inner-area fractions (see [CheckboxFill]).
  final Rect fillFractions;
  final Color color;
  final Color borderColor;
  final Radius radius;
  final double innerInset;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.width * 0.1;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final outerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        strokeWidth / 2,
        strokeWidth / 2,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      radius,
    );
    canvas.drawRRect(outerRect, borderPaint);
    if (fillFractions.width > 0.001 && fillFractions.height > 0.001) {
      final innerW = size.width - innerInset * 2;
      final innerH = size.height - innerInset * 2;
      final fillRect = Rect.fromLTRB(
        innerInset + innerW * fillFractions.left,
        innerInset + innerH * fillFractions.top,
        innerInset + innerW * fillFractions.right,
        innerInset + innerH * fillFractions.bottom,
      );
      final fillPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, Radius.circular(radius.x * 0.6)),
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ManyStateCheckboxPainter old) =>
      old.fillFractions != fillFractions ||
      old.color != color ||
      old.borderColor != borderColor;
}

/// A settings row laid out like a [ListTile] — optional [title] over [subtitle]
/// on the left, optional [trailing] on the right, vertically centred with a
/// minimum height — but driven by [InkButton] so the press feedback is our own
/// [InkWelling] ink rather than Material's. Because that ink is painted by the
/// InkButton itself (not registered with the nearest [Material] surface), these
/// rows need no Material ancestor and their feedback can't leak onto the wrong
/// canvas. [InkButton] wraps its child in an [IgnorePointer], so a [trailing]
/// widget is display-only; the whole row toggles via [onTap].
class MenuTile extends StatelessWidget {
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Receives the global tap position before [onTap] fires — used where the tap
  /// point seeds a transition origin (e.g. a [CircularRevealRoute]).
  final ValueChanged<Offset>? onTapUpGlobalPosition;
  final EdgeInsetsGeometry? contentPadding;
  const MenuTile({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onTapUpGlobalPosition,
    this.contentPadding,
  });

  static const double defaultPaddingTotal = 16;
  static const double defaultPaddingInside = 8;

  /// Side of the fixed, centred slot the [trailing] item is dropped into. Being
  /// a fixed height it also holds the row open, and callers pass [trailing] bare
  /// (no need to size or centre it themselves).
  static const double trailingSlotSpan = 40.0;

  @override
  Widget build(BuildContext context) {
    // Vertical breathing room: keep top/bottom at least the horizontal inset so
    // single-line rows aren't cramped (the [trailingSlot] height also holds the
    // row open). The trailing item supplies its own end spacing via its slot, so
    // no right inset is added to the text when a trailing is present.
    final base =
        (contentPadding ??
                const EdgeInsets.only(
                  left: defaultPaddingInside,
                  top: defaultPaddingInside,
                  bottom: defaultPaddingInside,
                ))
            .resolve(Directionality.of(context));
    final textPadding = EdgeInsets.fromLTRB(
      base.left,
      base.top,
      trailing == null ? base.right : 0.0,
      base.bottom,
    );
    return InkButton(
      backgroundColor: Colors.transparent,
      // Rectangular clip so the ink stays within this row (matching a
      // contained ListTile) rather than blooming into its neighbours.
      borderRadius: BorderRadius.zero,
      onTap: onTap,
      onTapUpGlobalPosition: onTapUpGlobalPosition,
      // [textPadding] always insets by [defaultPaddingInside]; in an
      // [EvenPadColumn] this tops that up to [defaultPaddingTotal] on whichever
      // edges abut the section (the leading tile's top, the trailing tile's
      // bottom, and — with a stretched column — every tile's sides), so the
      // section's outer gap matches the inter-tile gap. The top-up sits *inside*
      // the ink, so the highlight covers it; outside an EvenPad flex it's a
      // no-op.
      child: EvenPadding(
        all: defaultPaddingTotal - defaultPaddingInside,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: trailingSlotSpan),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: textPadding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null) title!,
                      if (subtitle != null) subtitle!,
                    ],
                  ),
                ),
              ),
              if (trailing != null)
                SizedBox(
                  width: trailingSlotSpan + defaultPaddingInside * 2,
                  height: trailingSlotSpan + defaultPaddingInside * 2,
                  child: Center(child: trailing!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class RoundedCheckboxListTile extends StatelessWidget {
  const RoundedCheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;
  final Widget? title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return MenuTile(
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      trailing: RoundedCheckbox(
        value: value,
        onChanged: (v) => onChanged(v),
        size: 24,
      ),
      onTap: () => onChanged(!value),
    );
  }
}

class FutureSliver<T> extends StatefulWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  final Widget loading;
  const FutureSliver({
    super.key,
    required this.future,
    required this.builder,
    this.loading = const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.all(24.0),
        child: Center(child: CircularProgressIndicator()),
      ),
    ),
  });

  @override
  State<FutureSliver<T>> createState() => _FutureSliverState<T>();
}

class _FutureSliverState<T> extends State<FutureSliver<T>> {
  T? _value;

  @override
  void initState() {
    super.initState();
    widget.future.then((v) {
      if (mounted) setState(() => _value = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (value == null) return widget.loading;
    return widget.builder(context, value);
  }
}

/// A section presented as a rounded card inset from the screen edges. The card
/// is a [Material] with a [borderRadius] and `clipBehavior`, which is what makes
/// it correct rather than a sliver clip: a [ListTile]'s ink (splash/highlight)
/// paints on its nearest [Material] ancestor, so the card must *be* that
/// ancestor for the ink to be clipped to the rounded corners — a sliver-level
/// clip can't touch ink painted on a Material above it. Because [Material] is a
/// box, the [child] is a box (wrapped in a [SliverToBoxAdapter] here); these
/// sections are small, so that costs no meaningful laziness. [color] fills the
/// card, [padding] insets the content, and [margin] is the gap to the screen
/// edges and to the card above.
class RoundedSectionSliver extends StatelessWidget {
  final Widget child;
  final Color color;

  /// Corner radius of the card. Defaults to the screen's corner radius minus the
  /// horizontal [margin], so the card's rounding sits concentric with the
  /// rounded screen corners it's inset from.
  final double? radius;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  static const double defaultMargin = 12;
  const RoundedSectionSliver({
    super.key,
    required this.child,
    required this.color,
    this.radius,
    this.margin = const EdgeInsets.fromLTRB(defaultMargin, 0, defaultMargin, 0),
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final horizontalInset = margin.resolve(Directionality.of(context)).left;
    final cornerRadius = getReasonableAestheticBottomCornerRadius();
    final screenRounding = max(
      max(cornerRadius, cornerRadius),
      max(cornerRadius, cornerRadius),
    );
    final r = radius ?? max(0.0, screenRounding - horizontalInset);
    return SliverPadding(
      padding: margin,
      sliver: SliverToBoxAdapter(
        child: Material(
          type: MaterialType.canvas,
          color: color,
          borderRadius: BorderRadius.circular(r),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class PadStateIcon extends StatelessWidget {
  final ReadonlySignal<bool> signal;
  const PadStateIcon({super.key, required this.signal});

  @override
  Widget build(BuildContext context) {
    return BoolSignalTween(
      signal: signal,
      duration: Duration(milliseconds: 600),
      // duration: Duration(milliseconds: 190),
      builder: (context, progress, _) {
        final theme = Theme.of(context);
        final longDimension = 22 / 4 * 3;
        final shortDimension = 22.0;
        final hpu = 0.37;
        final h = lerp(
          shortDimension,
          longDimension,
          Curves.easeInOutCubic.transform(unlerpUnit(0, hpu, progress)),
        );
        final w = lerp(
          longDimension,
          shortDimension,
          Curves.easeInOutCubic.transform(unlerpUnit(1 - hpu, 1, progress)),
        );
        final movementp = Curves.easeInOutQuad.transform(1 - progress);
        final centeredInset = (longDimension - shortDimension) / 2;
        return SizedBox(
          width: longDimension,
          height: longDimension,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                width: w,
                height: h,
                top: lerp(0, centeredInset, movementp),
                right: lerp(centeredInset, 0, movementp),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        );
        // a far simpler, prettier, but slightly less informational or characterful version, should be run in 200ms:
        // return SizedBox(
        //   width: lerp(
        //     longDimension,
        //     shortDimension,
        //     Curves.easeIn.transform(progress),
        //   ),
        //   height: lerp(
        //     shortDimension,
        //     longDimension,
        //     Curves.easeOut.transform(progress),
        //   ),
        //   child: Container(
        //     decoration: BoxDecoration(
        //       color: theme.colorScheme.primary,
        //       borderRadius: BorderRadius.circular(4),
        //     ),
        //   ),
        // );
      },
    );
  }
}

/// A single [GestureRecognizer] for an inline [TextSpan] that fires both a tap
/// and a long press, by forwarding pointers to an inner tap + long-press pair
/// (a TextSpan only accepts one recognizer, and each detector competes in the
/// gesture arena as usual).
class _TapAndLongPressRecognizer extends GestureRecognizer {
  _TapAndLongPressRecognizer({
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) : _tap = (TapGestureRecognizer()..onTap = onTap),
       _longPress = (LongPressGestureRecognizer()..onLongPress = onLongPress);

  final TapGestureRecognizer _tap;
  final LongPressGestureRecognizer _longPress;

  @override
  void addPointer(PointerDownEvent event) {
    _tap.addPointer(event);
    _longPress.addPointer(event);
  }

  @override
  String get debugDescription => 'tapAndLongPress';

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {}

  @override
  void dispose() {
    _tap.dispose();
    _longPress.dispose();
    super.dispose();
  }
}

/// Renders markdown links as tap-to-open, long-press-to-copy-URL. Registering
/// a builder for the 'a' tag replaces flutter_markdown_plus's built-in link
/// handling entirely (for every link), so tap-to-open is reimplemented here
/// alongside the long-press addition. The link is emitted as a plain [TextSpan]
/// (not a widget/WidgetSpan) so it shares the surrounding paragraph's exact text
/// metrics, wrapping and scaling; [baseStyle] is passed in explicitly rather
/// than relying on the sometimes-sizeless inherited [parentStyle].
class LinkElementBuilder extends MarkdownElementBuilder {
  LinkElementBuilder({required this.baseStyle, required this.linkStyle});

  final TextStyle baseStyle;
  final TextStyle linkStyle;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final href = element.attributes['href'];
    final text = element.textContent;
    if (href == null) return Text(text, style: baseStyle);
    return Text.rich(
      TextSpan(
        text: text,
        style: baseStyle.merge(linkStyle),
        recognizer: _TapAndLongPressRecognizer(
          onTap: () => launchUrl(Uri.parse(href)),
          onLongPress: () async {
            await Clipboard.setData(ClipboardData(text: href));
            HapticFeedback.mediumImpact();
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Copied "$href"')));
            }
          },
        ),
      ),
    );
  }
}

enum InkBand { lowercase, capitals, digits }

/// Ink-band centers above the baseline in em (upm 1000). Dongle and DongleLatin
/// share identical glyph outlines, so these hold for either font.
/// Measured from the TTFs (fontTools BoundsPen over each band's charset):
///   band        Regular   Bold
///   digits      0.1975    0.2025
///   capitals    0.1875    0.1875
///   lowercase   0.1450    0.1465
/// The constants below are the Regular values; Bold digits run 0.0045 em
/// hotter, which is sub-pixel at our sizes (0.2px at fontSize 40).
const _bandCenterEm = {
  InkBand.lowercase: 0.145,
  InkBand.capitals: 0.188,
  InkBand.digits: 0.198,
};

/// The layout-box center above the baseline, in em. With
/// TextLeadingDistribution.even this equals (ascent - descent) / 2 for any
/// `height`, so it depends only on the font's metrics:
///   Dongle       850/-598 (USE_TYPO_METRICS off) -> 0.126
///   DongleLatin  670/-380 (typo metrics)         -> 0.145
/// Must match whichever font BandCenteredText renders. Currently Dongle.
/// Verified empirically (test/font_metrics_probe_test.dart): Flutter reports
/// 0.126 for Dongle at every height/leadingDistribution combination we use.
const _lineBoxCenterEm = 0.126;

/// The paint-space nudge (positive = down) that moves [band]'s ink center onto
/// the line box's center. Use this to band-center a widget that isn't a plain
/// string (see [BandCenteredText] for those).
double inkBandDy(InkBand band, double fontSize) =>
    (_bandCenterEm[band]! - _lineBoxCenterEm) * fontSize;

class BandCenteredText extends StatelessWidget {
  const BandCenteredText(
    this.data, {
    super.key,
    this.style,
    this.band = InkBand.lowercase,
    this.overflow,
  });
  final String data;
  final TextStyle? style;
  final InkBand band;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final fontSize =
        style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    final dy = inkBandDy(band, fontSize);
    return Transform.translate(
      offset: Offset(0, dy), // digits/caps: pushes down ~0.04-0.05 em
      child: Text(data, style: style, overflow: overflow),
    );
  }
}
