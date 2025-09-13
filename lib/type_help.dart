import 'mobj.dart';

class TimerData {
  /// the last time the timer was started
  late final DateTime startTime;

  /// whether it's paused/playing/completed
  final int runningState;
  bool get isRunning => runningState == running;
  bool get isCompleted => runningState == completed;
  static const paused = 0;
  static const running = 1;
  static const completed = 2;

  /// the hue of the (pastel) color, in [0,1)
  final double hue;

  /// whether it's currently being edited (shouldn't that be persisted via "currently selected")
  final bool selected;

  /// the digit form of duration. Used when tapping out or backspacing numbers. Not always kept up to date with duration..
  final List<int> digits;

  /// the amount of time in seconds it ran before being paused (ignored if not paused, or if completed)
  final Duration ranTime;

  /// if the alarm is currently screaming and needs to be acknowledged by the user
  final bool isGoingOff;

  TimerData({
    DateTime? startTime,
    this.runningState = paused,
    required this.hue,
    required this.selected,
    this.digits = const [],
    this.ranTime = Duration.zero,
    this.isGoingOff = false,
  }) {
    this.startTime = startTime ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  TimerData withChanges({
    // fortunately we never need to set startTime to null :/ dart's optional parameter syntax doesn't support that
    DateTime? startTime,
    int? runningState,
    double? hue,
    bool? selected,
    List<int>? digits,
    Duration? ranTime,
    bool? isGoingOff,
  }) {
    return TimerData(
      startTime: startTime ?? this.startTime,
      runningState: runningState ?? this.runningState,
      hue: hue ?? this.hue,
      selected: selected ?? this.selected,
      digits: digits ?? this.digits,
      ranTime: ranTime ?? this.ranTime,
      isGoingOff: isGoingOff ?? this.isGoingOff,
    );
  }

  TimerData toggleRunning({required bool reset}) => isRunning
      ? reset
          ? withChanges(runningState: TimerData.paused, ranTime: Duration.zero)
          : withChanges(
              runningState: TimerData.paused,
              ranTime: DateTime.now().difference(startTime))
      : reset
          ? withChanges(
              runningState: TimerData.running,
              ranTime: Duration.zero,
              startTime: DateTime.now())
          :
          // still resets if it was completed
          runningState == TimerData.completed
              ? withChanges(
                  runningState: TimerData.running,
                  ranTime: Duration.zero,
                  startTime: DateTime.now())
              : withChanges(
                  runningState: TimerData.running,
                  ranTime: ranTime,
                  startTime: DateTime.now().subtract(ranTime));
}

class TimerDataType extends TypeHelp<TimerData> {
  const TimerDataType() : super('TimerData');

  @override
  TimerData fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return TimerData(
        startTime: Nullable(const DateTimeType()).fromJson(json['startTime']),
        runningState: const IntType().fromJson(json['runningState']),
        hue: const DoubleType().fromJson(json['hue']),
        selected: const BoolType().fromJson(json['selected']),
        digits: ListType(const IntType()).fromJson(json['digits']),
        ranTime: Duration(
            milliseconds:
                (DoubleType().fromJson(json['ranTime']) * 1000).toInt()),
        isGoingOff: const BoolType().fromJson(json['isGoingOff']),
      );
    }
    throw ArgumentError('Cannot convert $json to TimerData');
  }

  @override
  Object? toJsonValue(TimerData object) {
    return {
      'startTime': Nullable(const DateTimeType()).toJson(object.startTime),
      'runningState': const IntType().toJson(object.runningState),
      'hue': const DoubleType().toJson(object.hue),
      'selected': const BoolType().toJson(object.selected),
      'digits': ListType(const IntType()).toJson(object.digits),
      'ranTime': const DoubleType()
          .toJson(object.ranTime.inMilliseconds.toDouble() / 1000),
      'isGoingOff': const BoolType().toJson(object.isGoingOff),
    };
  }
}

TimerData cloneTimerDataWithChanges(
  TimerData old, {
  DateTime? startTime,
  int? runningState,
  double? hue,
  bool? selected,
  List<int>? digits,
  Duration? ranTime,
  bool? isGoingOff,
}) {
  return TimerData(
    startTime: startTime ?? old.startTime,
    runningState: runningState ?? old.runningState,
    hue: hue ?? old.hue,
    selected: selected ?? old.selected,
    digits: digits ?? old.digits,
    ranTime: ranTime ?? old.ranTime,
    isGoingOff: isGoingOff ?? old.isGoingOff,
  );
}
