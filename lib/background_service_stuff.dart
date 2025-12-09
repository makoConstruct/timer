import 'dart:io';
import 'dart:async';
import 'dart:isolate';
// this doesn't work from background isolates?
// import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart';
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

// entrypoint for the persistent notification isolate
@pragma('vm:entry-point')
void foregroundTaskStart() {
  print("mako foregroundTaskStart");

  // Catch all uncaught errors in the isolate (including from Timers, Futures, effects)
  final errorPort = ReceivePort();
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((errorData) {
    if (errorData is List && errorData.length >= 2) {
      final error = errorData[0];
      final stack = errorData[1];
      print("UNCAUGHT ISOLATE ERROR: $error");
      print("STACK TRACE:\n$stack");
    } else {
      print("UNCAUGHT ISOLATE ERROR (unknown format): $errorData");
    }
  });

  FlutterForegroundTask.setTaskHandler(
      ErrorCatchingTaskHandler(PersistentNotificationTask()));
}

// Wrapper that catches and logs all errors from the inner handler, since they don't otherwise seem to reach the logcat
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

class PersistentNotificationTask extends TaskHandler {
  late JukeBox jukeBox;
  Timer? _heartbeatTimeout;
  final List<Function()> cleanups = [];
  // increased by running timers and by a grasp from the app isolate
  late Signal<bool> appActive;
  // tracks the number of timers that were running when the app was last closed.
  late Signal<int> ranTimerCount;
  late Computed<int> refCount;
  final List<TrackedTimer> trackedTimers = [];
  StreamSubscription? timerListSubscription;
  Function()? listeningProcessCancel;
  Timer? noTimersCheck;
  // kept for debouncing notification updates
  DateTime? lastNotificationUpdate;

  void onTimerDataChanged(TrackedTimer tracked) {
    backthreadLog("onTimerDataChanged ${tracked.mobj.id}",
        name: "ForegroundService");
    final timer = tracked.mobj;
    final ntp = timer.peek()!;
    if (ntp.isRunning) {
      tracked.triggerTimer?.cancel();
      tracked.triggerTimer = Timer(
          digitsToDuration(timer.peek()!.digits) -
              DateTime.now().difference(timer.peek()!.startTime), () {
        backthreadLog("timer triggered ${timer.id}", name: "ForegroundService");
        // trigger timer
        FlutterForegroundTask.sendDataToMain(
            {'op': 'timerTriggered', 'timerId': timer.id});
        Mobj.fetch(selectedAudioID, type: AudioInfoType()).then((audio) {
          jukeBox.playAudio(audio.value!);
        });
        timer.value =
            timer.value!.withChanges(runningState: TimerData.completed);
      });
    } else {
      tracked.endTrackedTimer();
      updateRunningTimersNotification();
    }
  }

  void relinquishWork() {
    timerListSubscription?.cancel();
    timerListSubscription = null;
    listeningProcessCancel?.call();
    listeningProcessCancel = null;
    for (final tracked in trackedTimers) {
      tracked.endTrackedTimer();
    }
    trackedTimers.clear();
    ranTimerCount.value = 0;
  }

  void updatePersistentNotification(
      {required String title,
      required String text,
      required List<NotificationButton> buttons}) {
    // Service is already started by graspForegroundService(), only update it
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
      notificationButtons: buttons,
    );
  }

  void updateRunningTimersNotification() {
    // debounce to avoid excessive notification updates (no idea if they're expensive but we might as well)
    final now = DateTime.now();
    if (lastNotificationUpdate != null &&
        now.difference(lastNotificationUpdate!) < Duration(milliseconds: 130)) {
      return;
    }
    lastNotificationUpdate = now;

    String title =
        trackedTimers.length == 1 ? "timer running" : "timers running";
    String body = "";
    for (final tracked in trackedTimers) {
      final mv = tracked.mobj.value;
      body += mv?.isRunning ?? false
          ? "${formatTime(durationToDigits(tracked.secondsRemaining().toDouble()))}\n"
          : "timer completed";
    }
    updatePersistentNotification(title: title, text: body, buttons: []);
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print("onStart");
    appActive = Signal(starter == TaskStarter.developer);
    ranTimerCount = Signal(0);
    refCount = computed(() => ranTimerCount.value + (appActive.value ? 1 : 0));

    // this might be useful for plugin support for background isolate?
    // [todo] test to see if platform audio works when the isolate is started on reboot. If not, I think we're kinda screwed.
    // [todo] try removing this
    final token = RootIsolateToken.instance!;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    FlutterForegroundTask.sendDataToMain({'op': 'onStart Report'});
    jukeBox = await JukeBox.create();
    MobjRegistry.initialize(TheDatabase());

    print("registering effect to update notification message");
    // keeping track of the timers when we need to and forgetting them when we don't
    cleanups.add(effect(() {
      print("lifecycle logic");
      if (appActive.value) {
        relinquishWork();
        updatePersistentNotification(
            title: appName, text: foregroundNotificationText, buttons: []);
      } else {
        //(re)start the listening process
        listeningProcessCancel?.call();
        bool cancelled = false;
        listeningProcessCancel = () {
          cancelled = true;
          timerListSubscription?.cancel();
          noTimersCheck?.cancel();
          noTimersCheck = null;
        };
        final futureTimerList =
            Mobj.fetch(timerListID, type: ListType(const StringType()));

        futureTimerList.then((timerList) {
          if (cancelled) {
            return;
          }
          // tombstone: I at one point tried to make this reactive, so that if any timers were added during the running of the background task, we'd notice them and add them to the list. It could have worked, but there was a little bit of difficulty in adapting a Signal<List<Timer>> to a stream of events, and it was totally unneeded (nothing is adding timers while the background task is active), so I cut it, we just check the timer list once. Generally, streams in dart are annoying to deal with because dart lacks weak refs so you have to clean up every stream subscription.
          Future.wait(timerList
                  .peek()!
                  .map((id) => Mobj.fetch(id, type: TimerDataType()))
                  .toList())
              .then((timers) {
            for (final timer in timers) {
              if (cancelled) {
                timer.dispose();
                return;
              }
              if (timer.peek()!.isRunning) {
                ranTimerCount.value++;
                final tracked = TrackedTimer(timer);
                tracked.mobjUnsubscribe = timer.subscribe((_) {
                  onTimerDataChanged(tracked);
                });
                tracked.secondCountdownIndicatorTimer = PeriodicTimerFromEpoch(
                    period: Duration(seconds: 1),
                    epoch: tracked.mobj.peek()!.startTime,
                    callback: (timer) {
                      updateRunningTimersNotification();
                    });
                trackedTimers.add(tracked);
              }
            }
            if (appActive.value) {
              // never mind, app has resumed control
              return;
            }
            if (trackedTimers.isEmpty) {
              FlutterForegroundTask.stopService();
            }
          });
        });
      }
    }));
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _heartbeatTimeout?.cancel();
    for (final cleanup in cleanups) {
      cleanup();
    }
    cleanups.clear();
    backthreadLog("mako onDestroy $timestamp $isTimeout",
        name: "ForegroundService");
    appActive.dispose();
    ranTimerCount.dispose();
    refCount.dispose();
    FlutterForegroundTask.sendDataToMain({'op': 'goodbye'});
  }

  // "Called based on the eventAction set in ForegroundTaskOptions." (I don't know what this one is for)
  @override
  void onRepeatEvent(DateTime timestamp) {
    // this is what the documentation example did here. I don't think we have to do this.
    // Send data to main isolate.
    backthreadLog("onRepeatEvent $timestamp", name: "ForegroundService");
    // jukeBox.jarringPlayers.start();
  }

  @override
  void onNotificationPressed() {
    backthreadLog("mako onNotificationPressed", name: "ForegroundService");
    for (final tracked in trackedTimers) {
      if (tracked.mobj.value!.isRunning) {
        tracked.mobj.value = tracked.mobj.value!.withChanges(
            runningState: TimerData.paused, ranTime: Duration.zero);
      }
    }
    relinquishWork();
  }

  @override
  void onReceiveData(Object data) {
    Map<String, dynamic> dataMap = data as Map<String, dynamic>;
    String op = dataMap['op'] as String;
    resetHeartbeatTimeout() {
      _heartbeatTimeout?.cancel();
      _heartbeatTimeout = Timer(Duration(seconds: 2), () {
        backthreadLog("heartbeat timeout", name: "ForegroundService");
        appActive.value = false;
      });
    }

    switch (op) {
      case 'hello':
        appActive.value = true;
        resetHeartbeatTimeout();
        break;
      // there is no way to be reliably notified when a process is killed, so we do a heartbeat timer as well as the goodbye thing just in case that's killed
      case 'heartbeat':
        // for some reason the heartbeat continues to fire even after the app is closed. The heartbeat shouldn't trigger in that case.
        backthreadLog("heartbeat received", name: "ForegroundService");
        if (appActive.peek()) {
          appActive.value = true;
          resetHeartbeatTimeout();
          break;
        }
      case 'goodbye':
        appActive.value = false;
        _heartbeatTimeout?.cancel();
        break;
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    // [todo]: pause/play the current timer
    backthreadLog("notification button pressed $id", name: "ForegroundService");
  }
}

Timer? heartbeaterMain;

Future<void> graspForegroundService() async {
  if (!Platform.isAndroid) {
    return;
  }

  FlutterForegroundTask.initCommunicationPort();

  // permissions
  // Android 13+, you need to allow notification permission to display foreground service notification.
  // iOS: If you need notification, ask for permission.
  final NotificationPermission notificationPermission =
      await FlutterForegroundTask.checkNotificationPermission();
  if (notificationPermission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  if (Platform.isAndroid) {
    // Android 12+, there are restrictions on starting a foreground service.
    // To restart the service on device reboot or unexpected problem, you need to allow below permission.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      // This function requires `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission.
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    assert(await FlutterForegroundTask.canScheduleExactAlarms);
    // if (!await FlutterForegroundTask.canScheduleExactAlarms) {
    //   // [maybe todo] explain to the user why we need this. wait, it doesn't send the user to the settings page it just opens a tooltip, seems clear enough? Or maybe this permission was already granted and this code doesn't really need to be here? I'll comment this out and replace it with just a check.
    //   await FlutterForegroundTask.openAlarmsAndRemindersSettings();
    // }
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

  if (await FlutterForegroundTask.isRunningService) {
    // in the example, they restart the service here, we're not gonna restart
    print("service is already running");
    FlutterForegroundTask.sendDataToTask({'op': 'hello'});
  } else {
    print("starting service");
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
      throw sr;
    }
  }

  // Start an interval timer that sends the heartbeat signal to the foreground task
  heartbeaterMain ??=
      Timer.periodic(const Duration(milliseconds: 1200), (timer) {
    print("heartbeat sent");
    FlutterForegroundTask.sendDataToTask({'op': 'heartbeat'});
  });
}
