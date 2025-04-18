// the boring file is where we put things that're either self-explanatory or just small and fragmented and not very relevant to understanding the core structure of the application

import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

const tau = 2 * pi;

class JukeBox {
  static final AssetSource pianoSound =
      AssetSource('sounds/piano sound 448552__tedagame__g4.ogg');
  // static const String jarringSound = 'assets/jarring.mp3';
  late AudioPool jarringPlayers;
  static Future<JukeBox> create() async {
    return AudioPool.create(
      source: pianoSound,
      maxPlayers: 4,
    ).then((pool) => JukeBox()..jarringPlayers = pool);
  }

  static void jarringSound(BuildContext context) {
    context.read<Future<JukeBox>>().then((jb) {
      jb.jarringPlayers.start();
    });
  }
}

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

/// ceilab is better for interpollation but in most cases it doesn't matter and also the cielab library I tried seemed to have compilation errros in it
Color lerpColor(Color a, Color b, double t) {
  return Color.from(
    alpha: lerp(a.a, b.a, t),
    red: lerp(a.r, b.r, t),
    green: lerp(a.g, b.g, t),
    blue: lerp(a.b, b.b, t),
  );
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

const List<int> datetimeSectionLengths = [2, 2, 2, 3, 4];
const List<int> datetimeSectionOffsets = [0, 2, 4, 6, 9];
const List<int> datetimeMaxima = [60, 60, 24, 365];

int padLevelFor(int digitLength) {
  return datetimeSectionOffsets.indexWhere((s) => s >= digitLength);
}

/// if d is greater than the number of given padLevel, eg, if it's 25 hours and place is 3 (which means show seconds, minutes and hours), it will still automatically show 1 day, 1 hour, and zero minutes and seconds. padLevel is for making sure enough places are shown in numbers that are too low.
/// d: `List<int> | Duration`
String formatTime(Object d, {int padLevel = 0}) {
  List<int> digits =
      d is List<int> ? d : durationToDigits(d as Duration, padLevel: padLevel);

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

/// where padLevel is the number of figures to include as 0 values if the duration isn't really that long
List<int> durationToDigits(Duration d, {int padLevel = 1}) {
  List<int> digits = [];
  bool started = false;
  int days = d.inDays;
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
  if (started || d.inHours % 24 > 0 || padLevel > 2) {
    pushDigits(digits, d.inHours % 24, 2);
    started = true;
  }
  // Minutes
  if (started || d.inMinutes % 60 > 0 || padLevel > 1) {
    pushDigits(digits, d.inMinutes % 60, 2);
    started = true;
  }
  // Seconds
  if (started || d.inSeconds % 60 > 0 || padLevel > 0) {
    pushDigits(digits, d.inSeconds % 60, 2);
  }

  return digits;
}

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
  String formatted = formatTime(sd, padLevel: 3);
  assert(formatted == '20173:001:02:03:04');

  final d = Duration(days: 1 + 2017 * 365, hours: 2, minutes: 3, seconds: 4);
  final digits = durationToDigits(d);
  final convertedBack = digitsToDuration(digits);
  assert(d == convertedBack);
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
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: PiePainter(
              value: 1.0, // Full circle for the background
              color: backgroundColor,
            ),
          ),
          CustomPaint(
            size: Size(size, size),
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
