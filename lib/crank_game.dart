import 'dart:math';
import 'package:flutter/material.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/main.dart' show maybeFlippedBackgroundColors;
import 'package:makos_timer/mobj.dart';

class CrankGameScreen extends StatefulWidget {
  final GlobalKey? iconKey;
  final bool flipBackgroundColors;
  final bool byAngularSpeed;

  const CrankGameScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
    this.byAngularSpeed = false,
  });

  @override
  State<CrankGameScreen> createState() => _CrankGameScreenState();
}

class CrankGameTheme {
  final Color tooSlowColor;
  final Color withinBoundsColor;
  final Color wonColor;
  final Color tooFastColor;

  CrankGameTheme({
    required this.tooSlowColor,
    required this.withinBoundsColor,
    required this.wonColor,
    required this.tooFastColor,
  });

  static CrankGameTheme light = CrankGameTheme(
    tooSlowColor: const Color(0xff5bcef5),
    withinBoundsColor: const Color(0xff17e351),
    wonColor: darkenColor(Colors.amber, 0.1),
    tooFastColor: const Color(0xffdcd026),
  );
  static CrankGameTheme dark = CrankGameTheme(
    tooFastColor: const Color(0xFFD7D752),
    withinBoundsColor: const Color(0xff13bb3a),
    wonColor: Colors.amber,
    tooSlowColor: const Color(0xFF5bcdf5),
  );

  static CrankGameTheme fromContext(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }
}

class _CrankGameScreenState extends State<CrankGameScreen>
    with SingleTickerProviderStateMixin {
  // Game parameters
  double targetSpeed = 1.0; // rotations per second
  late double nextTargetSpeed = _nextTargetSpeed(); // rotations per second
  double windowSeconds = 0.5; // averaging window
  double errorMargin =
      0.1; // allowed deviation from target (in rotations per second)
  double durationToWin = 5.0; // seconds of consistent cranking to win
  double punishmentRate =
      1.3; // score lost per second when outside error bounds

  // Game state
  double _crankAngle = -pi / 4;
  double _progress = 0.0; // 0 to 1, represents how close to winning
  bool _isDragging = false;
  bool _hasWon = false;
  String? _currentWinMessage;

  // Speed tracking
  final List<_AngleSample> _angleSamples = [];
  double _currentSpeed = 0.0; // rotations per second

  late AnimationController _tickController;
  DateTime? _lastTickTime;
  late Mobj<int> _winMessageIndexMobj;

  static List<String> winMessages = [
    "You're one step closer to attaining the clock nature.",
    "You possess clock virtue.",
    "The clocks recognize you.",
    "I went to the clock zone and they all said they knew you.",
    "You possess the clock nature.",
    "You have demonstrated the passions and virtues of the clock.",
    "You have attained the status of \"Nehomme Sochronoi\".",
    "You are a clock.",
    "With these abilities, in theory, you can keep your own time.",
  ];
  String _takeNextWinMessage() {
    int c = _winMessageIndexMobj.peek()!;
    _winMessageIndexMobj.value = (c + 1) % winMessages.length;
    return winMessages[c % winMessages.length];
  }

  double _nextTargetSpeed() {
    return lerp(0.2, 2.7, Random().nextDouble());
  }

  @override
  void initState() {
    super.initState();
    _winMessageIndexMobj =
        Mobj.getAlreadyLoaded(crankGameWinMessageIndexID, const IntType());
    _tickController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _tickController.addListener(_tick);
  }

  @override
  void dispose() {
    _tickController.dispose();
    super.dispose();
  }

  void _win() {
    setState(() {
      _progress = 1.0;
      _currentWinMessage = _takeNextWinMessage();
      _hasWon = true;
    });
  }

  void _tick() {
    final now = DateTime.now();
    if (_lastTickTime == null) {
      _lastTickTime = now;
      return;
    }

    final dt = now.difference(_lastTickTime!).inMicroseconds / 1e6;
    _lastTickTime = now;

    // Calculate current speed from samples
    _calculateCurrentSpeed(now);

    // Update progress based on whether we're within error bounds
    if (_isDragging) {
      final speedError = (_currentSpeed - targetSpeed).abs();
      if (speedError <= errorMargin) {
        // Within bounds - increase progress
        _progress += dt / durationToWin;
        if (_progress >= 1.0 && !_hasWon) {
          _win();
        }
      } else {
        // Outside bounds - decrease progress
        _progress -= dt * punishmentRate / durationToWin;
        if (_progress < 0.0) _progress = 0.0;
      }
    } else {
      // Not dragging - slowly decrease progress
      _progress -= dt * 0.5 / durationToWin;
      if (_progress < 0.0) _progress = 0.0;
    }

    setState(() {});
  }

  void _calculateCurrentSpeed(DateTime now) {
    // Remove old samples outside the window
    final cutoff = now.subtract(Duration(
      milliseconds: (windowSeconds * 1000).round(),
    ));
    _angleSamples.removeWhere((s) => s.time.isBefore(cutoff));

    if (_angleSamples.length < 2) {
      _currentSpeed = 0.0;
      return;
    }

    // Calculate total angle change over the window
    double totalAngleChange = 0.0;
    for (int i = 1; i < _angleSamples.length; i++) {
      totalAngleChange += _angleSamples[i].angle - _angleSamples[i - 1].angle;
    }

    // Convert to rotations per second
    final windowDuration = _angleSamples.last.time
            .difference(_angleSamples.first.time)
            .inMicroseconds /
        1e6;
    if (windowDuration > 0) {
      _currentSpeed = (totalAngleChange / (2 * pi)) / windowDuration;
    }
  }

  void _onPanStart(DragStartDetails details) {
    _isDragging = true;
    _angleSamples.clear();
  }

  void _onPanUpdate(
      DragUpdateDetails details, Offset dialCenter, double crankRadius) {
    final prevPos = details.globalPosition - details.delta;
    final angularChange = shortestAngleDistance(angleFrom(dialCenter, prevPos),
        angleFrom(dialCenter, details.globalPosition));
    _crankAngle = _crankAngle +
        (widget.byAngularSpeed
                ? angularChange
                : details.delta.distance / (crankRadius * 0.67)) *
            (angularChange < 0 ? -1 : 1);
    _angleSamples.add(_AngleSample(DateTime.now(), _crankAngle));

    setState(() {});
  }

  void _onPanEnd(DragEndDetails details) {
    _isDragging = false;
    _angleSamples.clear();
  }

  void _resetGame() {
    setState(() {
      _progress = 0.0;
      _hasWon = false;
      _currentSpeed = 0.0;
      targetSpeed = nextTargetSpeed;
      nextTargetSpeed = _nextTargetSpeed();
      _angleSamples.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crankGameTheme = CrankGameTheme.fromContext(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, widget.flipBackgroundColors);
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;

    final outerDiameter = screenWidth * 0.8;
    final innerDiameter = screenWidth * 0.1;
    final dialCenterX = screenWidth * 0.5;
    final dialCenterY =
        screenWidth * 0.5; // bottom: 0.5w means center is at 0.5w from bottom

    // dialCenter in global coordinates (for pan gesture calculation)
    final dialCenter = Offset(dialCenterX, screenHeight - dialCenterY);

    final barBottom = screenWidth * 0.8;
    final barThickness = 50.0;
    return Scaffold(
      backgroundColor: backgroundColorA,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
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
            ),
            const SizedBox(width: 8),
            Text(
              'Crank Game',
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        backgroundColor: backgroundColorA,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          // Progress bar on the right
          Positioned(
            right: 24,
            top: 24,
            bottom: barBottom,
            child: _ProgressBar(
              thickness: barThickness,
              progress: _progress,
              isWithinBounds: _isDragging &&
                  (_currentSpeed - targetSpeed).abs() <= errorMargin,
              isTooSlow: _currentSpeed < targetSpeed - errorMargin,
              hasWon: _hasWon,
            ),
          ),

          // Difficulty slider on the left
          Positioned(
            left: 24,
            top: 24,
            bottom: barBottom,
            child: _DifficultySlider(
              thickness: barThickness,
              value: errorMargin,
              onChanged: (v) => setState(() => errorMargin = v),
            ),
          ),

          // Speed indicator
          Positioned(
            left: barThickness + 40,
            right: barThickness + 40,
            top: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Speed: ${_currentSpeed.toStringAsFixed(2)} rps',
                  style: theme.textTheme.bodyLarge,
                ),
                Text(
                  'Target: ${targetSpeed.toStringAsFixed(2)} rps',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _hasWon
                      ? 'You won!'
                      : _isDragging
                          ? (_currentSpeed - targetSpeed).abs() / targetSpeed <=
                                  errorMargin
                              ? 'Good!'
                              : _currentSpeed < targetSpeed * (1 - errorMargin)
                                  ? 'Faster!'
                                  : 'Slower!'
                          : "Please simply rotate the dial at ${targetSpeed.toStringAsFixed(2)}rps for five seconds",
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: !_isDragging
                        ? theme.colorScheme.onSurfaceVariant
                        : (_currentSpeed - targetSpeed).abs() <= errorMargin
                            ? crankGameTheme.withinBoundsColor
                            : _currentSpeed < targetSpeed - errorMargin
                                ? crankGameTheme.tooSlowColor
                                : crankGameTheme.tooFastColor,
                  ),
                ),
                const SizedBox(height: 8),
                RotatedBox(
                  quarterTurns: -1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'difficulty (error margin)',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${errorMargin.toStringAsFixed(2)}s',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Crank dial
          Positioned(
            left: dialCenterX - outerDiameter / 2,
            bottom: dialCenterY - outerDiameter / 2,
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: (details) =>
                  _onPanUpdate(details, dialCenter, outerDiameter / 2),
              onPanEnd: _onPanEnd,
              child: SizedBox(
                width: outerDiameter,
                height: outerDiameter,
                child: CustomPaint(
                  painter: _CrankDialPainter(
                    angle: _crankAngle,
                    outerDiameter: outerDiameter,
                    innerDiameter: innerDiameter,
                    backgroundColor: theme.colorScheme.surfaceContainerLow,
                    surfaceColor: theme.colorScheme.surfaceContainerHighest,
                    isDragging: _isDragging,
                  ),
                ),
              ),
            ),
          ),
          // Win overlay
          if (_hasWon)
            Positioned.fill(
              child: GestureDetector(
                onTap: _resetGame,
                child: Container(
                  color: theme.colorScheme.surfaceContainerLowest,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 30.0, right: 30.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.access_time_rounded,
                            size: 64,
                            color: crankGameTheme.wonColor,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            textAlign: TextAlign.center,
                            'Successfully produced high purity rotation at ${targetSpeed.toStringAsFixed(2)} rotations per second',
                            style: theme.textTheme.headlineLarge?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 30.0),
                            child: Text(
                              textAlign: TextAlign.center,
                              _currentWinMessage!,
                              style: theme.textTheme.headlineLarge?.copyWith(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(height: 30.0),
                          Text(
                            'Tap for next challenge (${nextTargetSpeed.toStringAsFixed(2)}rps)',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AngleSample {
  final DateTime time;
  final double angle;

  _AngleSample(this.time, this.angle);
}

class _CrankDialPainter extends CustomPainter {
  final double angle;
  final double outerDiameter;
  final double innerDiameter;
  final Color surfaceColor;
  final Color backgroundColor;
  final bool isDragging;

  _CrankDialPainter({
    required this.angle,
    required this.outerDiameter,
    required this.innerDiameter,
    required this.surfaceColor,
    required this.backgroundColor,
    required this.isDragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerGap = 0.05;
    final innerGap = 0.05;
    final handleRadius =
        ((1 - 2 * outerGap - innerGap) / 2) * outerDiameter / 2;
    final handleDistance = (innerGap / 2) * outerDiameter + handleRadius;
    final handlePaint = Paint()
      ..color = surfaceColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerDiameter / 2, handlePaint);
    handlePaint.color = backgroundColor;
    canvas.drawCircle(center + angleToOffset(angle) * handleDistance,
        handleRadius, handlePaint);
    canvas.drawCircle(center + angleToOffset(angle + pi) * handleDistance,
        handleRadius, handlePaint);
  }

  @override
  bool shouldRepaint(_CrankDialPainter oldDelegate) {
    return angle != oldDelegate.angle || isDragging != oldDelegate.isDragging;
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  final bool isWithinBounds;
  final bool isTooSlow;
  final bool hasWon;
  final double thickness;

  const _ProgressBar({
    required this.progress,
    required this.isWithinBounds,
    required this.isTooSlow,
    required this.hasWon,
    this.thickness = 24,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // it must first expand as a circle before it begins to advance vertically

    return LayoutBuilder(
      builder: (context, constraints) {
        final rectangularHeight = constraints.maxHeight - thickness / 2;
        final crankGameTheme = CrankGameTheme.fromContext(context);
        final rectangularArea = thickness * rectangularHeight;
        final circularArea = pi * thickness / 2 * thickness / 2;
        final totalArea = rectangularArea + circularArea;
        final startingp = circularArea / totalArea * 0.33;
        final augmentedProgress = lerp(startingp, 1, progress);
        final radius = sqrt(
            (unlerpUnit(0, circularArea / totalArea, augmentedProgress) *
                    circularArea) /
                pi);
        final verticalProgress =
            unlerpUnit(circularArea / totalArea, 1, augmentedProgress);
        return Container(
            width: thickness,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(thickness / 2),
              // border: Border.all(
              //   color: theme.colorScheme.outline.withValues(alpha: 0.3),
              //   width: 1,
              // ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: thickness / 2 - radius,
                  bottom: thickness / 2 - radius,
                  child: Container(
                    // duration: const Duration(milliseconds: 100),
                    width: radius * 2,
                    height: lerp(
                        radius * 2, constraints.maxHeight, verticalProgress),
                    decoration: BoxDecoration(
                      color: isWithinBounds
                          ? crankGameTheme.withinBoundsColor
                          : isTooSlow
                              ? crankGameTheme.tooSlowColor
                              : crankGameTheme.tooFastColor,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  ),
                ),
              ],
            ));
      },
    );
  }
}

class _DifficultySlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double thickness;
  static const double minError = 0.05;
  static const double maxError = 0.24;

  const _DifficultySlider({
    required this.value,
    required this.onChanged,
    this.thickness = 24,
  });

  // Logarithmic interpolation: convert normalized 0-1 to error margin
  static double _toErrorMargin(double normalized) {
    // log interpolation: minError * (maxError/minError)^normalized
    return minError * pow(maxError / minError, normalized).toDouble();
  }

  // Inverse: convert error margin to normalized 0-1
  static double _toNormalized(double errorMargin) {
    // inverse of above: log(errorMargin/minError) / log(maxError/minError)
    return log(errorMargin / minError) / log(maxError / minError);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Invert: higher bar = lower error margin = harder
    final normalized = 1 - _toNormalized(value.clamp(minError, maxError));
    final innerThickness = thickness * 0.64;

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onVerticalDragUpdate: (details) {
            // Invert: dragging up increases difficulty (lowers error margin)
            final newNormalized =
                (details.localPosition.dy / constraints.maxHeight)
                    .clamp(0.0, 1.0);
            onChanged(_toErrorMargin(newNormalized));
          },
          onTapDown: (details) {
            final newNormalized =
                (details.localPosition.dy / constraints.maxHeight)
                    .clamp(0.0, 1.0);
            onChanged(_toErrorMargin(newNormalized));
          },
          child: Container(
            width: thickness,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(thickness / 2),
            ),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Positioned(
                  bottom: thickness / 2 - innerThickness / 2,
                  child: Container(
                      width: innerThickness,
                      height: (constraints.maxHeight -
                              (thickness - innerThickness)) *
                          normalized,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(innerThickness / 2),
                      )),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
