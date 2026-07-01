/* random info: Background threads are currently enabled by the foreground notification. Background threads wouldn't be necessary if we used exact alarms instead of async.Timers. The background thread isn't doing arbitrary ongoing computation or anything. It's likely we're going to have to move to more of an alarm-style approach for ios */

import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/platform_notifications.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/main.dart'
    show
        mainNotificationPortName,
        isBackgrounded,
        foregroundServiceOpen,
        TimerHolm;
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:signals/signals_flutter.dart';

void backthreadLog(String message, {String name = "ForegroundService"}) {
  print("[$name] $message");
}

void printExceptions(void Function() fn, [String context = ""]) {
  try {
    fn();
  } catch (error, stack) {
    print("ERROR${context.isEmpty ? '' : ' in $context'}: $error");
    print("STACK TRACE:\n$stack");
  }
}

Future<void> printExceptionsAsync(
  Future<void> Function() fn, [
  String context = "",
]) async {
  try {
    await fn();
  } catch (error, stack) {
    print("ERROR${context.isEmpty ? '' : ' in $context'}: $error");
    print("STACK TRACE:\n$stack");
  }
}

const completionChannelKey = 'timer_completion';

/// Port name the service isolate registers so the main isolate can push it
/// hello/heartbeat/goodbye/dismissAlarms (mirrors [mainNotificationPortName] in
/// the other direction).
const foregroundServicePortName = 'foreground_service';

/// Channel the foreground engine uses to talk to [MakosTimerForegroundService]:
///   Dart -> native: 'ready' (returns isApiStart), 'update' (title/text), 'stop'.
///   native -> Dart: 'destroy' (run teardown before the engine dies).
const _taskChannelName = 'makos_timer/foreground_task';

/// Main-isolate control surface for the native foreground service. Mirrors the
/// MissingPluginException-tolerant style of [PlatformNotifications] so non-Android
/// builds (and the linux test target) treat everything as a no-op / granted.
class ForegroundControl {
  static const MethodChannel _channel = MethodChannel('makos_timer/foreground');

  static Future<void> start({
    required int callbackHandle,
    required bool isApiStart,
  }) async {
    try {
      await _channel.invokeMethod('start', {
        'callbackHandle': callbackHandle,
        'isApiStart': isApiStart,
      });
    } on MissingPluginException {
      // non-Android — no-op
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      // non-Android — no-op
    }
  }

  static Future<bool> isRunning() async {
    try {
      return (await _channel.invokeMethod<bool>('isRunning')) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Updates the persistent notification's title/text (null/empty => idle,
  /// icon-only). Used by the main isolate while the app is backgrounded; the
  /// service isolate does the same over its own task channel when it has taken
  /// over. A no-op natively if the service isn't running.
  static Future<void> update({String? title, String? text}) async {
    try {
      await _channel.invokeMethod('update', {'title': title, 'text': text});
    } on MissingPluginException {
      // non-Android — no-op
    }
  }

  static Future<bool> checkNotificationPermission() async {
    try {
      return (await _channel.invokeMethod<String>('checkNotificationPermission')) ==
          'granted';
    } on MissingPluginException {
      return true;
    }
  }

  static Future<bool> requestNotificationPermission() async {
    try {
      return (await _channel.invokeMethod<String>(
            'requestNotificationPermission',
          )) ==
          'granted';
    } on MissingPluginException {
      return true;
    }
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return (await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          )) ??
          true;
    } on MissingPluginException {
      return true;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      return (await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimization',
          )) ??
          false;
    } on MissingPluginException {
      return true;
    }
  }

  static Future<bool> canScheduleExactAlarms() async {
    try {
      return (await _channel.invokeMethod<bool>('canScheduleExactAlarms')) ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  static Future<bool> openAlarmsAndRemindersSettings() async {
    try {
      return (await _channel.invokeMethod<bool>(
            'openAlarmsAndRemindersSettings',
          )) ??
          false;
    } on MissingPluginException {
      return true;
    }
  }
}

/// Builds the persistent notification's (title, text) from a holm's tracked
/// timers, or null when there's nothing worth showing (caller shows idle). Shared
/// by the main isolate (while backgrounded) and the service isolate (after it
/// takes over) so the notification looks identical regardless of who's driving it.
({String title, String text})? buildTimersNotification(TimerHolm holm) {
  final runningLines = <String>[];
  bool anyCompleted = false;
  for (final tt in holm.tracking.values) {
    final mv = tt.mobj?.value;
    if (mv == null) continue;
    if (mv.isRunning) {
      final remaining = mv.duration - DateTime.now().difference(mv.startTime);
      // Skip timers that have crossed zero but whose completionTimer hasn't
      // flipped them to "completed" yet — otherwise they'd render a bogus "00".
      if (remaining <= Duration.zero) continue;
      runningLines.add(
        formatTime(durationToDigits(remaining.inMicroseconds / 1000000.0)),
      );
    } else if (mv.completedRecently) {
      // Completed but not yet acknowledged (the app hasn't been reopened). Keeps
      // the notification — and the service — around to say "completed".
      anyCompleted = true;
    }
  }

  if (runningLines.isEmpty && !anyCompleted) return null;
  if (runningLines.isNotEmpty) {
    return (
      title: runningLines.length == 1 ? "timer running" : "timers running",
      text: (anyCompleted ? [...runningLines, "completed"] : runningLines)
          .join("\n"),
    );
  }
  return (title: "completed", text: "");
}

/// Entry point executed by [MakosTimerForegroundService] in the foreground
/// engine. `@pragma('vm:entry-point')` keeps it from being tree-shaken and lets
/// it be looked up by callback handle (including on reboot).
@pragma('vm:entry-point')
void foregroundTaskStart() {
  // This runs on the foreground engine's own root isolate. Initialize the binding
  // first (exactly like main()): without it the default binary messenger isn't
  // wired up, and any MethodChannel.setMethodCallHandler — ours, PlatformAudio,
  // PlatformNotifications — throws "Cannot set the method call handler before the
  // binary messenger has been initialized."
  WidgetsFlutterBinding.ensureInitialized();
  print("mako foregroundTaskStart");

  final errorPort = ReceivePort();
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((errorData) {
    if (errorData is List && errorData.length >= 2) {
      print("UNCAUGHT ISOLATE ERROR: ${errorData[0]}");
      print("STACK TRACE:\n${errorData[1]}");
    } else {
      print("UNCAUGHT ISOLATE ERROR (unknown format): $errorData");
    }
  });

  _foregroundRunner = ForegroundTaskRunner();
  printExceptionsAsync(() => _foregroundRunner!.start(), "foregroundTaskStart");
}

ForegroundTaskRunner? _foregroundRunner;

void _sendDismissAlarms() {
  IsolateNameServer.lookupPortByName(
    mainNotificationPortName,
  )?.send('dismissAlarms');
  IsolateNameServer.lookupPortByName(
    foregroundServicePortName,
  )?.send('dismissAlarms');
}

/// The foreground engine's worker. Tracks timers while the app is gone, drives
/// the persistent notification, and hands tracking back when the app returns —
/// the same responsibilities the old flutter_foreground_task TaskHandler had,
/// minus the package.
class ForegroundTaskRunner {
  static const MethodChannel _taskChannel = MethodChannel(_taskChannelName);

  late JukeBox jukeBox;
  Timer? _heartbeatTimeout;
  final List<Function()> cleanups = [];

  // false until the app proves it's alive (developer/API start, or a 'hello').
  final Signal<bool> appActive = Signal(false);

  ReceivePort? _servicePort;

  // Non-null only while this isolate's TimerHolm is the live tracker (the app is
  // gone/backgrounded and we've finished (re)loading timers). The self-stop
  // effect is gated on it being non-null so it can't fire during the handoff
  // window: right after the app is dismissed, appActive flips false (so
  // isBackgrounded/foregroundServiceOpen briefly read "closed") but activeTimers
  // hasn't been repopulated yet — stopping then would kill the service while a
  // timer is actually running. A Signal (not a plain field) so that assigning it
  // re-triggers the effect once tracking is live and activeTimers is correct.
  final Signal<TimerHolm?> _timerHolm = Signal(null);
  Timer? _notificationTimer;
  bool _disposed = false;

  ForegroundTaskRunner();

  void dismissAllAlarms() {
    backthreadLog("dismissAllAlarms");
    final holm = _timerHolm.peek();
    if (holm != null) {
      holm.dismissAlarms();
    } else {
      jukeBox.stopAudio();
      PlatformNotifications.cancelAll();
    }
  }

  void _setIdleNotification() {
    // null title + text => icon-only, non-expandable notification (see
    // MakosTimerForegroundService.buildNotification).
    _taskChannel.invokeMethod('update', {'title': null, 'text': null});
  }

  void updateRunningTimersNotification() {
    final holm = _timerHolm.peek();
    if (holm == null) return;
    final n = buildTimersNotification(holm);
    if (n == null) return;
    _taskChannel.invokeMethod('update', {'title': n.title, 'text': n.text});
  }

  void _startTimerHolm(Mobj<List<MobjID<TimerData>>> timerListMobj) {
    _notificationTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => updateRunningTimersNotification(),
    );
    // Build the holm first (its constructor synchronously populates activeTimers
    // via enlivenTimer), then publish it — so the self-stop effect this assign
    // re-triggers sees an accurate activeTimers.
    _timerHolm.value = TimerHolm(
      list: timerListMobj,
      jukeBox: jukeBox,
      dismissOnForeground: false,
    );
  }

  Future<void> _reinitialize() async {
    await MobjRegistry.reloadPreload();
    if (appActive.peek()) return;
    _startTimerHolm(Mobj.getAlreadyLoaded(timerListID, ListType(StringType())));
  }

  Future<void> start() async {
    print("foreground runner start a");

    // The binding (and thus the binary messenger) is initialized in
    // foregroundTaskStart, so method channels are usable from here on.
    _taskChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'destroy':
          printExceptions(dispose, "destroy");
        case 'appKilled':
          // The service got a direct onTaskRemoved (user swiped the app away) —
          // take over immediately instead of waiting out the heartbeat timeout.
          printExceptions(_handleAppGone, "appKilled");
      }
      return null;
    });

    // Pull the start kind from native now that the channel is usable. true when
    // the app/API started us (app is in front), false for system/boot starts.
    final bool isApiStart =
        (await _taskChannel.invokeMethod<bool>('ready')) ?? false;
    appActive.value = isApiStart;

    print("foreground runner start b");
    jukeBox = JukeBox.create();
    await MobjRegistry.initialize(TheDatabase(), preload: true);

    final servicePort = ReceivePort();
    _servicePort = servicePort;
    IsolateNameServer.removePortNameMapping(foregroundServicePortName);
    IsolateNameServer.registerPortWithName(
      servicePort.sendPort,
      foregroundServicePortName,
    );
    servicePort.listen(_onPortMessage);

    await PlatformNotifications.ensureChannel(
      channelKey: completionChannelKey,
      channelName: 'Timer Completion',
      channelDescription: 'Notifications when timers complete',
    );
    // Dismissing or acting on a completion notification dismisses the alarm.
    PlatformNotifications.setActionListener(_sendDismissAlarms);

    // isBackgrounded is a global imported from main.dart. In this isolate it's a
    // fresh Signal(false). Wire it to !appActive so TimerHolm works correctly here.
    cleanups.add(
      effect(() {
        isBackgrounded.value = !appActive.value;
      }),
    );

    // When the app becomes active, synchronously tear down so it has exclusive access
    cleanups.add(
      effect(() {
        if (appActive.value) {
          _notificationTimer?.cancel();
          _notificationTimer = null;
          // Clearing _timerHolm both tears down tracking and (being non-null no
          // more) disarms the self-stop effect until the next handoff repopulates
          // activeTimers.
          _timerHolm.peek()?.dispose();
          _timerHolm.value = null;
          MobjRegistry.relinquishAll();
          _setIdleNotification();
        }
      }),
    );

    if (!appActive.peek()) {
      _startTimerHolm(
        Mobj.getAlreadyLoaded(timerListID, ListType(StringType())),
      );
    }

    cleanups.add(
      effect(() {
        // Only stop once we're actually the live tracker (gate avoids the
        // dismissal handoff race), and only when there's nothing to track.
        if (_timerHolm.value != null && !foregroundServiceOpen.value) {
          // Stop the per-second 'update' calls before tearing down, so their
          // replies don't race the engine destroy.
          _notificationTimer?.cancel();
          _notificationTimer = null;
          _taskChannel.invokeMethod('stop');
        }
      }),
    );

    // Tell the main isolate we're up so it flushes any buffered hello/heartbeat.
    IsolateNameServer.lookupPortByName(mainNotificationPortName)?.send('ready');
  }

  void _onPortMessage(dynamic message) {
    switch (message) {
      case 'dismissAlarms':
        dismissAllAlarms();
      case 'hello':
        appActive.value = true;
        _resetHeartbeatTimeout();
        dismissAllAlarms();
      // there is no way to be reliably notified when a process is killed, so we
      // do a heartbeat timer as well as relying on lifecycle messages.
      case 'heartbeat':
        backthreadLog("heartbeat received");
        if (appActive.peek()) {
          _resetHeartbeatTimeout();
        }
      case 'goodbye':
        _handleAppGone();
    }
  }

  /// The app process is gone (heartbeat lapsed, lifecycle goodbye, or a direct
  /// onTaskRemoved): this isolate becomes the live tracker. Guarded on appActive
  /// (set synchronously) so overlapping triggers — e.g. onTaskRemoved and the
  /// heartbeat timeout both firing — don't start tracking twice.
  void _handleAppGone() {
    if (!appActive.peek()) return;
    appActive.value = false;
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
    _reinitialize();
  }

  void _resetHeartbeatTimeout() {
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = Timer(const Duration(seconds: 2), () {
      backthreadLog("heartbeat timeout");
      _heartbeatTimeout = null;
      _handleAppGone();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    backthreadLog("runner dispose");
    // No method-channel calls here: the engine is about to be destroyed, so any
    // reply would arrive after FlutterJNI detaches ("Tried to send a platform
    // message response..."). Stopping audio is handled natively in
    // PlatformAudioPlugin.onDetachedFromEngine; notification clearing on a user
    // dismiss is handled natively in ForegroundDismissReceiver.
    _heartbeatTimeout?.cancel();
    _notificationTimer?.cancel();
    _timerHolm.peek()?.dispose();
    for (final cleanup in cleanups) {
      cleanup();
    }
    cleanups.clear();
    appActive.dispose();
    IsolateNameServer.removePortNameMapping(foregroundServicePortName);
    _servicePort?.close();
    _servicePort = null;
  }
}

Timer? heartbeaterMain;

List<String>? _pendingTaskMessages;

/// Sends a message to the foreground task over its IsolateNameServer port,
/// buffering until the port is registered (it isn't during the brief window
/// between starting the service and the runner finishing [ForegroundTaskRunner.start]).
void bufferedSendToForegroundTask(String message) {
  final port = IsolateNameServer.lookupPortByName(foregroundServicePortName);
  if (port != null) {
    port.send(message);
  } else {
    (_pendingTaskMessages ??= []).add(message);
  }
}

/// Flushes buffered messages once the task signals 'ready'. Called from the main
/// isolate's notification-response port listener.
void flushBufferedTaskMessages() {
  final pending = _pendingTaskMessages;
  _pendingTaskMessages = null;
  if (pending == null) return;
  final port = IsolateNameServer.lookupPortByName(foregroundServicePortName);
  if (port == null) return;
  for (final msg in pending) {
    port.send(msg);
  }
}

bool _foregroundServiceSetUp = false;

/// One-time permission setup (notifications, battery optimization, exact alarms).
/// Returns whether all permissions were granted. Safe to call more than once.
Future<bool> _setUpForegroundService() async {
  if (_foregroundServiceSetUp) return true;

  // Android 13+: notification permission is required to show the foreground
  // service notification. (No-op / granted off Android.)
  bool permissionsGranted = await ForegroundControl.requestNotificationPermission();

  if (Platform.isAndroid) {
    // Android 12+: restrictions on starting a foreground service / restarting it
    // on reboot. Ignoring battery optimization keeps us reliable.
    if (!await ForegroundControl.isIgnoringBatteryOptimizations()) {
      if (!await ForegroundControl.requestIgnoreBatteryOptimization()) {
        permissionsGranted = false;
      }
    }

    if (!await ForegroundControl.canScheduleExactAlarms()) {
      if (!await ForegroundControl.openAlarmsAndRemindersSettings()) {
        permissionsGranted = false;
      }
    }
  }

  _foregroundServiceSetUp = true;
  return permissionsGranted;
}

/// Stops the foreground service and removes its persistent notification. Safe to
/// call when the service isn't running (or off Android).
Future<void> stopForegroundService() async {
  if (!Platform.isAndroid) return;
  await ForegroundControl.stop();
}

/// Ensures the foreground service (and its persistent notification) is running,
/// starting it if necessary. Idempotent, so it's cheap to call on every app
/// resume to bring the notification back after a backgrounded-and-idle close.
Future<bool> graspForegroundService() async {
  if (!Platform.isAndroid) {
    return false;
  }

  final bool permissionsGranted = await _setUpForegroundService();

  final handle = PluginUtilities.getCallbackHandle(foregroundTaskStart);
  if (handle == null) {
    throw StateError('could not resolve foregroundTaskStart callback handle');
  }
  final bool alreadyRunning = await ForegroundControl.isRunning();
  if (!alreadyRunning) {
    print("starting service");
    _pendingTaskMessages = [];
  } else {
    print("service is already running; re-issuing start to re-show notification");
  }
  // Always (re)issue start, even when already running. Android 14+ lets the user
  // swipe away a foreground-service notification while leaving the service alive;
  // re-issuing start makes the service call startForeground again and re-post the
  // notification. When the service isn't running this boots it. The engine only
  // ever bootstraps once, so this is cheap either way.
  await ForegroundControl.start(
    callbackHandle: handle.toRawHandle(),
    isApiStart: true,
  );

  // 'hello' confirms the app is in front (resets the heartbeat watchdog and
  // dismisses any alarms). Buffered if the task isn't registered yet (fresh
  // start), sent directly if it's already up.
  bufferedSendToForegroundTask('hello');

  // Interval heartbeat so the task notices when the app process goes away.
  heartbeaterMain ??= Timer.periodic(const Duration(milliseconds: 1200), (_) {
    bufferedSendToForegroundTask('heartbeat');
  });

  return permissionsGranted;
}
