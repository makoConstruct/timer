import 'dart:io';
import 'dart:async';
import 'dart:ui';
// this doesn't work from background isolates?
// import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';

void backthreadLog(String message, {String name = "ForegroundService"}) {
  print("[$name] $message");
}

// Holds all tracking data for a single timer in the background service
class TrackedTimer {
  final Mobj<TimerData> mobj;
  Timer? countdownTimer;
  Function()? unsubscribe;

  TrackedTimer(this.mobj);
}

// entrypoint for the persistent notification isolate
// [todo] does this have to be called startCallback
@pragma('vm:entry-point')
void foregroundTaskStart() {
  print("mako foregroundTaskStart");
  FlutterForegroundTask.setTaskHandler(PersistentNotificationTask());
}

class PersistentNotificationTask extends TaskHandler {
  late JukeBox jukeBox;
  bool _appActive = false;
  Timer? _heartbeatTimeout;
  // increased by running timers and by a grasp from the app isolate
  int refCount = 0;
  final Map<MobjID<TimerData>, TrackedTimer> _trackedTimers = {};

  void setAppActive(bool value) {
    if (_appActive != value) {
      _appActive = value;
      if (value) {
        onAppOpened();
      } else {
        onAppClosed();
      }
    }
  }

  void endTrackedTimer(TrackedTimer tracked) {
    tracked.unsubscribe?.call();
    tracked.countdownTimer?.cancel();
    tracked.countdownTimer = null;
    refCount--;
    _trackedTimers.remove(tracked.mobj.id);
    if (refCount <= 0) {
      FlutterForegroundTask.stopService();
    }
  }

  void onTimerDataChanged(TrackedTimer tracked) {
    backthreadLog("onTimerDataChanged ${tracked.mobj.id}",
        name: "ForegroundService");
    final timer = tracked.mobj;
    final ntp = timer.peek()!;
    if (ntp.isRunning) {
      tracked.countdownTimer?.cancel();
      backthreadLog("startTimerTimer ${timer.id}", name: "ForegroundService");
      tracked.countdownTimer = Timer(
          digitsToDuration(timer.peek()!.digits) -
              DateTime.now().difference(timer.peek()!.startTime), () {
        // trigger timer
        backthreadLog("timer triggered ${timer.id}", name: "ForegroundService");
        FlutterForegroundTask.sendDataToMain(
            {'op': 'timerTriggered', 'timerId': timer.id});
        jukeBox.playJarringSound();
        backthreadLog("timer triggered, refCount is $refCount",
            name: "ForegroundService");
        timer.value =
            timer.value!.withChanges(runningState: TimerData.completed);
        backthreadLog("timer triggered refCount: $refCount",
            name: "ForegroundService");
      });
    } else {
      endTrackedTimer(tracked);
    }
  }

  // so there may be a slight delay when the app is opening or closing where timers wont sound, during the changeover, but this is fine

  void onAppOpened() {
    backthreadLog("onAppOpened, refCount is $refCount");
    refCount++;
    // stop waiting on the timers, assume the app will handle them
    for (final tracked in _trackedTimers.values) {
      endTrackedTimer(tracked);
    }
    backthreadLog("onAppOpened2, refCount is $refCount");
  }

  Future<void> checkTimers() async {
    // this method doesn't have to worry about deletion, since deletions will come through as nullifications of the timer mobjs
    final timers = await Mobj.readCurrentValue<List<MobjID<TimerData>>>(
      timerListID,
      type: ListType(const StringType()),
    );

    backthreadLog("checking ${timers.length} timers, refCount is $refCount",
        name: "ForegroundService");
    for (final timerId in timers) {
      backthreadLog("checking timer $timerId", name: "ForegroundService");
      if (_trackedTimers[timerId] == null) {
        // Fetch the timer and set up tracking
        final mobj = await Mobj.fetch(timerId, type: TimerDataType());
        final TimerData data = mobj.peek()!;

        if (data.isRunning) {
          refCount++;
          final tracked = TrackedTimer(mobj);
          _trackedTimers[timerId] = tracked;
          tracked.unsubscribe = mobj.subscribe((_) {
            onTimerDataChanged(tracked);
          });
        }
      }
    }
  }

  void onAppClosed() async {
    // take over the work from the app
    // we don't have to subscribe to the timerlists, monitor for new timers, or anything like that, since no new timers will be created while the app is closed.
    backthreadLog("onAppClosed, refCount is $refCount",
        name: "ForegroundService");

    await checkTimers();

    // release the app's refcount
    refCount--;
    backthreadLog("onAppClosed refCount: $refCount", name: "ForegroundService");
    if (refCount <= 0) {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Initialize plugin support for background isolate
    // [todo] test to see if this works when the isolate is started on reboot. If not, I think we're kinda screwed.
    final token = RootIsolateToken.instance!;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);

    FlutterForegroundTask.sendDataToMain({'op': 'onStart Report'});
    backthreadLog("mako onStart $timestamp $starter, refCount is $refCount",
        name: "ForegroundService");
    jukeBox = await JukeBox.create();
    backthreadLog("mako onStart jukebox created", name: "ForegroundService");
    MobjRegistry.initialize(TheDatabase());
    backthreadLog("mako onStart database initialized",
        name: "ForegroundService");
    // assume the app wont have died instantly after spawning this isolate
    _appActive = starter == TaskStarter.developer;
    if (_appActive) {
      onAppOpened();
    } else {
      await checkTimers();
      if (refCount <= 0) {
        backthreadLog(
            "stopping service, since the app isn't open and no timers are running, refCount is $refCount",
            name: "ForegroundService");
        FlutterForegroundTask.stopService();
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _heartbeatTimeout?.cancel();
    backthreadLog("mako onDestroy $timestamp $isTimeout",
        name: "ForegroundService");
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
    // [todo] open the app
    backthreadLog("mako onNotificationPressed", name: "ForegroundService");
  }

  @override
  void onReceiveData(Object data) {
    Map<String, dynamic> dataMap = data as Map<String, dynamic>;
    String op = dataMap['op'] as String;
    resetHeartbeatTimeout() {
      _heartbeatTimeout?.cancel();
      _heartbeatTimeout = Timer(Duration(seconds: 2), () {
        backthreadLog("heartbeat timeout", name: "ForegroundService");
        setAppActive(false);
      });
    }

    switch (op) {
      case 'hello':
        setAppActive(true);
        resetHeartbeatTimeout();
        break;
      // there is no way to be reliably notified when a process is killed, so we do a heartbeat timer as well as the goodbye thing just in case that's killed
      case 'heartbeat':
        // for some reason the heartbeat continues to fire even after the app is closed. The heartbeat shouldn't trigger in that case.
        backthreadLog("heartbeat received", name: "ForegroundService");
        if (_appActive) {
          setAppActive(true);
          resetHeartbeatTimeout();
          break;
        }
      case 'goodbye':
        setAppActive(false);
        _heartbeatTimeout?.cancel();
        break;
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    // todo: pause/play the current timer
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
      channelId: 'mako_timer_foreground_service',
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
      notificationTitle: 'Foreground Service is running',
      notificationText: 'Tap to return to the app',
      notificationIcon: null,
      notificationButtons: [
        const NotificationButton(id: 'btn_hello', text: 'hello'),
      ],
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
