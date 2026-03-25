import 'package:makos_timer/boring.dart';
import 'package:makos_timer/platform_audio.dart';

import 'mobj.dart';

// this file is pretty much entirely edited through language models, it's just database boilerplate. In a better programming langauge this stuff would be handled by reflection or codegen. In dart, it's more practical to just make the robot do it.

enum TimerKind {
  timer,
  stopwatch,
  loop,
  series,
  parallel,
}

class TimerData {
  /// the last time the timer was started
  late final DateTime startTime;

  /// whether it's paused/playing/completed
  final int runningState;
  bool get isRunning => runningState == running;
  bool get isCompleted => runningState == completed;
  bool get isPaused => !isRunning;
  bool get isComposite =>
      kind == TimerKind.loop ||
      kind == TimerKind.series ||
      kind == TimerKind.parallel;
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

  /// if not pinned, the timer will be deleted next time a new timer is created, unless it's currently playing
  final bool pinned;

  /// set when the timer reaches zero until the user starts it again or resets
  final bool completedRecently;

  final bool? persistentAlarm;

  final TimerKind kind;

  /// list of child timer IDs
  final List<String> children;

  final String? title;

  /// if this timer is a child of a composite timer, the ID of that composite
  final MobjID? parentId;

  Duration get duration => digitsToDuration(digits);

  /// in seconds
  double get transpired => runningState == TimerData.paused
      ? durationToSeconds(ranTime)
      : runningState == TimerData.running
          ? timeSinceLastStartTime
          : 0;
  double get timeSinceLastStartTime =>
      durationToSeconds(DateTime.now().difference(startTime));

  TimerData({
    DateTime? startTime,
    this.runningState = paused,
    required this.hue,
    required this.selected,
    this.digits = const [],
    this.ranTime = Duration.zero,
    this.isGoingOff = false,
    this.pinned = false,
    this.completedRecently = false,
    this.persistentAlarm,
    this.kind = TimerKind.timer,
    this.children = const [],
    this.title,
    this.parentId,
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
    bool? pinned,
    bool? completedRecently,
    bool? persistentAlarm,
    bool persistentAlarmNull = false,
    TimerKind? kind,
    List<String>? children,
    String? title,
    bool titleNull = false,
    String? parentId,
    bool parentIdNull = false,
  }) {
    return TimerData(
      startTime: startTime ?? this.startTime,
      runningState: runningState ?? this.runningState,
      hue: hue ?? this.hue,
      selected: selected ?? this.selected,
      digits: digits ?? this.digits,
      ranTime: ranTime ?? this.ranTime,
      isGoingOff: isGoingOff ?? this.isGoingOff,
      pinned: pinned ?? this.pinned,
      completedRecently: completedRecently ?? this.completedRecently,
      persistentAlarm: persistentAlarmNull
          ? null
          : (persistentAlarm ?? this.persistentAlarm),
      kind: kind ?? this.kind,
      children: children ?? this.children,
      title: titleNull ? null : (title ?? this.title),
      parentId: parentIdNull ? null : (parentId ?? this.parentId),
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
              startTime: DateTime.now(),
              completedRecently: false)
          :
          // still resets if it was completed
          runningState == TimerData.completed
              ? withChanges(
                  runningState: TimerData.running,
                  ranTime: Duration.zero,
                  startTime: DateTime.now(),
                  completedRecently: false)
              : withChanges(
                  runningState: TimerData.running,
                  ranTime: ranTime,
                  startTime: DateTime.now().subtract(ranTime));
}

class TimerDataType extends TypeHelp<TimerData> {
  TimerDataType() : super('TimerData');

  @override
  TimerData fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return TimerData(
        startTime: Nullable(DateTimeType()).fromJson(json['startTime']),
        runningState: IntType().fromJson(json['runningState']),
        hue: DoubleType().fromJson(json['hue']),
        selected: BoolType().fromJson(json['selected']),
        digits: ListType(IntType()).fromJson(json['digits']),
        pinned: BoolType().fromJson(json['pinned']),
        persistentAlarm: Nullable(BoolType()).fromJson(json['persistentAlarm']),
        ranTime: Duration(
            milliseconds:
                (DoubleType().fromJson(json['ranTime']) * 1000).toInt()),
        isGoingOff: BoolType().fromJson(json['isGoingOff']),
        completedRecently:
            BoolType().fromJson(json['completedRecently'] ?? false),
        kind: TimerKind.values[IntType().fromJson(json['kind'])],
        children: ListType(StringType()).fromJson(json['children'] ?? []),
        title: Nullable(StringType()).fromJson(json['title']),
        parentId: Nullable(StringType()).fromJson(json['parentId']),
      );
    }
    throw ArgumentError('Cannot convert $json to TimerData');
  }

  @override
  Object? toJsonValue(TimerData object) {
    return {
      'startTime': Nullable(DateTimeType()).toJson(object.startTime),
      'runningState': IntType().toJson(object.runningState),
      'hue': DoubleType().toJson(object.hue),
      'selected': BoolType().toJson(object.selected),
      'digits': ListType(IntType()).toJson(object.digits),
      'pinned': BoolType().toJson(object.pinned),
      'persistentAlarm': Nullable(BoolType()).toJson(object.persistentAlarm),
      'ranTime':
          DoubleType().toJson(object.ranTime.inMilliseconds.toDouble() / 1000),
      'isGoingOff': BoolType().toJson(object.isGoingOff),
      'completedRecently': BoolType().toJson(object.completedRecently),
      'kind': IntType().toJson(object.kind.index),
      'children': ListType(StringType()).toJson(object.children),
      'title': Nullable(StringType()).toJson(object.title),
      'parentId': Nullable(StringType()).toJson(object.parentId),
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
  bool? pinned,
  bool? completedRecently,
  bool? persistentAlarm,
  bool persistentAlarmNull = false,
  List<String>? children,
  String? title,
  bool titleNull = false,
  String? parentId,
  bool parentIdNull = false,
}) {
  return TimerData(
    startTime: startTime ?? old.startTime,
    runningState: runningState ?? old.runningState,
    hue: hue ?? old.hue,
    selected: selected ?? old.selected,
    digits: digits ?? old.digits,
    ranTime: ranTime ?? old.ranTime,
    isGoingOff: isGoingOff ?? old.isGoingOff,
    pinned: pinned ?? old.pinned,
    completedRecently: completedRecently ?? old.completedRecently,
    persistentAlarm:
        persistentAlarmNull ? null : (persistentAlarm ?? old.persistentAlarm),
    children: children ?? old.children,
    title: titleNull ? null : (title ?? old.title),
    parentId: parentIdNull ? null : (parentId ?? old.parentId),
  );
}

class AudioInfoType extends TypeHelp<AudioInfo> {
  AudioInfoType() : super('AudioInfo');

  @override
  AudioInfo fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return AudioInfo(
        url: json['uri'] != null ? StringType().fromJson(json['uri']) : null,
        name: StringType().fromJson(json['name']),
        isLong: BoolType().fromJson(json['isLong']),
      );
    }
    throw ArgumentError('Cannot convert $json to AudioInfo');
  }

  @override
  Object? toJsonValue(AudioInfo object) {
    return {
      'uri': object.url != null ? StringType().toJson(object.url!) : null,
      'name': StringType().toJson(object.name),
      'isLong': BoolType().toJson(object.isLong),
    };
  }
}
