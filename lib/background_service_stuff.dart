import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:awesome_notifications/awesome_notifications.dart'
    hide NotificationPermission;
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/main.dart'
    show mainNotificationPortName, isBackgrounded, foregroundOpen, TimerHolm;
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

Future<void> printExceptionsAsync(Future<void> Function() fn,
    [String context = ""]) async {
  try {
    await fn();
  } catch (error, stack) {
    print("ERROR${context.isEmpty ? '' : ' in $context'}: $error");
    print("STACK TRACE:\n$stack");
  }
}

late final PersistentNotificationTask foregroundTaskHandler;

const foregroundServicePortName = 'foreground_service';

@pragma('vm:entry-point')
void foregroundTaskStart() {
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

  foregroundTaskHandler = PersistentNotificationTask();
  FlutterForegroundTask.setTaskHandler(
      ErrorCatchingTaskHandler(foregroundTaskHandler));
}

void _sendDismissAlarms() {
  IsolateNameServer.lookupPortByName(mainNotificationPortName)
      ?.send('dismissAlarms');
  IsolateNameServer.lookupPortByName(foregroundServicePortName)
      ?.send('dismissAlarms');
}

@pragma('vm:entry-point')
Future<void> foregroundServiceNotificationActionReceived(
    ReceivedAction action) async {
  print("foregroundServiceNotificationActionReceived: $action");
  _sendDismissAlarms();
}

@pragma('vm:entry-point')
Future<void> foregroundServiceNotificationDismissedReceived(
    ReceivedAction action) async {
  print("foregroundServiceNotificationDismissedReceived: $action");
  _sendDismissAlarms();
}

class ErrorCatchingTaskHandler extends TaskHandler {
  final TaskHandler _inner;
  ErrorCatchingTaskHandler(this._inner);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) =>
      printExceptionsAsync(() => _inner.onStart(timestamp, starter), "onStart");

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) =>
      printExceptionsAsync(
          () => _inner.onDestroy(timestamp, isTimeout), "onDestroy");

  @override
  void onRepeatEvent(DateTime timestamp) =>
      printExceptions(() => _inner.onRepeatEvent(timestamp), "onRepeatEvent");

  @override
  void onReceiveData(Object data) =>
      printExceptions(() => _inner.onReceiveData(data), "onReceiveData");

  @override
  void onNotificationPressed() => printExceptions(
      () => _inner.onNotificationPressed(), "onNotificationPressed");

  @override
  void onNotificationButtonPressed(String id) => printExceptions(
      () => _inner.onNotificationButtonPressed(id),
      "onNotificationButtonPressed");
}

const completionChannelKey = 'timer_completion';

class PersistentNotificationTask extends TaskHandler {
  late JukeBox jukeBox;
  Timer? _heartbeatTimeout;
  final List<Function()> cleanups = [];
  late Signal<bool> appActive;
  late ReceivePort _dismissPort;
  TimerHolm? _timerHolm;
  Timer? _notificationTimer;

  void dismissAllAlarms() {
    backthreadLog("dismissAllAlarms");
    if (_timerHolm != null) {
      _timerHolm!.dismissAlarms();
    } else {
      jukeBox.stopAudio();
      AwesomeNotifications().cancelAll();
    }
  }

  void updatePersistentNotification(
      {required String title,
      required String text,
      required List<NotificationButton> buttons}) {
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
      notificationButtons: buttons,
    );
  }

  void updateRunningTimersNotification() {
    final tracking = _timerHolm?.tracking;
    if (tracking == null || tracking.isEmpty) return;
    final String title =
        tracking.length == 1 ? "timer running" : "timers running";
    String body = "";
    for (final tt in tracking.values) {
      final mv = tt.mobj?.value;
      if (mv?.isRunning == true) {
        final dur = mv!.duration - DateTime.now().difference(mv.startTime);
        final remainingSecs =
            dur.isNegative ? 0.0 : dur.inMicroseconds / 1000000.0;
        body += "${formatTime(durationToDigits(remainingSecs))}\n";
      } else {
        body += "timer completed\n";
      }
    }
    updatePersistentNotification(
        title: title, text: body.trimRight(), buttons: []);
  }

  void _startTimerHolm(Mobj<List<MobjID<TimerData>>> timerListMobj) {
    // Just start tracking; building the TimerHolm populates `activeTimers`
    // (via enlivenTimer), which feeds `foregroundOpen`. The stop effect wired
    // up in onStart will tear the service down if nothing turns out to be
    // active — no need to special-case the idle case here.
    _timerHolm = TimerHolm(
        list: timerListMobj, jukeBox: jukeBox, dismissOnForeground: false);
    _notificationTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => updateRunningTimersNotification());
  }

  Future<void> _reinitialize() async {
    await MobjRegistry.reloadPreload();
    if (appActive.peek()) return;
    _startTimerHolm(Mobj.getAlreadyLoaded(timerListID, ListType(StringType())));
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print("onStart a");
    appActive = Signal(starter == TaskStarter.developer);

    // this might be useful for plugin support for background isolate?
    // [todo] test to see if platform audio works when the isolate is started on reboot. If not, I think we're kinda screwed.
    // [todo] try removing this
    final token = RootIsolateToken.instance!;
    print("onStart b");
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    FlutterForegroundTask.sendDataToMain({'op': 'onStart Report'});
    jukeBox = JukeBox.create();
    print("onStart c");
    await MobjRegistry.initialize(TheDatabase(), preload: true);
    _dismissPort = ReceivePort();
    IsolateNameServer.removePortNameMapping(foregroundServicePortName);
    IsolateNameServer.registerPortWithName(
        _dismissPort.sendPort, foregroundServicePortName);
    _dismissPort.listen((message) {
      if (message == 'dismissAlarms') dismissAllAlarms();
    });
    await AwesomeNotifications()
        .initialize('resource://drawable/res_notification_icon', [
      NotificationChannel(
        channelKey: completionChannelKey,
        channelName: 'Timer Completion',
        channelDescription: 'Notifications when timers complete',
        importance: NotificationImportance.High,
      ),
    ]);
    await AwesomeNotifications().setListeners(
      onActionReceivedMethod: foregroundServiceNotificationActionReceived,
      onDismissActionReceivedMethod:
          foregroundServiceNotificationDismissedReceived,
    );

    // isBackgrounded is a global imported from main.dart. In this isolate it's a
    // fresh Signal(false). Wire it to !appActive so TimerHolm works correctly here.
    cleanups.add(effect(() {
      isBackgrounded.value = !appActive.value;
    }));

    // When the app becomes active, synchronously tear down so it has exclusive access
    cleanups.add(effect(() {
      if (appActive.value) {
        _notificationTimer?.cancel();
        _notificationTimer = null;
        _timerHolm?.dispose();
        _timerHolm = null;
        MobjRegistry.relinquishAll();
        updatePersistentNotification(
            title: appName, text: foregroundNotificationText, buttons: []);
      }
    }));

    if (!appActive.peek()) {
      _startTimerHolm(Mobj.getAlreadyLoaded(timerListID, ListType(StringType())));
    }

    // The service can't start itself (that's the main isolate's job), but it
    // can notice when it's no longer needed and shut down. This is what removes
    // the notification when the last timer finishes while the app is hidden:
    // appActive is false, the last active timer drops out of `activeTimers`, so
    // `foregroundOpen` goes false and we stop. Registered after the holm above
    // so `activeTimers` already reflects reality on first evaluation.
    cleanups.add(effect(() {
      if (!foregroundOpen.value) {
        FlutterForegroundTask.stopService();
      }
    }));
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _heartbeatTimeout?.cancel();
    _notificationTimer?.cancel();
    _timerHolm?.dispose();
    for (final cleanup in cleanups) {
      cleanup();
    }
    cleanups.clear();
    backthreadLog("mako onDestroy $timestamp $isTimeout");
    appActive.dispose();
    IsolateNameServer.removePortNameMapping(foregroundServicePortName);
    _dismissPort.close();
    FlutterForegroundTask.sendDataToMain({'op': 'goodbye'});
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    backthreadLog("onRepeatEvent $timestamp");
  }

  @override
  void onNotificationPressed() {
    backthreadLog("mako onNotificationPressed");
  }

  @override
  void onReceiveData(Object data) {
    Map<String, dynamic> dataMap = data as Map<String, dynamic>;
    String op = dataMap['op'] as String;
    resetHeartbeatTimeout() {
      _heartbeatTimeout?.cancel();
      _heartbeatTimeout = Timer(Duration(seconds: 2), () {
        backthreadLog("heartbeat timeout");
        appActive.value = false;
        _reinitialize();
      });
    }

    switch (op) {
      case 'hello':
        appActive.value = true;
        resetHeartbeatTimeout();
        dismissAllAlarms();
        break;
      // there is no way to be reliably notified when a process is killed, so we do a heartbeat timer as well as the goodbye thing just in case that's killed
      case 'heartbeat':
        backthreadLog("heartbeat received");
        if (appActive.peek()) {
          resetHeartbeatTimeout();
        }
        break;
      case 'goodbye':
        appActive.value = false;
        _heartbeatTimeout?.cancel();
        _reinitialize();
        break;
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    backthreadLog("notification button pressed $id");
  }
}

Timer? heartbeaterMain;

List<Object>? _pendingTaskMessages;
bool _serviceRunning = false;

/// Sends data to the foreground task, buffering messages until the service is running.
void bufferedSendToForegroundTask(Object data) {
  if (_serviceRunning) {
    FlutterForegroundTask.sendDataToTask(data);
  } else {
    _pendingTaskMessages ??= [];
    _pendingTaskMessages!.add(data);
  }
}

/// Flushes any buffered messages to the foreground task.
void flushBufferedTaskMessages() {
  final pending = _pendingTaskMessages;
  _pendingTaskMessages = null;
  if (pending != null) {
    for (final msg in pending) {
      FlutterForegroundTask.sendDataToTask(msg);
    }
  }
}

bool _foregroundServiceSetUp = false;

/// One-time setup: communication port, permissions, and notification/task
/// options. Returns whether all permissions were granted. Safe to call more
/// than once (it only does the work the first time).
Future<bool> _setUpForegroundService() async {
  if (_foregroundServiceSetUp) return true;

  FlutterForegroundTask.initCommunicationPort();

  // permissions
  // Android 13+, you need to allow notification permission to display foreground service notification.
  // iOS: If you need notification, ask for permission.
  bool permissionsGranted = true;
  final NotificationPermission notificationPermission =
      await FlutterForegroundTask.checkNotificationPermission();
  if (notificationPermission != NotificationPermission.granted) {
    bool g = await FlutterForegroundTask.requestNotificationPermission() ==
        NotificationPermission.granted;
    if (!g) {
      permissionsGranted = false;
    }
  }
  if (Platform.isAndroid) {
    // Android 12+, there are restrictions on starting a foreground service.
    // To restart the service on device reboot or unexpected problem, you need to allow below permission.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      // This function requires `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission.
      bool g = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!g) {
        permissionsGranted = false;
      }
    }

    // I don't think this is ever on Android 13+
    assert(await FlutterForegroundTask.canScheduleExactAlarms);
    if (!await FlutterForegroundTask.canScheduleExactAlarms) {
      // // [maybe todo] explain to the user why we need this. wait, it doesn't send the user to the settings page it just opens a tooltip, seems clear enough? Or maybe this permission was already granted and this code doesn't really need to be here? I'll comment this out and replace it with just a check.
      bool g = await FlutterForegroundTask.openAlarmsAndRemindersSettings();
      if (!g) {
        permissionsGranted = false;
      }
    }
  }

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: "mako timer's persistent notification",
      channelDescription: "mako timer's persistent notification",
      onlyAlertOnce: true,
    ),
    // disabled on ios? well, ios shouldn't do any of it this way, it should do it by scheduling notifications and stuff
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // [todo] remove
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      // is this really right? I would like to let the phone rests when it wants to rest as long as it can start to wake up before we need it, we can plan ahead, we know when we're going to need it, so if it takes time to wake up that's okay.
      allowWakeLock: true,
    ),
  );

  _foregroundServiceSetUp = true;
  return permissionsGranted;
}

/// Stops the foreground service and removes its persistent notification. Safe
/// to call when the service isn't running (or off Android).
Future<void> stopForegroundService() async {
  if (!Platform.isAndroid) return;
  _serviceRunning = false;
  await FlutterForegroundTask.stopService();
}

/// Ensures the foreground service (and its persistent notification) is running,
/// starting it if necessary. Idempotent, so it's cheap to call on every app
/// resume to bring the notification back after a backgrounded-and-idle close.
Future<bool> graspForegroundService() async {
  if (!Platform.isAndroid) {
    return false;
  }

  final bool permissionsGranted = await _setUpForegroundService();

  if (await FlutterForegroundTask.isRunningService) {
    // in the example, they restart the service here, we're not gonna restart
    print("service is already running");
    _serviceRunning = true;
    flushBufferedTaskMessages();
    bufferedSendToForegroundTask({'op': 'hello'});
  } else {
    print("starting service");
    _pendingTaskMessages = [];
    final sr = await FlutterForegroundTask.startService(
      // serviceTypes: [
      //   ForegroundServiceTypes.dataSync,
      //   ForegroundServiceTypes.remoteMessaging,
      // ],
      serviceId: 1,
      notificationTitle: appName,
      notificationText: foregroundNotificationText,
      notificationIcon: null,
      // (see manifest for why specialUse)
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationInitialRoute: '/',

      callback: foregroundTaskStart,
    );
    if (sr is ServiceRequestFailure) {
      _pendingTaskMessages = null;
      throw sr;
    }
    _serviceRunning = true;
    flushBufferedTaskMessages();
  }

  // Start an interval timer that sends the heartbeat signal to the foreground task
  heartbeaterMain ??=
      Timer.periodic(const Duration(milliseconds: 1200), (timer) {
    print("heartbeat sent");
    bufferedSendToForegroundTask({'op': 'heartbeat'});
  });

  return permissionsGranted;
}
