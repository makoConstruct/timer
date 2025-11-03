// the boring file is where we put things that're either self-explanatory or just small and fragmented and not very relevant to understanding the core structure of the application

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_manager/flutter_ringtone_manager.dart';
import 'package:hsluv/hsluvcolor.dart';

// import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
// import 'package:flutter_soloud/flutter_soloud.dart' as sl;

import 'platform_audio.dart';

const tau = 2 * pi;

// Using platform audio for content:// URI support (for using system ringtones)
class JukeBox {
  static Future<JukeBox> create() async {
    return Future.value(JukeBox());
  }

  Future<void> playAudio(AudioInfo a) async {
    await PlatformAudio.playAudio(a);
  }

  Future<void> playJarringSound() async {
    // Get the user's actual default notification sound
    final defaultSound =
        await PlatformAudio.getDefaultAudio(PlatformAudioType.notification);
    await playAudio(defaultSound!);
  }

  static void jarringSound(BuildContext context) {
    Provider.of<Future<JukeBox>>(context, listen: false).then((jb) {
      jb.playJarringSound();
    });
  }
}

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
                                Curves.easeOut.transform(popAnimation.value) *
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
  final cpro = k.currentContext!.findRenderObject() as RenderBox;
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
  final dx = to.dx - from.dx;
  final dy = to.dy - from.dy;
  return atan2(dy, dx);
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

double unlerp(double a, double b, double t) {
  return (t - a) / (b - a);
}

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

const List<int> datetimeSectionLengths = [2, 2, 2, 3, 4];
const List<int> datetimeSectionOffsets = [0, 2, 4, 6, 9];
const List<int> datetimeMaxima = [60, 60, 24, 365];

const appName = "mako timer";
const foregroundNotificationText =
    "this foreground task is ready to continue running any active timers in case the app closes. It will close with the app if no timers were running.";

int padLevelFor(int digitLength) {
  return datetimeSectionOffsets.indexWhere((s) => s >= digitLength);
}

/// if d is greater than the number of given padLevel, eg, if it's 25 hours and place is 3 (which means show seconds, minutes and hours), it will still automatically show 1 day, 1 hour, and zero minutes and seconds. padLevel is for making sure enough places are shown in numbers that are too low.
String formatTime(List<int> digits, {int padLevel = 0}) {
  String ret = "";
  // the index of the next digit to be printed
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
  // print("${s.width}x${s.height}dpi:$dpi");
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
