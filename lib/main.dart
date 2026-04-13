// this file tries to only concern itself with the core logic of the app. Anything whose functionality would be obvious just from its name/context but can't be fully modularized will be in boring.dart. Main and Boring aren't separable, so why separate them? I guess you could say main is like a "best of" of the code.

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:async';
import 'dart:async' as async;
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:awesome_notifications/awesome_notifications.dart'
    hide NotificationPermission;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_refresh_rate_control/flutter_refresh_rate_control.dart';
import 'package:improved_wrap/improved_wrap.dart';
// imported as because there's a name collision with Column, lmao
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' as physics;
import 'package:flutter/scheduler.dart' hide Priority;
import 'package:flutter/services.dart';
import 'package:hsluv/extensions.dart';
import 'package:makos_timer/platform_audio.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:makos_timer/background_service_stuff.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/boring.dart' as boring;
import 'package:makos_timer/crank_game.dart';
import 'package:makos_timer/journeying_game.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
import 'package:animove/animove.dart';
import 'package:signals/signals_flutter.dart';
import 'package:springster/springster.dart';
import 'package:uuid/v4.dart';

Future<void> deleteDatabase() async {
  final directory = await getApplicationSupportDirectory();
  final file = File(p.join(directory.path, '$databaseName.sqlite'));
  await file.delete();
  print("CRITICAL: deleted database file as commanded");
}

Future<void> torchDatabase(TheDatabase db) async {
  print('CRITICAL ERROR: Clearing all data from the database!');
  await db.kVs.deleteAll();
}

// think about this later after spawning a foreground task
// Future<DriftIsolate> createIsolateManually() async {
//   final receiveIsolate = ReceivePort('receive drift isolate handle');
//   await Isolate.spawn<SendPort>((message) async {
//     final server = DriftIsolate.inCurrent(() {
//       // Again, this needs to return the LazyDatabase or the connection to use.
//     });

//     // Now, inform the original isolate about the created server:
//     message.send(server);
//   }, receiveIsolate.sendPort);

//   final server = await receiveIsolate.first as DriftIsolate;
//   receiveIsolate.close();
//   return server;
// }

final sharedDriftIsolateName = "sharedDrift";

const databaseName = 'mako_timer_db';

const double timerOutline = 7;
const double timerGap = 11;
// might make this user-configurable
final Signal<double> timerWidgetRadius = Signal(25);

const double standardLineWidth = 6;

final GlobalKey<ScaffoldMessengerState> globalScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey configButtonKey = GlobalKey();

const backingCornerRounding = 0.37;
const backingDeflationProportion = 0.07;

/// I meticulously fitted the actual core of the play icon to this box. You can scale it to get a play icon that has the dimensions you want.
Widget fittedPlayIcon(color) => SizedBox(
      height: 10,
      width: 8.15,
      child: Transform.translate(
        offset: Offset(-6.3, -4.5),
        child: Icon(Icons.play_arrow_rounded, size: 19, color: color),
      ),
    );

/// Was supposed to be a custom Hero flight shuttle builder with 60ms delay, but I it looks like it does nothing, I can't see how the movement part of the animation would be affected by this, it would only affect an animation over the hero widget
/// should have been a builder for createRectTween instead
Widget delayedHeroFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final delayedAnimation = CurvedAnimation(
    parent: animation,
    curve: const Interval(0.3, 1.0, curve: Curves.fastOutSlowIn),
  );

  // Get the child from the destination hero
  final Widget toHeroChild = (flightDirection == HeroFlightDirection.push)
      ? (toHeroContext.widget as Hero).child
      : (fromHeroContext.widget as Hero).child;

  return AnimatedBuilder(
    animation: delayedAnimation,
    builder: (context, child) {
      return toHeroChild;
    },
  );
}

Future<void> initializeDatabase() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = TheDatabase();
  // the db will be accessed via this singleton from then on
  // initialize version one of the db
  await MobjRegistry.initialize(db);
  final fversion = Mobj.getOrCreate(dbVersionID,
      type: IntType(), initial: () => 0, debugLabel: "version");
  await Future.wait(<Future>[
    // we know that the data required for the app is minimal enough that we should wait until it's loaded before showing anything... idk not sure I believe this
    Mobj.getOrCreate(timerListID,
        type: ListType(StringType()), initial: () => <MobjID>[]),
    Mobj.getOrCreate(transientTimerListID,
        type: ListType(StringType()), initial: () => <MobjID>[]),
    Mobj.getOrCreate(nextHueID, type: DoubleType(), initial: () => 0.252),
    Mobj.getOrCreate(isRightHandedID,
        type: BoolType(), initial: () => true, debugLabel: "is right handed"),
    Mobj.getOrCreate(padVerticallyAscendingID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "pad vertically ascending"),
    Mobj.getOrCreate(selectedAudioID,
        type: AudioInfoType(),
        initial: () => PlatformAudio.assetSounds[0],
        debugLabel: "selected audio"),
    Mobj.getOrCreate(hasSelectedAudioID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "has selected audio"),
    Mobj.getOrCreate(persistentAlarmModeID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "persistent alarm mode"),
    Mobj.getOrCreate(timeFirstUsedApp,
        type: DateTimeType(),
        initial: () => DateTime.now(),
        debugLabel: "first used app"),
    Mobj.getOrCreate(hasCreatedTimerID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "has created timer"),
    Mobj.getOrCreate(exitedSetupID,
        type: BoolType(), initial: () => false, debugLabel: "left setup"),
    Mobj.getOrCreate(completedSetupID,
        type: BoolType(), initial: () => false, debugLabel: "completed setup"),
    Mobj.getOrCreate(buttonSpanID,
        type: DoubleType(), initial: () => 64.0, debugLabel: "button span"),
    Mobj.getOrCreate(buttonScaleDialOnID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "button scale dial on"),
    Mobj.getOrCreate(crankGameWinMessageIndexID,
        type: IntType(),
        initial: () => 0,
        debugLabel: "crank game win message index"),
    Mobj.getOrCreate(usedDragActionRecordID,
        type: IntType(),
        initial: () => 0,
        debugLabel: "used drag action count"),
    Mobj.getOrCreate(usedMenuCountID,
        type: IntType(), initial: () => 0, debugLabel: "used menu count"),
    Mobj.getOrCreate(hintGetsCompositeTimersID,
        type: BoolType(),
        initial: () => false,
        debugLabel: "has created cycle timer"),
    Mobj.getOrCreate(numberOfTimersCreatedID,
        type: IntType(),
        initial: () => 0,
        debugLabel: "number of timers created"),
    fversion,
  ]);
}

Future<void> enableHighRefreshRate() async {
  final refreshRateControl = FlutterRefreshRateControl();
  // Request high refresh rate
  await refreshRateControl.requestHighRefreshRate();
  // How to stop high refresh rate mode:
  // bool success = await _refreshRateControl.stopHighRefreshRate();
}

const mainNotificationPortName = 'main_notification';
ReceivePort? notificationResponseReceivePort;

void main() async {
  // await deleteDatabase();
  WidgetsFlutterBinding.ensureInitialized();
  SignalsObserver.instance = null;
  await Future.wait([
    enableHighRefreshRate(),
    initializeDatabase(),
    Future(() async {
      notificationResponseReceivePort = ReceivePort();
      // tombstone: registerPortWithName doesn't work if there's already a port with that name, so when main died and then was reborn, this registration would fail. So you have to removePortWithMapping first.
      IsolateNameServer.removePortNameMapping(mainNotificationPortName);
      IsolateNameServer.registerPortWithName(
          notificationResponseReceivePort!.sendPort, mainNotificationPortName);
      notificationResponseReceivePort!.listen((message) {
        if (message == 'dismissAlarms') {
          print("main message to dismissAlarms");
          globalTimerHolm?.dismissAlarms();
        }
      });
      await AwesomeNotifications()
          .initialize('resource://drawable/res_notification_icon', [
        NotificationChannel(
          channelKey: 'main_notification',
          channelName: 'Timer Completion',
          channelDescription: 'Notifications when timers complete',
          importance: NotificationImportance.High,
        ),
      ]);
      await AwesomeNotifications().setListeners(
        onActionReceivedMethod: onNotificationActionReceived,
        onDismissActionReceivedMethod: onNotificationDismissedReceived,
      );
    })
  ]);
  runApp(const TimersApp());
}

void _sendDismissAlarms() {
  IsolateNameServer.lookupPortByName(mainNotificationPortName)
      ?.send('dismissAlarms');
  IsolateNameServer.lookupPortByName(foregroundServicePortName)
      ?.send('dismissAlarms');
}

@pragma('vm:entry-point')
Future<void> onNotificationActionReceived(ReceivedAction action) async {
  print("onNotificationActionReceived: $action");
  _sendDismissAlarms();
}

@pragma('vm:entry-point')
Future<void> onNotificationDismissedReceived(ReceivedAction action) async {
  print("onNotificationDismissedReceived: $action");
  _sendDismissAlarms();
}

void onDataReceived(Object data) {
  print("data received: $data");
}

final Signal<bool> isBackgrounded = Signal(false);

TimerHolm? globalTimerHolm;

/// this is in charge of running timer sounds in response to changes to the timer list
/// eventually it will be responsible for doing repeat timer logic
/// ideally the background thread would also use it
class TimerHolm {
  late JukeBox jukeBox;
  final Mobj<List<MobjID<TimerData>>> list;
  Map<MobjID<TimerData>, TimerTrack> tracking = {};
  // initialized to a high number to make sure that notifications from the main thread wont id collide with notifications from the background thread
  int _notificationIdCounter = 200000;

  late EffectCleanup _backgroundedReaction;
  late StreamSubscription<Mobj<TimerData>> _newTimerReaction;
  late QuerySet<TimerData> allTimers;
  TimerHolm(
      {required this.list,
      required this.jukeBox,
      bool dismissOnForeground = true}) {
    allTimers = MobjRegistry.createQuerySet(TimerDataType());
    // runs every time a new timer is created or loaded
    _newTimerReaction = allTimers.forAll((mobj) {
      if (!tracking.containsKey(mobj.id)) {
        final tt = TimerTrack()..mobj = mobj;
        tracking[mobj.id] = tt;
        tt.subscription = enlivenTimer(tt, mobj, jukeBox);
      }
    });
    _backgroundedReaction = effect(() {
      if (dismissOnForeground && !isBackgrounded.value) {
        dismissAlarms();
      }
    });
  }

  void dismissAlarms() {
    jukeBox.stopAudio();
    print("dismissAlarms");
    AwesomeNotifications().cancelAll();
    for (final tt in tracking.values) {
      print("dismissing alarm ${tt.mobj?.id}");
      final d = tt.mobj?.peek();
      if (d != null && d.isGoingOff) {
        tt.mobj!.value = d.withChanges(isGoingOff: false);
        tt.vibrationRepeatTimer?.cancel();
        tt.vibrationRepeatTimer = null;
      }
    }
  }

  Future<void> _sendCompletionNotification(TimerTrack tt) async {
    print("_sendCompletionNotification");
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: _notificationIdCounter++,
        channelKey: completionChannelKey,
        title: 'timer complete',
        body: tt.mobj?.peek()?.title ?? 'tap to dismiss',
        bigPicture: 'resource://drawable/res_large_notification_icon',
        notificationLayout: NotificationLayout.BigPicture,
        actionType: ActionType.DismissAction,
        locked: true,
        autoDismissible: true,
        category: NotificationCategory.Alarm,
        // my phone screen already wakes up for alarms, so maybe we shouldn't override os default, if that's what this does, and if that's not what it does maybe it does nothing. And yes I went trhough the convoluted 5 clicks required to find out whether this is default true and it isn't.
        // wakeUpScreen: true,
      ),
      actionButtons: [
        NotificationActionButton(
          key: 'dismiss',
          label: 'dismiss',
          actionType: ActionType.DismissAction,
          autoDismissible: true,
        ),
      ],
    );
  }

  void stopTracking(MobjID id) {
    final tt = tracking[id];
    if (tt == null) {
      return;
    }
    tt.completionTimer?.cancel();
    tt.completionTimer = null;
    tt.startAlarmTimer?.cancel();
    tt.startAlarmTimer = null;
    tt.subscription?.call();
    tt.subscription = null;
    tt.mobj = null;
    tracking.remove(id);
  }

  void _timerStartAlarm(TimerTrack tt, Mobj<TimerData> mobj) {
    tt.startAlarmTimer = null;
    vibrateAlertOnce();
    final audio =
        Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType()).value!;
    jukeBox.playAudio(audio);
  }

  void _timerGoesOff(TimerTrack tt, Mobj<TimerData> mobj) {
    final d = mobj.value!;
    tt.completionTimer = null;
    if (d.soundsOnStart) {
      // alarm already played at start; complete silently
      mobj.value = d.withRunningState(TimerData.completed);
      returnAndContinueParent(mobj);
      return;
    } else {
      vibrateAlertOnce();
      final audio =
          Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType()).value!;
      final persistentAlarmMode =
          Mobj.getAlreadyLoaded(persistentAlarmModeID, BoolType()).value ??
              false;
      if (isBackgrounded.peek() && (d.persistentAlarm ?? persistentAlarmMode)) {
        // then it needs to send a notification and scream repeatedly until acknowledged
        jukeBox.playAudioLooping(audio);
        mobj.value = d
            .withRunningState(
              TimerData.completed,
            )
            .withChanges(isGoingOff: true);
        tt.vibrationRepeatTimer?.cancel();
        tt.vibrationRepeatTimer = async.Timer.periodic(
            const Duration(seconds: 8), (_) => vibrateAlertOnce());
        _sendCompletionNotification(tt);
      } else {
        jukeBox.playAudio(audio);
        mobj.value = d.withRunningState(TimerData.completed);
      }
      // actuate any parent timers
      returnAndContinueParent(mobj);
    }
  }

  /// calls the next timer in the chain and such
  /// it's kind of like the reverse of a program stack, like we're going to be creating a lot of unnecessary stack frames that don't mean anything and don't do anything on unwind. I considered rearranging this to use a more conventional interpreter structure but it just wasn't necessary.
  static void returnAndContinueParent(Mobj<TimerData> childMobj) {
    final child = childMobj.peek();
    if (child?.parentId == null) return;

    final parentMobj =
        Mobj.seekTypedAlreadyLoaded(child!.parentId!, TimerDataType());
    // if the parent isn't a timer, can't be actuated
    if (parentMobj == null) return;
    TimerData parent = parentMobj.peek()!;

    switch (parent.kind) {
      case TimerKind.series:
      case TimerKind.loop:
        final childIdx = parent.children.indexOf(childMobj.id);
        final nextIdx = (childIdx + 1) % parent.children.length;
        if (parent.kind != TimerKind.loop && nextIdx == 0) {
          returnAndContinueParent(parentMobj);
        } else {
          bool timerComplete =
              startTimer(parentMobj, reset: false, suggestedStart: nextIdx);
          if (timerComplete) {
            returnAndContinueParent(parentMobj);
          }
        }
      case TimerKind.parallelStartJustified:
        final allCompleted = parent.children.every((id) =>
            Mobj.getAlreadyLoaded(id, TimerDataType()).peek()?.isCompleted ??
            false);
        if (allCompleted) {
          parentMobj.value = parent.withChanges(
            runningState: TimerData.completed,
            completedRecently: true,
          );
          returnAndContinueParent(parentMobj);
        }
      // parallelEndJustified: completion is handled by TimerTrack.completionTimer in enlivenTimer
      default:
        break;
    }
  }

  /// how each timer is subscribed to and responded to, imbued with spirit and voice
  /// I'm not sure how I really feel about this approach, where everything is reactions. There are many situations where we had to fully understand how this reaction converges with itself when it causes reactions in the process of doing its thing. Yet, there was always a way to make it converge.
  void Function() enlivenTimer(
      TimerTrack tt, Mobj<TimerData> mobj, JukeBox jukeBox) {
    // once null always null
    if (mobj.peek() == null) {
      return () {};
    }
    TimerData? prev;
    return effect(() {
      final TimerData? d = mobj.value;
      if (d == null) {
        // delete its children too if it has any
        if (prev?.isComposite ?? false) {
          for (final childId in prev!.children) {
            Mobj.getAlreadyLoaded(childId, TimerDataType()).value = null;
          }
        }
        //remove it from its parent
        final parent = Mobj.seekTypedsAlreadyLoaded(
            prev!.parentId!, [TimerDataType(), ListType(StringType())]);
        if (parent != null && parent.peek() != null) {
          writeBackChildren(
              parent, childrenOf(parent).toList()..remove(mobj.id));
        }
        stopTracking(mobj.id);
      } else {
        if (prev?.isRunning != d.isRunning) {
          switch (d.kind) {
            case TimerKind.timer:
              // delete most of this, this should be handled by the thing that triggers the change in state, since it needs to propagate in one direction or another, without stepping on itself, which may be possible with effects, but effects make it less clear what's happening
              if (d.isRunning) {
                tt.startAlarmTimer?.cancel();
                tt.completionTimer?.cancel();
                final total = Duration(
                    microseconds: (totalDuration(d) * 1000000).round());
                final elapsed = DateTime.now().difference(d.startTime);
                if (d.soundsOnStart) {
                  // fire start alarm when startTime arrives (startTime is in the future by the delay)
                  final timeUntilStart = d.startTime.difference(DateTime.now());
                  tt.startAlarmTimer = async.Timer(
                      timeUntilStart.isNegative
                          ? Duration.zero
                          : timeUntilStart,
                      () => _timerStartAlarm(tt, mobj));
                }
                tt.completionTimer = async.Timer(
                    Duration(
                        milliseconds: (total - elapsed).inMilliseconds.ceil()),
                    () => _timerGoesOff(tt, mobj));
              } else {
                tt.startAlarmTimer?.cancel();
                tt.startAlarmTimer = null;
                tt.completionTimer?.cancel();
                tt.completionTimer = null;
              }
            case TimerKind.parallelEndJustified:
              if (d.isRunning) {
                tt.completionTimer?.cancel();
                final total = Duration(
                    microseconds: (totalDuration(d) * 1000000).round());
                final elapsed = DateTime.now().difference(d.startTime);
                tt.completionTimer = async.Timer(
                    Duration(
                        milliseconds: (total - elapsed).inMilliseconds.ceil()),
                    () => _timerGoesOff(tt, mobj));
              } else {
                tt.completionTimer?.cancel();
                tt.completionTimer = null;
              }
            // tombstone: the reason timercule behaviors are handled by togglePlaying methods is that when we were handling them here, the reaction would get in its own way. Starting a timer in a timercule parent would also start the parent, which would then start the first child, and pause all others, which may then again cycle or something, I don't know, I don't think it did cycle, but things weren't working right, and it was hard to reason about a pure reactive approach, so I decided to just use methods.
            default:
          }
        }

        /// check if it's a cycle timer to dismiss that hint
        if (d.isComposite && d.children.length > 1) {
          Mobj.getAlreadyLoaded(hintGetsCompositeTimersID, BoolType()).value =
              true;
        }
      }
      prev = d;
    });
  }

  void dispose() {
    _backgroundedReaction();
    _newTimerReaction.cancel();
    allTimers.dispose();
    for (final tt in tracking.values) {
      tt.completionTimer?.cancel();
      tt.startAlarmTimer?.cancel();
      tt.vibrationRepeatTimer?.cancel();
      tt.subscription?.call();
    }
    tracking.clear();
  }
}

void resetTimer(MobjID ki) {
  final mobj = Mobj.getAlreadyLoaded(ki, TimerDataType());
  mobj.value = mobj.peek()!.withChanges(
      ranTime: Duration.zero,
      runningState: TimerData.completed,
      startTime: DateTime.now(),
      completedRecently: false);
  // also reset children
  for (final childId in mobj.peek()!.children) {
    resetTimer(childId);
  }
}

class TimerTrack {
  Function()? subscription;
  async.Timer? completionTimer;
  async.Timer? startAlarmTimer;
  async.Timer? vibrationRepeatTimer;
  Mobj<TimerData>? mobj;
}

/// Toggle this timer and propagate to children and parents via Mobj graph.
/// Returns whether the timer is now running.
bool toggleRunning(Mobj<TimerData> mobj, {bool reset = false}) {
  final data = mobj.peek()!;
  final wasRunning = data.isRunning;
  final nowRunning = !wasRunning;

  if (nowRunning) {
    bool instantlyComplete = startTimer(mobj, reset: reset);
    if (instantlyComplete) {
      TimerHolm.returnAndContinueParent(mobj);
    }
  } else {
    pauseTimer(mobj, reset: reset);
  }

  return nowRunning;
}

void pauseTimer(Mobj<TimerData> mobj, {required bool reset}) {
  final d = mobj.peek()!;
  if (d.isComposite && d.children.isNotEmpty) {
    _pauseRunningChildren(d, reset: reset);
  }
  _pauseAncestorsIfNeeded(d.parentId);

  mobj.value = d.withRunningState(TimerData.paused, reset: reset);
}

/// important, if it returns true, that means it was synchronous and it's done, it wont leave an asynchronous timer or whatever running and then call back in through returnAndContinueParent, so you should continue to run the next one.
/// the boolean return has the same meaning for all the methods below too
bool startTimer(Mobj<TimerData> mobj,
    {bool reset = false, Duration? delay, int suggestedStart = 0}) {
  if (reset) {
    resetTimer(mobj.id);
  }
  final d = mobj.peek()!;
  _startAncestors(d.parentId);
  if (d.isComposite) {
    bool ret = _startChildren(d, delay: delay, suggestedStart: suggestedStart);
    mobj.value =
        d.withRunningState(ret ? TimerData.completed : TimerData.running);
    return ret;
  } else {
    mobj.value = d.toggleRunning(reset: reset);
    return false;
  }
}

bool _startChildren(TimerData host, {Duration? delay, int suggestedStart = 0}) {
  bool parallelStartJustified() {
    // then some of them aren't completed, so to continue, only restart those ones
    bool alreadyCompleted = true;
    for (final childId in host.children) {
      final child = Mobj.getAlreadyLoaded(childId, TimerDataType());
      if (child.peek()!.runningState != TimerData.running) {
        alreadyCompleted =
            _startSingle(child, delay: delay) && alreadyCompleted;
      }
    }
    return alreadyCompleted;
  }

  if (host.children.isEmpty) {
    return true;
  }
  switch (host.kind) {
    case TimerKind.loop:
    case TimerKind.series:
      // if any of the timers are paused rather than completed, (ignore suggestedStart and) resume at that point in the chain. (if any of the timers are running, do nothing)
      // find the first non-complete child
      Mobj<TimerData>? firstPausedChild;
      int firstPausedIndex = -1;
      for (int i = 0; i < host.children.length; i++) {
        final child = Mobj.getAlreadyLoaded(host.children[i], TimerDataType());
        switch (child.peek()!.runningState) {
          case TimerData.running:
            // there's nothing to do, already started
            return false;
          case TimerData.paused:
            firstPausedChild = child;
            firstPausedIndex = i;
            break;
          case TimerData.completed:
            continue;
          default:
            throw Exception(
                'Invalid timer state: ${child.peek()!.runningState}');
        }
      }

      final int startingIndex;
      if (firstPausedChild != null) {
        if (firstPausedChild.peek()!.isRunning) {
          return false;
        } // otherwise, it's paused, so we should start it
        startingIndex = firstPausedIndex;
      } else {
        startingIndex = suggestedStart;
      }
      // execute every already complete until it ends or loops
      int ci = startingIndex;
      bool taskAlreadyComplete = true;
      while (true) {
        final child = Mobj.getAlreadyLoaded(host.children[ci], TimerDataType());
        if (child.peek()!.isRunning) {
          return false;
        }
        taskAlreadyComplete = _startSingle(child, delay: delay);
        if (!taskAlreadyComplete) {
          return false;
        }
        // then this loops forever without going async. we should consider throwing or displaying an alert. But in the least we should terminate it and report that it was instant.
        ci += 1;
        if (ci == host.children.length) {
          if (host.kind == TimerKind.series) {
            return true;
          } else {
            // loop
            ci = 0;
          }
        }
        if (ci == startingIndex) {
          return true;
        }
      }
    case TimerKind.parallelStartJustified:
      return parallelStartJustified();
    case TimerKind.parallelEndJustified:
      // determine the max duration of the children, and start subtimers with delays to pad.
      if (host.isCompleted) {
        List<Duration?> childDurations = host.children
            .map((childId) => remainingTimerDuration(
                Mobj.seekAlreadyLoaded(childId, TimerDataType())?.peek()))
            .toList();
        final Duration? md = maxRemainingDurationOfList(childDurations);
        if (md == null) {
          // oh, maybe instead of this, it should run end-justified parallel just wrt the ones that have finite durations.
          return parallelStartJustified();
        } else {
          bool alreadyCompleted = true;
          for (int i = 0; i < host.children.length; i++) {
            final d = childDurations[i];
            final innerDelay = d == null
                ? Duration.zero
                : maxDuration(Duration.zero, md - d) + (delay ?? Duration.zero);
            alreadyCompleted = _startSingle(
                    Mobj.getAlreadyLoaded(host.children[i], TimerDataType()),
                    delay: innerDelay) &&
                alreadyCompleted;
          }
          return alreadyCompleted;
        }
      } else if (host.isPaused) {
        bool alreadyCompleted = true;
        for (final childId in host.children) {
          final child = Mobj.getAlreadyLoaded(childId, TimerDataType());
          if (!child.peek()!.isCompleted) {
            alreadyCompleted =
                _startSingle(child, delay: delay) && alreadyCompleted;
          }
        }
        return alreadyCompleted;
      } else {
        return false;
      }

    default:
      throw Exception(
          'Invalid timer kind: ${host.kind}, _startChildren should only be passed composite timers');
  }
}

bool _startSingle(Mobj<TimerData> mobj, {Duration? delay}) {
  final data = mobj.peek()!;
  if (data.isRunning) return false;
  if (data.isComposite) {
    bool r = _startChildren(data, delay: delay);
    mobj.value =
        data.withRunningState(r ? TimerData.completed : TimerData.running);
    return r;
  } else {
    mobj.value = data.toggleRunning(delay: delay);
    return false;
  }
}

void _pauseRunningChildren(TimerData parent, {required bool reset}) {
  for (final childId in parent.children) {
    _pauseSingle(Mobj.getAlreadyLoaded(childId, TimerDataType()), reset: reset);
  }
}

void _pauseSingle(Mobj<TimerData> mobj, {required bool reset}) {
  final data = mobj.peek()!;
  // is this incorrect? if reset is on, shouldn't we go from paused to completed? Yes. It's not correct.
  if (!data.isRunning) return;
  mobj.value = data.toggleRunning(reset: reset);
  if (data.isComposite && data.children.isNotEmpty) {
    _pauseRunningChildren(data, reset: reset);
  }
}

void _startAncestors(MobjID? parentId) {
  if (parentId == null) return;
  final parentMobj = Mobj.seekTypedAlreadyLoaded(parentId, TimerDataType());
  if (parentMobj == null) return;
  final pp = parentMobj.peek();
  if (pp == null) return;
  if (!pp.isRunning) {
    parentMobj.value = pp.toggleRunning(reset: false);
  }
  _startAncestors(pp.parentId);
}

void _pauseAncestorsIfNeeded(MobjID? parentId) {
  if (parentId == null) return;
  final parentMobj = Mobj.seekTypedAlreadyLoaded(parentId, TimerDataType());
  if (parentMobj == null) return;
  final pp = parentMobj.peek();
  if (pp == null || !pp.isRunning) return;

  switch (pp.kind) {
    case TimerKind.loop:
    case TimerKind.series:
      parentMobj.value = pp.toggleRunning(reset: true);
      _pauseRunningChildren(pp, reset: true);
    case TimerKind.parallelStartJustified:
      if (!pp.children.any((id) =>
          Mobj.getAlreadyLoaded(id, TimerDataType()).peek()!.isRunning)) {
        parentMobj.value = pp.toggleRunning(reset: true);
      } else {
        return;
      }
    default:
      return;
  }
  _pauseAncestorsIfNeeded(pp.parentId);
}

/// Whether the timer should be deleted automatically. Note, checks by `value` so will susbcribe if called in an effect.
bool trivialAndClearable(Mobj<TimerData> mobj, TimerData? prev) {
  final d = mobj.value ?? prev;
  if (d == null) {
    return false;
  }
  if (d.pinned ||
      d.isComposite ||
      d.title != null ||
      d.isRunning ||
      d.selected) {
    return false;
  }
  if (mobj.peek() == null) {
    return d.parentId == null;
  }
  final parent = Mobj.seekTypedAlreadyLoaded(d.parentId!, TimerDataType());
  if (parent == null) {
    return true;
  }
  return trivialAndClearable(parent, prev);
}

// Global to cache screen corner radius
ScreenRadius? _cachedCornerRadius;
ScreenRadius defaultCornerRadius = ScreenRadius.value(0.0);
Future<ScreenRadius> _loadCornerRadius() async {
  if (_cachedCornerRadius != null) return _cachedCornerRadius!;
  try {
    _cachedCornerRadius = await ScreenCornerRadius.get() ?? defaultCornerRadius;
  } on UnimplementedError catch (_) {
    _cachedCornerRadius = defaultCornerRadius;
  } on MissingPluginException catch (_) {
    _cachedCornerRadius = defaultCornerRadius;
  }
  return _cachedCornerRadius!;
}

ScreenRadius getCachedCornerRadius() =>
    _cachedCornerRadius ?? defaultCornerRadius;

class TimersApp extends StatefulWidget {
  const TimersApp({super.key});

  @override
  State<TimersApp> createState() => _TimersAppState();
}

class _TimersAppState extends State<TimersApp> with WidgetsBindingObserver {
  late final JukeBox jukeBox;
  _TimersAppState() {
    WidgetsFlutterBinding.ensureInitialized();
    jukeBox = JukeBox.create();
  }
  @override
  void initState() {
    super.initState();
    _loadCornerRadius();

    // Enable edge-to-edge mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    WidgetsBinding.instance.addObserver(this);

    // start listening to all currently existing timers (I'd like if this were listening to the lists, but we tried implementing that with background task and it was complicated and didn't quite come together, again, we don't need to, there's only one other place new timers are added through)
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      isBackgrounded.value = true;
    } else if (state == AppLifecycleState.resumed) {
      isBackgrounded.value = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    ThemeData makeTheme(Brightness brightness) {
      return ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.white,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
          // brightness: (() {
          //   print("CRITICAL WARNING: overriding theme for debugging purposes");
          //   return Brightness.light;
          // })(),
          brightness: brightness,
        ),
        useMaterial3: true,
      );
    }

    return MultiProvider(
      providers: [
        Provider<Thumbspan>(
            create: (context) => Thumbspan(lpixPerThumbspan(context))),
        Provider<JukeBox>(create: (_) => jukeBox),
      ],
      child: MaterialApp(
        scaffoldMessengerKey: globalScaffoldMessengerKey,
        title: 'timer',
        theme: makeTheme(Brightness.light),
        darkTheme: makeTheme(Brightness.dark),
        // darkTheme: makeTheme(Brightness.light),
        onGenerateRoute: (settings) {
          if (settings.name == '/') {
            return CircularRevealRoute(
              builder: (context) => TimerScreen(),
            );
          }
          if (settings.name == '/onboard') {
            return CircularRevealRoute(
              builder: (context) => OnboardScreen(),
              iconOriginKey: configButtonKey,
            );
          }
          return null;
        },
        onGenerateInitialRoutes: (initialRouteName) {
          final completedSetup =
              Mobj.getAlreadyLoaded(completedSetupID, BoolType()).value ??
                  false;
          if (completedSetup) {
            return <Route<dynamic>>[
              CircularRevealRoute(builder: (context) => TimerScreen()),
            ];
          } else {
            // Start with a blank placeholder, then onboarding on top.
            // When onboarding completes, only then are we able to initialize TimerScreen, and at that time we replaceRouteBelow with TimerScreen (we can't just push below at that time because for some reason Navigator doesn't support that) then we pop(). The pop animation is the one we want, so pushReplace wouldn't work either.
            return <Route>[
              PageRouteBuilder(
                pageBuilder: (context, __, ___) => ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerLowest),
                transitionDuration: Duration.zero,
              ),
              CircularRevealRoute(
                  builder: (context) => OnboardScreen(isRootal: true),
                  reverseTransitionDuration: Duration(milliseconds: 350),
                  iconOriginKey: configButtonKey),
            ];
          }
        },
      ),
    );
  }
}

class TimerMenu extends StatelessWidget {
  final MobjID<TimerData> timerID;
  final Rect centerOn;
  final List<Widget> items;
  final double? estimatedWidth;
  final Animation<double> animation;
  static const double buttonHeight = 40;
  final Color? backgroundColor;
  final double arrowHeight;
  const TimerMenu({
    super.key,
    this.estimatedWidth,
    required this.timerID,
    required this.centerOn,
    required this.items,
    required this.animation,
    required this.arrowHeight,
    this.backgroundColor,
  });
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const double margin = 12;
      final theme = Theme.of(context);
      final mt = MakoThemeData.fromTheme(theme);
      final backgroundColor = this.backgroundColor ?? mt.foreBackColor;
      final buttonSpan =
          Mobj.getAlreadyLoaded(buttonSpanID, DoubleType()).value!;
      Offset tentativeArrowCenter = topLeftManhattanCenter(centerOn);
      // correct arrowCenter to make sure it's not too close to either side
      final minDistanceFromSide =
          margin + backingCornerRounding * buttonSpan + arrowHeight;
      final arrowCenter = Offset(
          clampDouble(tentativeArrowCenter.dx, minDistanceFromSide,
              constraints.maxWidth - minDistanceFromSide),
          tentativeArrowCenter.dy);
      final width = min(estimatedWidth ?? buttonSpan * 3.8,
          constraints.maxWidth - margin * 2);
      final left = min(max(margin, arrowCenter.dx - width / 2),
          constraints.maxWidth - margin - width);
      final cornerRounding = backingCornerRounding * buttonSpan * 1.2;
      final top = centerOn.bottom - arrowHeight;
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final curve = animation.status == AnimationStatus.forward
              ? Curves.easeOutQuart
              : Curves.easeOut;
          final p = animation.status == AnimationStatus.forward
              ? animation.value
              // so that it's effectively shorter on the reverse traversal
              : unlerpUnit(0.5, 1, animation.value);
          return Stack(children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              child: ClipPath(
                clipper: _MenuRevealClipper(
                  progress: curve.transform(unlerpUnit(0, 0.7, p)),
                  // happens to make the origin be the center of the clockface
                  origin: arrowCenter - Offset(left, top),
                  cornerRounding: cornerRounding,
                  arrowHeight: arrowHeight,
                ),
                child: Container(
                  color: backgroundColor,
                  child: Opacity(
                    opacity: Curves.easeInOut.transform(unlerpUnit(0.37, 1, p)),
                    child: Column(children: items.toList()),
                  ),
                ),
              ),
            ),
          ]);
        },
      );
    });
  }
}

class _MenuRevealClipper extends CustomClipper<Path> {
  final double progress;
  final Offset origin;
  final double cornerRounding;
  final double arrowHeight;

  _MenuRevealClipper({
    required this.progress,
    required this.origin,
    required this.cornerRounding,
    required this.arrowHeight,
  });

  @override
  Path getClip(Size size) {
    // morphs from intermediateRect to targetRect
    // it's complicated because it was arrived at by iterating towards something that felt right
    Size targetRectSize = Size(size.width, size.height - arrowHeight);
    // should start already being wide enough to be flush with the arrow bottom
    final targetRect = RRect.fromRectAndRadius(
      Offset(0, arrowHeight) & targetRectSize,
      Radius.circular(cornerRounding),
    );
    final intermediateTargetSpan =
        min(targetRectSize.height, targetRectSize.width);
    final earlyProgress = unlerpUnit(0, 0.5, progress);
    final distanceFromCenter = origin - sizeToOffset(targetRectSize / 2);
    final Offset earlyOrigin = Offset(origin.dx, targetRect.top);
    final intermediateOriginTarget =
        // Offset(0, arrowHeight) +
        (distanceFromCenter.dx > distanceFromCenter.dy
            ? Offset(
                origin.dx.clamp(intermediateTargetSpan / 2,
                    targetRectSize.width - intermediateTargetSpan / 2),
                targetRect.center.dy)
            : Offset(
                targetRect.center.dx,
                origin.dy.clamp(intermediateTargetSpan / 2,
                    targetRectSize.height - intermediateTargetSpan / 2)));
    final arrowProgress =
        Curves.easeOut.transform(unlerpUnit(0.15, 0.7, progress));
    var earlyCornerRounding = cornerRounding * earlyProgress;
    final earlySpan = arrowHeight * arrowProgress * 2 + 2 * earlyCornerRounding;
    final earlyRect = RRect.fromRectAndRadius(
        rectFromAlign(
            align: Alignment.topCenter,
            anchor: earlyOrigin,
            width: earlySpan,
            height: lerp(0, earlySpan, earlyProgress)),
        Radius.circular(earlyCornerRounding));
    // intermediate rect target is square
    final intermediateRect = RRect.fromRectAndRadius(
      Rect.fromCircle(
          center: intermediateOriginTarget, radius: intermediateTargetSpan / 2),
      Radius.circular(cornerRounding),
    );
    // final lerpr = RRect.lerp(
    //     earlyRect,
    //     RRect.lerp(
    //         intermediateRect, targetRect, unlerpUnit(0.37, 1, progress))!,
    //     unlerpUnit(0.2, 0.65, progress))!;

    final lerpr = RRect.lerp(
        RRect.fromRectAndRadius(Rect.fromCircle(center: origin, radius: 0),
            Radius.circular(lerp(size.width / 2, cornerRounding, progress))),
        targetRect,
        progress)!;

    Path arrowPath = Path();
    {
      final ah = arrowHeight * arrowProgress;
      final w = arrowHeight * 2 * arrowProgress;
      final h = ah;
      final stemw = w * 0.2;
      final basew = (w - stemw) / 2;
      final minHeight = basew + stemw / 2;
      final double additionalHeight = max(h - minHeight, 0);
      arrowPath.moveTo(origin.dx - w / 2, arrowHeight);
      arrowPath.relativeArcToPoint(Offset(basew, -basew),
          radius: Radius.circular(basew), rotation: pi / 2, clockwise: false);
      arrowPath.relativeLineTo(0, additionalHeight);
      arrowPath.relativeArcToPoint(Offset(stemw, 0),
          radius: Radius.circular(stemw / 2), rotation: pi, clockwise: true);
      arrowPath.relativeLineTo(0, -additionalHeight);
      arrowPath.relativeArcToPoint(Offset(basew, basew),
          radius: Radius.circular(basew), rotation: pi / 2, clockwise: false);
      arrowPath.close();
    }

    return Path.combine(
        PathOperation.union, Path()..addRRect(lerpr), arrowPath);
  }

  @override
  bool shouldReclip(_MenuRevealClipper old) =>
      old.progress != progress || old.origin != origin;
}

abstract class TimerBase extends StatefulWidget {
  final Mobj<TimerData> mobj;
  final bool animateIn;
  final void Function()? onTap;
  const TimerBase({
    super.key,
    required this.mobj,
    this.animateIn = true,
    this.onTap,
  });
}

abstract class TimerBaseState<T extends TimerBase> extends State<T>
    with SignalsMixin, TickerProviderStateMixin {
  TimerData get p => widget.mobj.peek()!;

  late final AnimationController _appearanceAnimation;
  late final AnimationController _unpinnedIndicatorShowing;
  late final AnimationController _unpinnedIndicatorFullyShowing;
  // currently inactive. I was considering using this for doing a deletion where most of the deletion animation happens in-place and then it's shunted out into another layer just for the end.
  late final Computed<bool> whetherPinned;
  late final Computed<bool> _shouldFade;
  final GlobalKey animatedToKey = GlobalKey();
  // used to prevent the deletion animation from being interfered with by animated to, which unfortunately only pays attention to paint position, so slows down even non-layout position transforms.
  late final Signal<bool> animatedToDisabled = Signal(false);
  static const Duration _deletionAnimationDuration =
      Duration(milliseconds: 270);
  bool _deleted = false;
  Rect? _deletionLayoutRect;
  AnimationController? _deletionAnimation;
  Widget? _deletionHostChild;
  final transferrableKey = GlobalKey();
  MobjID<TimerData>? parentBeforeDrag;
  int? indexBeforeDrag;
  bool hasDisabled = false;
  TimerData? previousValue;
  bool _titleEditMode = false;
  final FocusNode _titleFocusNode = FocusNode();
  late final TextEditingController _titleController = TextEditingController();

  static Color backgroundColor(double hue) =>
      hpluvToRGBColor([hue * 360, 100, 90]);
  static Color primaryColor(double hue) =>
      hpluvToRGBColor([hue * 360, 100, 30]);

  /// called after base animations are initialized, before the reactive effect is created
  void onInitState() {}

  /// called by the reactive effect whenever timer data changes
  void onTimerDataChanged(TimerData d, TimerData? prev) {}

  @override
  void initState() {
    super.initState();
    whetherPinned = Computed(() => widget.mobj.value?.pinned ?? false);
    _shouldFade = Computed(() {
      return trivialAndClearable(widget.mobj, previousValue);
    });
    _appearanceAnimation = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
    if (widget.animateIn) {
      _appearanceAnimation.forward();
    } else {
      _appearanceAnimation.value = 1;
    }
    _unpinnedIndicatorShowing = AnimationController(
        duration: const Duration(milliseconds: 150), vsync: this);
    _unpinnedIndicatorFullyShowing = AnimationController(
        duration: const Duration(milliseconds: 150), vsync: this);
    onInitState();
    createEffect(() {
      final TimerData? d = widget.mobj.value;
      if (d == null) {
        // move this widget into a transient overlay deletion animation, and trust timerHolm to remove this from its parent in time for the next render so that there wont be a globalkey collision.
        // but only do this if its parent was also not deleted, because if the parent was deleted, it will be animating the disappearance instead
        final parent = Mobj.seekTypedsAlreadyLoaded(previousValue!.parentId!,
            [TimerDataType(), ListType(StringType())]);
        if (parent == null ||
            parent.peek() != null ||
            parent is Mobj<List<String>>) {
          if (mounted && !_deleted) {
            final renderBox = context.findRenderObject() as RenderBox?;
            final timerScreen =
                context.findAncestorStateOfType<TimerScreenState>();
            timerScreen?.timerWidgetCache.remove(widget.mobj.id);
            if (renderBox != null && renderBox.hasSize) {
              final ephemeralAnimationLayer = context
                  .findAncestorStateOfType<TimerScreenState>()!
                  .ephemeralAnimationLayer;
              final tr = boxRectRelativeTo(
                  boring.renderBox(widget.key as GlobalKey),
                  ephemeralAnimationLayer.currentContext?.findRenderObject()
                      as RenderBox?)!;
              animatedToDisabled.value = true;
              _deletionLayoutRect = tr;
              _deletionAnimation = AnimationController(
                duration: _deletionAnimationDuration,
                vsync: this,
              );
              _deletionAnimation!.addStatusListener((status) {
                if (status != AnimationStatus.completed) return;
                _deletionAnimation?.dispose();
                _deletionAnimation = null;
                final timerScreen =
                    context.findAncestorStateOfType<TimerScreenState>();
                if (_deletionHostChild != null) {
                  timerScreen?.ephemeralAnimationLayer.currentState
                      ?.remove(_deletionHostChild!);
                  _deletionHostChild = null;
                }
              });
              _deletionHostChild = Positioned(
                left: tr.left,
                top: tr.top,
                child: widget,
              );
              ephemeralAnimationLayer.currentState!.add(_deletionHostChild!);
              setState(() {
                _deleted = true;
              });
              _deletionAnimation!.forward();
            }
          }
        }

        disable();
        return;
      }
      moveAnimationTowardsState(_unpinnedIndicatorShowing, !d.pinned);
      moveAnimationTowardsState(_unpinnedIndicatorFullyShowing, !d.isRunning);
      onTimerDataChanged(d, previousValue);
      previousValue = d;
    });
  }

  @override
  void dispose() {
    disable();
    _deletionAnimation?.dispose();
    _deletionAnimation = null;
    _appearanceAnimation.dispose();
    _unpinnedIndicatorShowing.dispose();
    _unpinnedIndicatorFullyShowing.dispose();
    animatedToDisabled.dispose();
    _titleFocusNode.dispose();
    _titleController.dispose();
    whetherPinned.dispose();
    _shouldFade.dispose();
    super.dispose();
  }

  void disable() {
    if (hasDisabled) return;
    hasDisabled = true;
  }

  void enterTitleEditMode() {
    final current = p.title ?? '';
    widget.mobj.value = p.withChanges(title: current);
    _titleController.text = current;
    _titleController.selection =
        TextSelection.collapsed(offset: current.length);
    void onFocusChange() {
      if (!_titleFocusNode.hasFocus) {
        _titleFocusNode.removeListener(onFocusChange);
        final text = _titleController.text;
        setState(() => _titleEditMode = false);
        widget.mobj.value = p.withChanges(
          title: text.isEmpty ? null : text,
          titleNull: text.isEmpty,
        );
      }
    }

    _titleFocusNode.addListener(onFocusChange);
    setState(() => _titleEditMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleFocusNode.requestFocus();
    });
  }

  int getIndexWithinParent() {
    final pcs = childrenOf(Mobj.seekTypedsAlreadyLoaded(
        widget.mobj.peek()!.parentId!,
        [TimerDataType(), ListType(StringType())])!);
    return pcs.indexOf(widget.mobj.id);
  }

  Widget buildShell(BuildContext context, Widget content) {
    return nesting(
      [
        (next) => DraggableWidget<GlobalKey<TimerBaseState>>(
            data: widget.key as GlobalKey<TimerBaseState>,
            onDragStarted: () {
              // record current place within parent to later use to determine whether it's an operative drag or whether it's a menu opening longclick
              parentBeforeDrag = widget.mobj.peek()!.parentId;
              indexBeforeDrag = getIndexWithinParent();
            },
            onDragEnd: () {
              if (parentBeforeDrag == widget.mobj.peek()!.parentId &&
                  getIndexWithinParent() == indexBeforeDrag!) {
                // it's a non-operative drag, open the menu
                // delayed because menu needs its new position
                context
                    .findAncestorStateOfType<TimerScreenState>()
                    ?.openTimerMenu(
                        context,
                        widget.key as GlobalKey<TimerBaseState>,
                        widget.mobj.id);
              }
            },
            child: next),
        // (next) => AnimatedTo.spring(
        //     globalKey: animatedToKey,
        //     enabled: !watchSignal(context, animatedToDisabled)!,
        //     // tighter than default. ios sets this to .55
        //     description: const Spring.withDamping(durationSeconds: 0.2),
        //     child: next),
        // (next) => AnimoveFrame(child: next),
        (next) => Animove(
              key: animatedToKey,
              child: next,
            ),
        (next) => AnimatedBuilder(
            animation: _appearanceAnimation,
            child: next,
            builder: (context, child) => FractionalTranslation(
                  translation: Offset(
                      0,
                      0.6 *
                          (1.0 -
                              Curves.easeOut
                                  .transform(_appearanceAnimation.value))),
                  child: FuzzyLinearClip(
                    angle: pi / 2,
                    progress: _appearanceAnimation.value,
                    child: child!,
                  ),
                )),
        (next) {
          if (!_deleted ||
              _deletionAnimation == null ||
              _deletionLayoutRect == null) {
            return next;
          } else {
            return IgnorePointer(
              child: AnimatedBuilder(
                animation: _deletionAnimation!,
                child: next,
                builder: (context, child) {
                  final progress =
                      Curves.easeOut.transform(_deletionAnimation!.value);
                  return Transform.translate(
                    offset: Offset(0, -_deletionLayoutRect!.height * progress),
                    child: FuzzyLinearClip(
                      angle: -pi / 2,
                      progress: 1.0 - progress,
                      fuzzyEdgeWidth: 6,
                      child: child!,
                    ),
                  );
                },
              ),
            );
          }
        },
        (next) => BoolSignalTween(
            signal: _shouldFade,
            duration: Duration(milliseconds: 90),
            child: next,
            builder: (context, progress, child) => Opacity(
                // we delay it on the down swing, I guess because it allows the user to take in whatever caused this, or to perceive in the fact that this automatic scheduling for deletion is a separate event than the cause
                // opacity: lerp(1, 0.54, unlerpUnit(0.65, 1, progress)),
                opacity: lerp(1, 0.4, progress),
                child: child)),
        (next) => GestureDetector(
            onTap: () {
              context
                  .findAncestorStateOfType<TimerScreenState>()
                  ?.takeActionOn(widget.mobj.id);
            },
            behavior: HitTestBehavior.opaque,
            child: next),
      ],
      content,
    );
  }
}

/// Timer widget, contrast with Timer row from the database orm
class Timer extends TimerBase {
  Timer({
    super.key,
    required super.mobj,
    super.animateIn = true,
  }) {
    assert(!mobj.peek()!.isComposite,
        "For composite timers, use a Timercule rather than a Timer");
  }

  @override
  State<Timer> createState() => TimerState();

  static usualHeight() {
    final clockRadius = timerWidgetRadius.peek();
    return 2 * clockRadius + timerGap;
  }
}

class TimerState extends TimerBaseState<Timer> {
  @override
  TimerData get p => widget.mobj.peek()!;

  late Ticker _ticker;
  // in seconds
  double currentTime = 0;
  late final AnimationController _runningAnimation;
  Offset _slideBounceDirection = Offset(0, -1);
  late final AnimationController _slideActivateBounceAnimation;
  late final AnimationController _selectedUnderlineAnimation;
  late final AnimationController _completedRecentlyAnimation;
  final GlobalKey _clockKey = GlobalKey();
  StateError wrongTimerVariantError(TimerKind kind) =>
      StateError("timer kind $kind shouldn't appear in a non-composite timer");

  set selected(bool v) {
    if (p.selected == v) return;
    widget.mobj.value = p.withChanges(selected: v);
  }

  // not sure we use this
  // set duration(double d) {
  //   final digits = durationToDigits(d);
  //   if (currentTime >= d) {
  //     currentTime = d;
  //     isCompleted = true;
  //   } else {
  //     isCompleted = false;
  //   }
  // }

  double get duration {
    return durationToSeconds(digitsToDuration(p.digits));
  }

  set digits(List<int> value) {
    widget.mobj.value = p.withChanges(digits: value);
  }

  // the timerID should never change, we don't respond to widget updates
  // @override
  // void didUpdateWidget(Timer oldWidget) {
  //   super.didUpdateWidget(oldWidget);
  //   if (widget.hue != oldWidget.hue) {
  //     setState(() {
  //       hue = widget.hue;
  //     });
  //   }
  // }

  @override
  void onInitState() {
    _runningAnimation = AnimationController(
        duration: const Duration(milliseconds: 80), vsync: this);
    _slideActivateBounceAnimation = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
    _selectedUnderlineAnimation = AnimationController(
        duration: const Duration(milliseconds: 250), vsync: this);
    _completedRecentlyAnimation = AnimationController(
        duration: const Duration(milliseconds: 510), vsync: this);
    _ticker = createTicker((d) {
      setTime(durationToSeconds(DateTime.now().difference(p.startTime)));
    });
  }

  @override
  dispose() {
    _runningAnimation.dispose();
    _slideActivateBounceAnimation.dispose();
    _selectedUnderlineAnimation.dispose();
    _completedRecentlyAnimation.dispose();
    super.dispose();
  }

  @override
  void disable() {
    if (hasDisabled) return;
    super.disable();
    _ticker.dispose();
  }

  void setTime(double nd) {
    if (currentTime == nd) {
      return;
    }
    setState(() {
      currentTime = nd;
      // we don't set the timer off/change its state, enlivenTimer bindings do that
    });
  }

  @override
  void onTimerDataChanged(TimerData d, TimerData? prev) {
    if ((prev?.isRunning ?? false) != d.isRunning) {
      if (d.isRunning) {
        _completedRecentlyAnimation.value = 0;
        _runningAnimation.forward();
        _ticker.start();
      } else {
        _runningAnimation.reverse();
        _ticker.stop();
      }
    }
    if (prev?.completedRecently != d.completedRecently && d.completedRecently) {
      // acknowledge and begin display
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final d2 = widget.mobj.peek();
        if (d2 != null && d2.completedRecently) {
          widget.mobj.value = d2.withChanges(completedRecently: false);
        }
      });
      _completedRecentlyAnimation.forward(from: 0);
    }
    // if we're just initializing for the first time and it didn't complete recently/has been acknowledged, don't run the acknowledgement animation
    if (prev == null &&
        d.runningState == TimerData.completed &&
        !d.completedRecently) {
      _completedRecentlyAnimation.value = 1;
    }
    moveAnimationTowardsState(_selectedUnderlineAnimation, d.selected);
  }

  @override
  Widget build(BuildContext context) {
    final d = watchSignal(context, widget.mobj) ?? previousValue!;
    final theme = Theme.of(context);
    final mt = MakoThemeData.fromTheme(theme);
    final mover = 0.1;
    final clockRadius = watchSignal(context, timerWidgetRadius);

    // final thumbSpan = Thumbspan.of(context);

    final totalDuration = durationToSeconds(digitsToDuration(d.digits));
    double dt = d.transpired;
    double pieCompletion = dt / totalDuration;
    final durationDigits = d.digits;
    bool timeIsNegative = dt < 0;
    final timeDigits = durationToDigits(dt.abs(),
        isNegative: timeIsNegative,
        padLevel: padLevelFor(durationDigits.length));

    List<int> withDigitsReplacedWith(List<int> v, int d) =>
        List.filled(v.length, d);

    // Selected underline animation
    Widget selectionUnderline = AnimatedBuilder(
      animation: _selectedUnderlineAnimation,
      builder: (context, child) {
        final progress =
            Curves.easeOut.transform(_selectedUnderlineAnimation.value);
        final underlineHeight = 9.0;
        final gap = 3.0;

        return Positioned(
          left: 0,
          right: 0,
          bottom: -underlineHeight - gap,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: progress,
            child: Container(
              height: underlineHeight,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(underlineHeight / 2),
              ),
            ),
          ),
        );
      },
    );

    Widget timeText(List<int> digits,
        {int? centiseconds,
        bool withTimeLevel = false,
        bool isNegative = false}) {
      // adds a second invisible but laid-out copy of the text, underneath the top text, so that if the width of the numerals changes the width of the timer doesn't. We assume that 0 is the widest digit, because it was on mako's machine. If this fails to hold, we can precalculate which is the widest digit.
      Widget fmt(List<int> ds, int? cs, {bool maybeWithTimeLevel = false}) {
        if (maybeWithTimeLevel && withTimeLevel) {
          return boring.formatTimeWithTimeLevel(
            ds,
            padLevel: padLevelFor(ds.length),
            centiseconds: cs,
          );
        }
        final base = boring.formatTime(ds);
        return Text(
            overflow: TextOverflow.clip,
            cs == null ? base : '$base.${cs.toString().padLeft(2, '0')}');
      }

      return Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(
              opacity: 0,
              child: fmt(
                withDigitsReplacedWith(digits, 0),
                centiseconds != null ? 0 : null,
              )),
          fmt(digits, centiseconds, maybeWithTimeLevel: true),
          if (isNegative)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionalTranslation(
                  translation: const Offset(-1, 0),
                  child: Text('-'),
                ),
              ),
            ),
        ],
      );
    }

    var animatedTextPartForTimer = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        AnimatedBuilder(
          animation: _runningAnimation,
          builder: (context, child) {
            final v = Curves.easeInCubic.transform(_runningAnimation.value);
            return FractionalTranslation(
                translation: Offset(0, lerp(-mover, mover, v)),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Transform.scale(
                          alignment: Alignment.bottomLeft,
                          scale: lerp(0.6, 1, v),
                          child:
                              timeText(timeDigits, isNegative: timeIsNegative)),
                      Transform.scale(
                          alignment: Alignment.topLeft,
                          scale: lerp(1, 0.6, v),
                          child: Stack(clipBehavior: Clip.none, children: [
                            timeText(durationDigits, withTimeLevel: true),
                            selectionUnderline,
                          ])),
                    ]));
          },
        ),
      ],
    );

    Widget titledTextPart() {
      final Widget titleWidget = _titleEditMode
          ? IntrinsicWidth(
              child: TextField(
                focusNode: _titleFocusNode,
                controller: _titleController,
                style: DefaultTextStyle.of(context).style,
                decoration: InputDecoration.collapsed(hintText: 'description'),
                onChanged: (text) {
                  widget.mobj.value = p.withChanges(title: text);
                },
              ),
            )
          : Text(d.title!, overflow: TextOverflow.clip);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleWidget,
          switch (d.kind) {
            TimerKind.timer => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  timeText(timeDigits, isNegative: timeIsNegative),
                  Text(' / '),
                  timeText(durationDigits, withTimeLevel: true),
                ],
              ),
            TimerKind.stopwatch => timeText(timeDigits,
                centiseconds: ((dt % 1) * 100).toInt(),
                isNegative: timeIsNegative,
                withTimeLevel: true),
            _ => throw wrongTimerVariantError(d.kind),
          }
        ],
      );
    }

    final Widget textPart = DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: (d.title != null || _titleEditMode)
            ? titledTextPart()
            : switch (d.kind) {
                TimerKind.timer => animatedTextPartForTimer,
                TimerKind.stopwatch => timeText(timeDigits,
                    centiseconds: ((dt % 1) * 100).toInt(),
                    isNegative: timeIsNegative,
                    withTimeLevel: true),
                _ => throw wrongTimerVariantError(d.kind),
              });

    final playIconRadius = 10;
    Offset playIconPos = Offset(clockRadius, clockRadius) +
        Offset.fromDirection(-pi / 4, clockRadius + 8 + playIconRadius);

    final stopwatchPulse = d.transpired % 1;
    final stopwatchPulseProgress = stopwatchPulse *
        (1 -
            Curves.easeOutCubic.transform(unlerpUnit(0.84, 1, stopwatchPulse)));
    final double innerTimerSpan = 2 * (clockRadius - timerOutline);
    final stopwatchPulseSize = lerp(
        innerTimerSpan - timerOutline * 2,
        (clockRadius - timerGap / 2) * 2 * 0.28,
        // Curves.easeOutCubic.transform(stopwatchPulse) *
        stopwatchPulseProgress);

    Decoration containerShape(Color color) => d.kind == TimerKind.stopwatch
        ? ShapeDecoration(
            shape: StarBorder.polygon(
              sides: 8,
              pointRounding: 0.5,
              rotation: 45 / 2,
            ),
            color: color,
          )
        : BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          );

    Widget clockDial = nesting(
        [
          (next) {
            return PinAnimation(
                isPinned: whetherPinned,
                child: Container(
                    width: 2 * clockRadius,
                    height: 2 * clockRadius,
                    padding: EdgeInsets.all(timerOutline),
                    decoration: containerShape(mt.foreBackColor),
                    child: next));
          },
        ],
        switch (d.kind) {
          TimerKind.timer => AnimatedBuilder(
              animation: _completedRecentlyAnimation,
              builder: (context, child) {
                var pie = Pie(
                    innerRadp: (1 -
                            Curves.easeOutCubic.transform(unlerpUnit(0.2, 0.46,
                                    _completedRecentlyAnimation.value)) *
                                ((timerOutline * 2) / innerTimerSpan)) *
                        (1 -
                            unlerpUnit(
                                0.5,
                                1,
                                Curves.easeInCubic.transform(
                                    _completedRecentlyAnimation.value))),
                    backgroundColor: TimerBaseState.backgroundColor(d.hue),
                    color: TimerBaseState.primaryColor(d.hue),
                    value: pieCompletion,
                    size: innerTimerSpan);
                return pie;
              },
            ),
          TimerKind.stopwatch => Container(
              width: innerTimerSpan,
              height: innerTimerSpan,
              decoration: containerShape(
                TimerBaseState.backgroundColor(d.hue),
              ),
              child: Center(
                child: Container(
                  width: stopwatchPulseSize,
                  height: stopwatchPulseSize,
                  decoration: ShapeDecoration(
                    shape: StarBorder.polygon(
                      sides: 8,
                      // it should linger in the full roundness for a moment
                      pointRounding: lerp(
                          0.5, 1, unlerpUnit(0.0, 0.8, stopwatchPulseProgress)),
                      rotation: 45 / 2,
                    ),
                    color: TimerBaseState.primaryColor(d.hue),
                  ),
                ),
              ),
            ),
          _ => throw wrongTimerVariantError(d.kind),
        }
        // size: 90),
        );

    // do a bounce animation to respond to slide to start interactions
    double bounceDistance =
        10 * defaultPulserFunction(_slideActivateBounceAnimation.value);

    return buildShell(
      context,
      Padding(
          padding: EdgeInsets.all(timerGap / 2),
          child: AnimatedBuilder(
            animation: _slideActivateBounceAnimation,
            builder: (context, child) => Transform.translate(
                offset: _slideBounceDirection * bounceDistance, child: child),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                clockDial,
                SizedBox(width: timerGap * 0.4),
                textPart,
              ],
            ),
          )),
    );
  }
}

class Timercule extends TimerBase {
  const Timercule({
    super.key,
    required super.mobj,
    super.animateIn = true,
  });

  @override
  State<Timercule> createState() => TimerculeState();
}

class TimerculeState extends TimerBaseState<Timercule> {
  final GlobalKey iWrapKey = GlobalKey();
  final ValueNotifier<Size?> _handleSizeNotifier = ValueNotifier(null);
  Map<MobjID<TimerData>, TimerBase>? timerWidgetCache;
  final frameKey = GlobalKey();

  @override
  TimerData get p => widget.mobj.peek()!;

  late final Signal<double> depth = Signal(0.0);
  void Function()? _parentDepthDispose;

  void _subscribeToParentDepth() {
    _parentDepthDispose?.call();
    final parent = context.findAncestorStateOfType<TimerculeState>();
    if (parent != null) {
      _parentDepthDispose = effect(() {
        depth.value = parent.depth.value + 1;
      });
    } else {
      depth.value = 0;
      _parentDepthDispose = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToParentDepth();
  }

  @override
  Widget build(BuildContext context) {
    final d = watchSignal(context, widget.mobj) ?? previousValue!;
    final theme = Theme.of(context);
    final double timerHeight = watchSignal(context, timerWidgetRadius) * 2;
    final depth = watchSignal(context, this.depth);
    final mt = MakoThemeData.fromContext(context);
    final backgroundColor = mt.timerculeHighlightBackground(depth);
    final buttonSpan = watchSignal(
        context, Mobj.getAlreadyLoaded(buttonSpanID, DoubleType()))!;
    final cornerRadius = backingCornerRounding * buttonSpan;
    Widget? titleWidget;
    if (d.title != null || _titleEditMode) {
      titleWidget = Padding(
        padding: const EdgeInsets.all(timerGap / 2),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.colorScheme.onSurface),
          child: _titleEditMode
              ? IntrinsicWidth(
                  child: TextField(
                    focusNode: _titleFocusNode,
                    controller: _titleController,
                    style: DefaultTextStyle.of(context).style,
                    decoration:
                        InputDecoration.collapsed(hintText: 'description'),
                    onChanged: (text) {
                      widget.mobj.value = p.withChanges(title: text);
                    },
                  ),
                )
              : Text(d.title!, overflow: TextOverflow.clip),
        ),
      );
    }

    Widget handleContainer({required Widget child}) => Container(
          constraints: BoxConstraints(
              minWidth: timerHeight * 0.7,
              minHeight: timerHeight + timerGap,
              maxWidth: timerHeight * 2),
          child: child,
        );

    Widget handle = handleContainer(
      child: Stack(
        children: [
          Positioned.fill(
              child: Center(
                  child: timerKindIcon(d.kind,
                      color: mt.timerculeHighlightBackground(depth + 1)))),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: titleWidget ?? const SizedBox.shrink()),
        ],
      ),
    );

    Widget tail = Container(
      width: timerHeight * 0.333,
      height: timerHeight * 0.333,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
      ),
    );

    // apparently, sometimes Timers have to build in places where TimerScreenState is no longer in the ancestry (probably from the overlay, during dragging), so we have to retain the map and not assume we'll always be able to make the connection and fetch it.
    timerWidgetCache ??=
        context.findAncestorStateOfType<TimerScreenState>()?.timerWidgetCache;

    final content = buildShell(
        context,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: timerGap / 2),
          child: PinAnimation(
            isPinned: whetherPinned,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: timerGap / 2,
                  bottom: timerGap / 2,
                  child: AnisizedContainer(
                    // todo: shrink background vertically by timerGap/2, if possible. If not possible, maybe build that.
                    decoration: BoxDecoration(
                      // color: TimerBaseState.backgroundColor(d.hue),
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(cornerRadius),
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: timerHeight,
                    minWidth: timerHeight,
                  ),
                  child: AnimoveFrame(
                    key: frameKey,
                    child: IWrap(
                        key: iWrapKey,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.end,
                        children: [
                          SizeFollower(sizeNotifier: _handleSizeNotifier),
                          ...d.children.map<Widget>((id) =>
                              getOrCreateTimerWidget(timerWidgetCache, id,
                                  animateIn: true)),
                          tail
                        ]),
                  ),
                ),
                Positioned(
                    top: 0,
                    left: 0,
                    child: SizeReporter(
                        previousSize: _handleSizeNotifier, child: handle)),
              ],
            ),
          ),
        ));

    return DragTarget<GlobalKey<TimerBaseState>>(
      builder: (context, candidateData, rejectedData) => content,
      onWillAcceptWithDetails: (details) {
        // we have to ensure that this timer isn't any of our ancestors
        bool checkAncestorsRecurse(Mobj<TimerData> ancestor) {
          if (ancestor.id ==
              (details.data.currentWidget! as TimerBase).mobj.id) {
            return false;
          }
          final nextAncestor = Mobj.seekTypedAlreadyLoaded(
              ancestor.peek()!.parentId!, TimerDataType());
          if (nextAncestor == null) {
            return true;
          } else {
            return checkAncestorsRecurse(nextAncestor);
          }
        }

        return checkAncestorsRecurse(widget.mobj);
      },
      onAcceptWithDetails: (details) {
        final iWrapInsertion = insertionOf(iWrapKey, details.offset);
        final timerId = (details.data.currentWidget! as TimerBase).mobj.id;
        final children = widget.mobj.peek()!.children;
        final Mobj<TimerData> cm =
            (details.data.currentWidget! as TimerBase).mobj;
        // Convert IWrap-space insertion index to children-space (subtract 1 for handle)
        final insertAt = (iWrapInsertion.midwayInsertionIndex() - 1)
            .clamp(0, children.length);
        final childIndex = children.indexOf(timerId);
        if (childIndex != -1) {
          // Already a child - reorder
          final (operative, atIWrap) = iWrapInsertion.cleverInsertionIndexFor(
              childIndex + 1, children.length + 2);
          if (operative) {
            final at = (atIWrap - 1).clamp(0, children.length);
            widget.mobj.value = widget.mobj.peek()!.withChanges(
                children: children.toList()
                  ..insert(at, timerId)
                  ..removeAt(childIndex > at ? childIndex + 1 : childIndex));
          }
        } else {
          if (cm.peek()!.parentId != null) {
            final oldList = Mobj.seekTypedsAlreadyLoaded(cm.peek()!.parentId!,
                [TimerDataType(), ListType(StringType())])!;
            final oldChildren = childrenOf(oldList);
            writeBackChildren(oldList,
                oldChildren.toList()..removeAt(oldChildren.indexOf(timerId)));
          }
          widget.mobj.value = widget.mobj.peek()!.withChanges(
              children: children.toList()..insert(insertAt, timerId));
          // why selected false? because if a user drags a timer onto a composite timer, it indicates that they're done editing it
          cm.value =
              cm.peek()!.withChanges(parentId: widget.mobj.id, selected: false);
        }
      },
    );
  }

  @override
  void dispose() {
    _parentDepthDispose?.call();
    _handleSizeNotifier.dispose();
    super.dispose();
  }
}

class FadingDial extends AnimatedWidget {
  final double angle;
  final double radius;
  final Color topColor;
  final Color bottomColor;
  final double holeRadius;
  const FadingDial({
    super.key,
    required super.listenable,
    required this.angle,
    required this.radius,
    required this.topColor,
    required this.bottomColor,
    this.holeRadius = 0,
  });

  Animation<double> get visibility => listenable as Animation<double>;
  @override
  Widget build(BuildContext context) {
    final vv = visibility.value;
    return FractionalTranslation(
        translation: Offset(-0.5, -0.5),
        child: Transform.rotate(
            angle: angle,
            child: Opacity(
                opacity: vv,
                child: AnimatedScale(
                    scale: lerp(0.9, 1.0, vv),
                    duration: Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    child: CustomPaint(
                      size: Size.square(radius * 2),
                      painter: SweepGradientCirclePainter(topColor, bottomColor,
                          holeRadius: holeRadius),
                    )))));
  }
}

final timerListType = ListType(StringType());

/// A widget that displays a sequence of timers with drag and drop functionality.
/// Can optionally be displayed within a scrollview.
class TimerTray extends StatefulWidget {
  /// The Mobj that stores the timer data list. Replacing this with a MobjID wouldn't be a big deal
  final Mobj<List<MobjID<TimerData>>> mobj;

  /// Background color for the sequence container
  final Color backgroundColor;

  final Computed<TimerWidgets> timerWidgets;

  /// Icon widget that displays above the sequence
  final Widget? icon;

  /// Whether this sequence should render within a scrollview
  final bool useScrollView;

  /// Callback for when a timer is dropped into this sequence
  final Function(MobjID<TimerData> timerId)? onTimerDropped;

  const TimerTray({
    super.key,
    required this.mobj,
    required this.backgroundColor,
    required this.timerWidgets,
    this.icon,
    this.useScrollView = true,
    this.onTimerDropped,
  });

  @override
  State<TimerTray> createState() => TimerTrayState();
}

typedef TimerWidgets = Map<MobjID<TimerData>, TimerBase>;

class TimerTrayState extends State<TimerTray> with SignalsMixin {
  late final GlobalKey wrapKey;

  @override
  void initState() {
    super.initState();
    wrapKey = GlobalKey();
  }

  List<MobjID<TimerData>> get p => widget.mobj.peek()!;

  @override
  Widget build(BuildContext context) {
    final result = Watch((context) {
      final isRightHanded =
          Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).value!;
      return Align(
          alignment: isRightHanded
              ? FractionalOffset(0.8, 1)
              : FractionalOffset(0.2, 1),
          child: IWrap(
            key: wrapKey,
            textDirection:
                isRightHanded ? TextDirection.ltr : TextDirection.rtl,
            // TextDirection.rtl,
            clipBehavior: Clip.none,
            verticalDirection: VerticalDirection.down,
            alignment: WrapAlignment.end,
            crossAxisAlignment:
                // isRightHanded ? WrapCrossAlignment.end : WrapCrossAlignment.start,
                WrapCrossAlignment.start,
            children: widget.mobj.value!
                .map((ki) => widget.timerWidgets.value[ki]!)
                .toList(),
          ));
    });

    return result;
  }
}

class TimerScreen extends StatefulWidget {
  const TimerScreen({super.key});

  @override
  State<TimerScreen> createState() => TimerScreenState();
}

/// a circle of colors sampled from a uniform circle in the hsluv space at lightness 70
/// for some reason like none of the hsluv apis provide polar coordinates, so you can't get perceptually uniform saturation. I refuse to implement polar coordinates, so I just copied some points at constant saturation from the hsluv site.
const List<HSLuvColor> colorCircle = [
  HSLuvColor.fromHSL(0, 67, 70),
  HSLuvColor.fromHSL(26.7, 54, 70),
  HSLuvColor.fromHSL(48.1, 58, 70),
  HSLuvColor.fromHSL(81, 72, 70),
  HSLuvColor.fromHSL(111, 63, 70),
  HSLuvColor.fromHSL(134, 60, 70),
  HSLuvColor.fromHSL(158, 88, 70),
  HSLuvColor.fromHSL(180, 100, 70),
  HSLuvColor.fromHSL(205, 94, 70),
  HSLuvColor.fromHSL(234, 67, 70),
  HSLuvColor.fromHSL(262, 69, 70),
  HSLuvColor.fromHSL(294, 61, 70),
  HSLuvColor.fromHSL(326, 63, 70),
  HSLuvColor.fromHSL(346, 68, 70),
];

/// hue is in degrees
/// we might not need this, hpluv is pretty good.
HSLuvColor interpolateHuePoints(double hue, List<HSLuvColor> colorCircle) {
  assert(hue >= 0 && hue <= 360);
  hue = hue % 360;
  // then move iHint so that it's lower than or equal tohue
  int iHint = (hue / 360 * colorCircle.length).floor();
  while (colorCircle[iHint].hue > hue) {
    if (iHint == 0) {
      break;
    }
    iHint -= 1;
  }
  // but that it's the highest allowable hue
  while (iHint < colorCircle.length - 1 && colorCircle[iHint + 1].hue <= hue) {
    iHint += 1;
  }
  // now interpolate between the two colors
  final lower = colorCircle[iHint];
  final upper = colorCircle[(iHint + 1) % colorCircle.length];
  final hueDiff = iHint < colorCircle.length - 1
      ? upper.hue - lower.hue
      : 360 - lower.hue + upper.hue;
  final t = (hue - lower.hue) / hueDiff;
  return HSLuvColor.fromHSL(
      lerp(lower.hue, upper.hue, t),
      lerp(lower.saturation, upper.saturation, t),
      lerp(lower.lightness, upper.lightness, t));
}

final List<double> numericRadialActivatorPositions = [
  -pi / 2,
  -pi,
];
void pausePlaySelected(TimerScreenState tss) {
  tss.pausePlaySelected();
}

final List<Function(TimerScreenState)> numericRadialActivatorFunctions = [
  (tss) {
    final dagc = Mobj.getAlreadyLoaded(usedDragActionRecordID, IntType());
    dagc.value = dagc.peek()! | 1;
    pausePlaySelected(tss);
  },
  (tss) {
    final dagc = Mobj.getAlreadyLoaded(usedDragActionRecordID, IntType());
    dagc.value = dagc.peek()! | 2;
    tss.numeralPressed([0, 0]);
    pausePlaySelected(tss);
  },
];

class DragActionRing extends StatefulWidget {
  final Offset position;
  final Signal<int?> dragEvents;

  /// used to close the ring if another one opens
  final Listenable? suppressionBus;
  final List<Widget> radialActivatorIcons;
  final List<Widget>? radialActivatorLabels;
  final List<double> radialActivatorPositions;

  /// position represents the touch origin, visualPosition is where the visual should be centered. The reason we distinguish these things is it looks wrong or imprecise if the visual origin doesn't come from the UI element it's associated with, while the touch origin also absolutely needs to be correct or else you're injecting random error to the user choice.
  final Offset visualPosition;
  final bool? shuntRight;

  const DragActionRing(
      {super.key,
      required this.position,
      required this.dragEvents,
      this.suppressionBus,
      required this.visualPosition,
      this.shuntRight,
      required this.radialActivatorIcons,
      this.radialActivatorLabels,
      required this.radialActivatorPositions});

  @override
  State<DragActionRing> createState() => DragActionRingState();
}

class DragActionRingState extends State<DragActionRing>
    with TickerProviderStateMixin, SignalsMixin {
  double actionSizepAtSelection = 0;
  int numberSelected = -1;
  // mirrors numberSelected, but not always
  int centeredNumber = -1;
  late final List<AnimationController> labelAnimations;
  late final UpDownAnimationController upDownAnimation =
      UpDownAnimationController(
    vsync: this,
    riseDuration: Duration(milliseconds: 300),
    fallDuration: Duration(milliseconds: 140),
  );
  late final AnimationController optionActivationAnimation =
      AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 200),
  );
  late final AnimationController optionConsiderationAnimation =
      AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 200),
  );
  Function()? dragEventsSubscription;

  void _onOtherRingOpens() {
    upDownAnimation.reverse();
  }

  @override
  void initState() {
    super.initState();
    labelAnimations = List.generate(
      widget.radialActivatorPositions.length,
      (_) => AnimationController(
          vsync: this, duration: Duration(milliseconds: 540)),
    );
    widget.suppressionBus?.addListener(_onOtherRingOpens);
    upDownAnimation.forward();
    optionActivationAnimation.addStatusListener((status) {
      if (!mounted) {
        return;
      }
      if (status == AnimationStatus.completed) {
        context.findAncestorStateOfType<SelfRemovalHostState>()?.remove(widget);
      }
    });
    upDownAnimation.addStatusListener((status) {
      // wait for option activation if it's going
      if (!optionActivationAnimation.isAnimating &&
          status == AnimationStatus.dismissed) {
        if (!mounted) {
          return;
        }
        context.findAncestorStateOfType<SelfRemovalHostState>()?.remove(widget);
      }
    });
    dragEventsSubscription = widget.dragEvents.subscribe((v) {
      if (v == null) {
        if (numberSelected != -1) {
          optionActivationAnimation.forward();
        } else {
          upDownAnimation.reverse();
        }
        dragEventsSubscription?.call();
      } else if (v != -1) {
        if (v != numberSelected) {
          HapticFeedback.heavyImpact();
          if (numberSelected != -1) labelAnimations[numberSelected].reverse();
          labelAnimations[v].forward();
        }
        setState(() {
          numberSelected = v;
          centeredNumber = v;
          actionSizepAtSelection = currentActionSize();
          optionConsiderationAnimation.forward();
        });
      } else {
        if (numberSelected != -1) labelAnimations[numberSelected].reverse();
        setState(() {
          numberSelected = -1;
          optionConsiderationAnimation.reverse();
          upDownAnimation.forward();
        });
      }
    });
  }

  @override
  void dispose() {
    for (final c in labelAnimations) c.dispose();
    optionActivationAnimation.dispose();
    optionConsiderationAnimation.dispose();
    upDownAnimation.dispose();
    dragEventsSubscription?.call();
    widget.suppressionBus?.removeListener(_onOtherRingOpens);
    super.dispose();
  }

  double currentActionSize() {
    // disables fade down if action selected
    return Curves.easeIn.transform(unlerpUnit(
        0.4,
        0.65,
        upDownAnimation.value.$1 *
            (1 - (numberSelected != -1 ? 0 : upDownAnimation.value.$2))));
  }

  Widget buildWithGivenAnimationParameters(
      double risep, double fallp, double swipep, double releasep) {
    final theme = Theme.of(context);
    final mt = MakoThemeData.fromTheme(theme);
    final thumbSpan = Thumbspan.of(context);
    final isRightHanded = watchSignal(
        context, Mobj.getAlreadyLoaded(isRightHandedID, BoolType()))!;

    final radialRadiusMax = thumbSpan * (0.5 + 0.17);
    // disable fade down if a number is selected
    final double fallpIfNotSelected = numberSelected != -1 ? 0 : fallp;
    final radius = radialRadiusMax *
        Curves.easeOut
            .transform(unlerpUnit(0, 0.6, risep * (1 - fallpIfNotSelected)));
    final Widget radialActivationRing = Positioned(
      left: 0,
      top: 0,
      child: FractionalTranslation(
        translation: Offset(-0.5, -0.5),
        child: Container(
          constraints: BoxConstraints.tight(Size(radius * 2, radius * 2)),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );

    final actionRadiusMax = thumbSpan * 0.6;
    Widget dragChoiceWidget(Widget child) {
      return Container(
        constraints:
            BoxConstraints.tight(Size(actionRadiusMax, actionRadiusMax)),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
        padding: EdgeInsets.all(8),
        child: Opacity(
          opacity: unlerpUnit(0.6, 1, risep),
          child: IconTheme(
            data: IconThemeData(
              color: theme.colorScheme.onPrimary,
            ),
            child: DefaultTextStyle(
              style: controlPadTextStyle
                  .merge(TextStyle(color: theme.colorScheme.onPrimary)),
              child: FittedBox(fit: BoxFit.scaleDown, child: child),
            ),
          ),
        ),
      );
    }

    final List<Widget> radialActivatorWidgets = widget.radialActivatorIcons
        .map((icon) => dragChoiceWidget(icon))
        .toList();

    Offset positionFor(int actionIndex, {double? overrideRisep}) {
      final angle = conditionallyApplyIf<double>(!isRightHanded,
          flipAngleHorizontally, widget.radialActivatorPositions[actionIndex]);
      return Offset.fromDirection(
          angle,
          lerp(
              radius - actionRadiusMax,
              radius,
              Curves.easeInOut.transform(unlerpUnit(0.6, 1,
                  (overrideRisep ?? risep) * (1 - fallpIfNotSelected)))));
    }

    final List<Widget> unselectedNumeralDragRadialActivators =
        List.generate(widget.radialActivatorPositions.length, (i) {
      Offset o = positionFor(i);
      return Positioned(
        left: o.dx,
        top: o.dy,
        child: FractionalTranslation(
            translation: Offset(-0.5, -0.5),
            child: Transform.scale(
                scale: currentActionSize(), child: radialActivatorWidgets[i])),
      );
    });

    Widget? selectedNumeralDragRadialActivator;
    if (centeredNumber != -1) {
      selectedNumeralDragRadialActivator =
          unselectedNumeralDragRadialActivators.removeAt(centeredNumber);
    }

    double totalSpan = 2 * radialRadiusMax + 2 * actionRadiusMax;

    final revealFraction = 1 - Curves.easeOut.transform(swipep);
    final revealCenter = centeredNumber != -1
        ? positionFor(centeredNumber, overrideRisep: 1)
        : Offset.zero;
    final revealMaxRadius = totalSpan;

    Widget radialRevealShaderMask({
      required double fraction,
      required double maxRadius,
      required List<Widget> stackChildren,
    }) {
      return ShaderMask(
        shaderCallback: (bounds) => createRadialRevealShader(
          bounds: bounds,
          center: Alignment(
            revealCenter.dx / (bounds.size.width / 2),
            revealCenter.dy / (bounds.size.height / 2),
          ),
          fraction: fraction,
          fuzzyEdgeWidth: 20.0,
          maxRadius: maxRadius,
        ),
        child: SizedBox(
          width: totalSpan,
          height: totalSpan,
          child: Transform.translate(
            offset: Offset(totalSpan / 2, totalSpan / 2),
            child: Stack(
              clipBehavior: Clip.none,
              children: stackChildren,
            ),
          ),
        ),
      );
    }

    Widget labelWidgetAt(int index, double progress) {
      final angle = conditionallyApplyIf<double>(!isRightHanded,
          flipAngleHorizontally, widget.radialActivatorPositions[index]);
      final labelPos =
          Offset.fromDirection(angle, radius + actionRadiusMax * 0.8);
      // alignment parameters are projected to the manhattan unit square

      var rawTx = cos(angle);
      final rawTy = sin(angle);
      if (widget.shuntRight != null) {
        if (rawTx.abs() < 0.07) {
          rawTx = widget.shuntRight! ? 1 : -1;
        } else {
          rawTx = rawTx.sign;
        }
      }
      final m = max(rawTx.abs(), rawTy.abs());
      final double fontSize = 38;
      return nesting(
        [
          (w) => Positioned(left: labelPos.dx, top: labelPos.dy, child: w),
          (w) => FractionalTranslation(
              translation: (Offset(rawTx / m, rawTy / m) - Offset(1, 1)) / 2,
              child: w),
          (w) => FuzzyCircleClip(
              origin: RelAlignment(
                originAlignX: -labelPos.dx,
                originAlignY: -labelPos.dy,
              ),
              progress: progress,
              fuzzyEdgeWidth: 20.0,
              child: w),
          (w) => Transform.translate(
              offset: angleToOffset(angle) *
                  (actionRadiusMax * 0.2) *
                  easeIn(1 - progress),
              child: w),
          // tombstone: it seems as if you can't nest these inside the FuzzyCircleClip, they get their boundaries clipped and messed up. I really don't understand why!
          // (w) => ShadowWidget(
          //       color: mt.lowestBackColor.withValues(alpha: 1),
          //       offset: Offset.zero,
          //       blurRadius: 4,
          //       child: w,
          //     ),
          // (child) => DecoratedBox(
          //     decoration: BoxDecoration(
          //       borderRadius: BorderRadius.circular(fontSize * 0.5),
          //       boxShadow: [
          //         BoxShadow(
          //           color: mt.lowestBackColor.withValues(alpha: 0.8),
          //           offset: Offset.zero,
          //           blurRadius: 5,
          //           spreadRadius: 2,
          //         ),
          //       ],
          //     ),
          //     child: child),
          (w) => DefaultTextStyle(
              style: controlPadTextStyle.copyWith(
                color: theme.colorScheme.primary,
                fontSize: fontSize,
                shadows: [
                  Shadow(
                    color: mt.lowestBackColor.withValues(alpha: 0.8),
                    offset: Offset.zero,
                    blurRadius: 5,
                  ),
                ],
              ),
              child: w)
        ],
        SignedPadding(
            insets: EdgeInsets.symmetric(vertical: -fontSize * 0.57),
            child: widget.radialActivatorLabels![index]),
      );
    }

    return IgnorePointer(
        child: FractionalTranslation(
            translation: Offset(-0.5, -0.5),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // disappearing on swipe
                radialRevealShaderMask(
                  fraction: revealFraction,
                  maxRadius: revealMaxRadius,
                  stackChildren: [
                    radialActivationRing,
                    ...unselectedNumeralDragRadialActivators,
                  ],
                ),
                // disappearing on release
                radialRevealShaderMask(
                  fraction: 1 - Curves.easeOut.transform(releasep),
                  maxRadius: revealMaxRadius * 0.8,
                  stackChildren: [
                    if (selectedNumeralDragRadialActivator != null)
                      selectedNumeralDragRadialActivator,
                  ],
                ),
                if (widget.radialActivatorLabels != null)
                  SizedBox(
                    width: totalSpan,
                    height: totalSpan,
                    child: Transform.translate(
                      offset: Offset(totalSpan / 2, totalSpan / 2),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (int i = 0; i < labelAnimations.length; i++)
                            if (labelAnimations[i].value > 0)
                              labelWidgetAt(
                                  i,
                                  unlerpUnit(
                                      0.66, 1, labelAnimations[i].value)),
                        ],
                      ),
                    ),
                  ),
              ],
            )));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
        left: widget.visualPosition.dx,
        top: widget.visualPosition.dy,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            upDownAnimation,
            optionConsiderationAnimation,
            optionActivationAnimation,
            ...labelAnimations,
          ]),
          builder: (context, child) {
            return buildWithGivenAnimationParameters(
                upDownAnimation.value.$1,
                upDownAnimation.value.$2,
                optionConsiderationAnimation.value,
                optionActivationAnimation.value);
          },
        ));
  }
}

TimerBase getOrCreateTimerWidget(
    Map<MobjID<TimerData>, TimerBase>? timerWidgetCache, MobjID<TimerData> id,
    {bool animateIn = false}) {
  if (timerWidgetCache != null && timerWidgetCache.containsKey(id)) {
    return timerWidgetCache[id]!;
  }
  final mobj = Mobj.getAlreadyLoaded(id, TimerDataType());
  final widget = mobj.peek()!.isComposite
      ? Timercule(
          key: GlobalKey<TimerculeState>(), mobj: mobj, animateIn: animateIn)
      : Timer(key: GlobalKey<TimerState>(), mobj: mobj, animateIn: animateIn);
  if (timerWidgetCache != null) {
    timerWidgetCache[id] = widget;
  }
  return widget;
}

class TimerScreenState extends State<TimerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  late final Signal<MobjID?> selectedTimer = Signal(null);
  late final EffectCleanup watchingForUnselection;
  late final Computed<TimerWidgets> timerWidgets;
  final Map<MobjID<TimerData>, TimerBase> timerWidgetCache = {};

  TimerBase timerScreenGetOrCreateTimerWidget(MobjID<TimerData> id,
      {bool animateIn = false}) {
    return getOrCreateTimerWidget(timerWidgetCache, id, animateIn: animateIn);
  }

  late final Mobj<bool> isRightHandedMobj =
      Mobj.getAlreadyLoaded(isRightHandedID, BoolType());
  late final Signal<Rect> numPadBounds = Signal(Rect.zero);
  late final JukeBox jukeBox = JukeBox.create();
  late final TimerHolm timerHolm;
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => timerListMobj.value!;
  List<MobjID<TimerData>> peekTimers() => timerListMobj.peek()!;

  GlobalKey<TimerTrayState> timerTrayKey = GlobalKey<TimerTrayState>();
  GlobalKey pinButtonKey = GlobalKey();
  GlobalKey deleteButtonKey = GlobalKey();
  GlobalKey<SelfRemovalHostState> ephemeralAnimationLayer = GlobalKey();
  final Mobj<List<MobjID<TimerData>>> timerListMobj =
      Mobj.getAlreadyLoaded(timerListID, timerListType);
  // final Mobj<List<MobjID<TimerData>>> transientTimerListMobj =
  //     Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
  late final Mobj<double> nextHueMobj =
      Mobj.getAlreadyLoaded(nextHueID, DoubleType());
  late final Mobj<bool> buttonScaleDialOn =
      Mobj.getAlreadyLoaded(buttonScaleDialOnID, BoolType());
  late final Mobj<double> buttonSpanMobj =
      Mobj.getAlreadyLoaded(buttonSpanID, DoubleType());
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());
  final GlobalKey modeHighlightAnimoveKey = GlobalKey();
  final Signal<Offset> modeHighlightAnchor = Signal(Offset.zero);
  late AnimationController modeLivenessAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));
  // emits whenever a drag action ring is created, so that older ones can disable themselves
  late final ChangeNotifier onNewNumeralDragActionRing = ChangeNotifier();
  late final Computed<bool> userDragActionHintCondition = Computed(() {
    final dagc = Mobj.getAlreadyLoaded(usedDragActionRecordID, IntType());
    return (dagc.value! & 3) != 3;
  }, autoDispose: true);
  late final Computed<bool> hasUsedMenuTwice = Computed(() {
    final dagc = Mobj.getAlreadyLoaded(usedMenuCountID, IntType());
    return dagc.value! < 2;
  }, autoDispose: true);
  late final Computed<bool> hintGetsCompositeTimersCondition = Computed(
      () =>
          // also goes away if the user just uses timers and ignores the timercule feature
          (Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType()).value! <
              10) &&
          // user has been using the app for less than 7 days. This is an imperfect condition and we should probably track the number of timers they've created instead.
          // (DateTime.now()
          //         .difference(
          //             Mobj.getAlreadyLoaded(timeFirstUsedApp, DateTimeType())
          //                 .value!)
          //         .inDays <
          //     7) &&
          !(Mobj.getAlreadyLoaded(hintGetsCompositeTimersID, BoolType())
                  .value ??
              false),
      autoDispose: true);
  late final AnimationController buttonScaleDialAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));
  late final AnimationController buttonScaleFlashAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 1600));
  late final Signal<Offset?> buttonScaleDialCenter = Signal(Offset.zero);
  final GlobalKey selectButtonKey = GlobalKey();
  late final Signal<double> buttonScaleDialAngle = Signal(0.0);
  async.Timer? buttonScaleDialLeavingTimer;
  final Map<MobjID, Function()> _timerDeletionSubs = {};
  late final Signal<int> currentlyPressingKey = Signal(0);
  Rect editPopoverControls = Rect.zero;
  late final UpDownAnimationController editPopoverAnimation =
      UpDownAnimationController(
          vsync: this,
          riseDuration: Duration(milliseconds: 400),
          fallDuration: Duration(milliseconds: 200));
  late final ScrollController timersScroller = ScrollController();
  late final AnimationController squishPanelController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 16000));
  late final Signal<bool> isFirstPressForSelectedTimer = Signal(true);

  /// which mode is currently selected. Can be 'pin', 'delete', or 'play', any other value will be treated as 'play'
  /// we should probably persist this... but it doesn't matter much.
  late Signal<String> actionMode = Signal('play');
  double decAngleFor(int i) {
    // position for when there were only 4
    // // with an epsilon on the first one to make sure the label goes to the left
    // final lumpNudge = pi / 3 * 0.24;
    // final lumpBase = -(pi / 2 + pi / 3 + lumpNudge);
    // final lumpEnd = -pi / 2 - pi;
    // double splay(int i) => lumpBase + (i - 1) * (lumpEnd - lumpBase) / 2;
    // switch (i) {
    //   case 0:
    //     return -pi / 2 - 0.001;
    //   case 1:
    //     return splay(1);
    //   case 2:
    //     return splay(2);
    //   case 3:
    //     return splay(3);
    //   default:
    //     throw Exception('Invalid index $i');
    // }
    final base = -pi / 2;
    final s = pi / 4;
    return base - s * i;
  }

  static const Size dragActionRingIconSize = Size.square(26);
  late final specialTimerCreateDragRingController = DragActionRingController(
    shuntRight: false,
    radialActivatorFunctions: [
      addNewStopwatch,
      () => addNewCompositeTimer(TimerKind.loop),
      () => addNewCompositeTimer(TimerKind.series),
      () => addNewCompositeTimer(TimerKind.parallelStartJustified),
      () => addNewCompositeTimer(TimerKind.parallelEndJustified),
    ],
    radialActivatorPositions: List.generate(5, decAngleFor),
    radialActivatorIcons: [
      Icon(Icons.square_rounded),
      Builder(
          builder: (context) => CustomPaint(
              size: dragActionRingIconSize,
              painter: TimerculeCyclePainter(
                  color: Theme.of(context).colorScheme.onPrimary))),
      Builder(
          builder: (context) => CustomPaint(
              size: dragActionRingIconSize,
              painter: TimerculeSerialPainter(
                  color: Theme.of(context).colorScheme.onPrimary))),
      Builder(
          builder: (context) => CustomPaint(
              size: dragActionRingIconSize,
              painter: TimerculeParallelPainter(
                  color: Theme.of(context).colorScheme.onPrimary,
                  rightJustified: false))),
      Builder(
          builder: (context) => CustomPaint(
              size: dragActionRingIconSize,
              painter: TimerculeParallelPainter(
                  color: Theme.of(context).colorScheme.onPrimary,
                  rightJustified: true))),
    ],
    radialActivatorLabels: const [
      Text('stopwatch'),
      Text('cycle'),
      Text('series'),
      Text('simultaneous (start)'),
      Text('simultaneous (end)'),
    ],
  );
  late final StreamController<void> modeActivationPulse =
      StreamController<void>.broadcast();

  @override
  void initState() {
    super.initState();

    timerHolm =
        globalTimerHolm = TimerHolm(list: timerListMobj, jukeBox: jukeBox);

    FlutterForegroundTask.addTaskDataCallback(onDataReceived);
    // my impression so far is that apple forbid you from running stuff in the background on iOS (unless you're an application for which it would create bad PR for them to kill you), so you can't really make the best timer apps there. On iOS, we're going to have to approach this in a very hacky way.
    // android will support repeat timers via the foreground service
    // assuming that all permissions are granted by now.
    // this is async, but we don't have to wait for it since all interaction with it is async and buffered
    graspForegroundService();

    // make sure the mode indicator follows the current mode
    createEffect(() {
      void moveTo(GlobalKey target) {
        modeHighlightAnchor.value = boxRect(target)!.center;
        modeLivenessAnimation.forward();
      }

      if (actionMode.value == 'pin') {
        moveTo(pinButtonKey);
      } else if (actionMode.value == 'delete') {
        moveTo(deleteButtonKey);
      } else {
        modeLivenessAnimation.reverse();
      }
    });
    // resetting the button scale dial
    createEffect(() {
      if (buttonScaleDialOn.value!) {
        buttonScaleDialAnimation.forward();
        buttonScaleDialCenter.value = null;
        buttonScaleDialAngle.value = 0.0;
        buttonScaleFlashAnimation.forward(from: 0);
      } else {
        buttonScaleDialAnimation.reverse();
      }
    });
    timerWidgets = Computed(() {
      TimerWidgets next = {};
      for (final t in timerListMobj.value!) {
        next[t] = timerScreenGetOrCreateTimerWidget(t, animateIn: true);
      }
      return next;
    });
    // watching the selected timer
    createEffect(() {
      final sv = selectedTimer.value;
      // clear selectedTimer if the selected timer is no longer selected
      if (sv != null) {
        final svm = Mobj.getAlreadyLoaded(sv, TimerDataType()).value;
        if (svm == null || svm.selected == false) {
          selectedTimer.value = null;
        }
      }
      // control editPopoverAnimation
      // edit popover doesn't pop up until there's a selected timer and the user has released the key at least once (you could simplify this logic a lot by directly tracking key release instead of this cocamamie bullshit)
      // this is null excepting, understandably, you can't peek it, it was just deleted
      final timerData =
          sv != null ? Mobj.getAlreadyLoaded(sv, TimerDataType()).peek() : null;
      editPopoverAnimation.towards(timerData != null &&
          timerData.kind == TimerKind.timer &&
          (!isFirstPressForSelectedTimer.value ||
              currentlyPressingKey.value == 0));
    });
  }

  @override
  void dispose() {
    squishPanelController.dispose();
    timersScroller.dispose();
    selectedTimer.dispose();
    timerWidgets.dispose();
    buttonScaleDialCenter.dispose();
    buttonScaleDialAngle.dispose();
    actionMode.dispose();
    onNewNumeralDragActionRing.dispose();
    numPadBounds.dispose();
    selectedTimer.dispose();
    actionMode.dispose();
    isFirstPressForSelectedTimer.dispose();
    currentlyPressingKey.dispose();
    modeLivenessAnimation.dispose();
    modeActivationPulse.close();
    for (final unsub in _timerDeletionSubs.values) {
      unsub();
    }
    timerHolm._backgroundedReaction();
    timerHolm._newTimerReaction.cancel();
    super.dispose();
  }

  void openTimerMenu(
    BuildContext context,
    GlobalKey<TimerBaseState> timerKey,
    MobjID<TimerData> timerID,
  ) {
    // final tm = Mobj.getAlreadyLoaded(timerID, TimerDataType());
    // final tmParent = Mobj.seekTypedsAlreadyLoaded(tm.peek()!.parentId!, [TimerDataType(), ListType(StringType())])!;
    // final indexInParent = childrenOf(tmParent).indexOf(timerID);

    final menuCountMobj = Mobj.getAlreadyLoaded(usedMenuCountID, IntType());
    if ((menuCountMobj.peek() ?? 0) < 2) {
      menuCountMobj.value = (menuCountMobj.peek() ?? 0) + 1;
    }
    Rect p = boxRect(timerKey)!;
    final arrowHeight = TimerMenu.buttonHeight * 0.36;
    final theme = Theme.of(context);
    final mt = MakoThemeData.fromTheme(theme);
    final backgroundColor = theme.brightness == Brightness.light
        ? theme.colorScheme.primary
        : lightenColor(mt.foreBackColor, 0.1);
    final foregroundColor = theme.brightness == Brightness.light
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final indentColor = theme.brightness == Brightness.light
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.07)
        : darkenColor(backgroundColor, 0.1);
    const double menuItemPadding = 8;
    TimerData td = Mobj.getAlreadyLoaded(timerID, TimerDataType()).peek()!;
    Color inkColor = td.isComposite
        ? foregroundColor
        : TimerBaseState.backgroundColor(td.hue);
    Widget menuItem(BuildContext context, bool isRightHanded, Widget icon,
        String label, Function() action,
        {bool isFirst = false, bool isLast = false}) {
      return InkButton(
          backgroundColor: backgroundColor,
          inkColor: inkColor.withValues(alpha: 0.6),
          inkColorFaded: inkColor.withValues(alpha: 0.3),
          onTap: () {
            action();
            Navigator.of(context).pop();
          },
          child: Padding(
              padding: EdgeInsets.only(
                  top: isFirst ? (menuItemPadding + arrowHeight) : 0,
                  bottom: isLast ? menuItemPadding : 0,
                  left: menuItemPadding,
                  right: menuItemPadding),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: isRightHanded
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.end,
                children: reverseIfNot(isRightHanded, [
                  SizedBox(
                      width: TimerMenu.buttonHeight,
                      height: TimerMenu.buttonHeight,
                      child: Center(child: icon)),
                  Expanded(
                      child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium!
                          .copyWith(color: foregroundColor),
                    ),
                  )),
                  SizedBox(width: TimerMenu.buttonHeight * 0.2),
                ]),
              )));
    }

    double totalVisibleMenuItemHeight =
        TimerMenu.buttonHeight * 4 + 14 + menuItemPadding * 2;

    showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Timer menu',
        barrierColor: mt.lowestBackColor.withAlpha(0),
        transitionDuration: Duration(milliseconds: 370),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            child,
        pageBuilder: (context, animation, secondaryAnimation) {
          return Watch(
            (context) {
              bool isRightHanded = watchSignal(context, isRightHandedMobj)!;
              return TimerMenu(
                  timerID: timerID,
                  arrowHeight: arrowHeight,
                  centerOn: p,
                  // we're making it square :3 it was initially as wide as the screen, but it occurred to me that all of the crispest menus aren't, and then I thought about whether it really needed to be wide, and the answer is no, because to open a menu your thumb has to already be over there above it
                  estimatedWidth: totalVisibleMenuItemHeight,
                  backgroundColor: backgroundColor,
                  animation: animation,
                  items: [
                    menuItem(
                        context,
                        isRightHanded,
                        Icon(Icons.delete, color: foregroundColor),
                        'Delete', () {
                      deleteTimer(timerID);
                    }, isFirst: true),
                    SeparatorGradient(color: indentColor),
                    menuItem(
                        context,
                        isRightHanded,
                        Transform.rotate(
                            angle: -pi / 2,
                            child: Icon(Icons.rotate_90_degrees_cw_rounded,
                                color: foregroundColor)),
                        'Reset', () {
                      resetTimer(timerID);
                    }),
                    menuItem(
                        context,
                        isRightHanded,
                        Icon(Icons.push_pin, color: foregroundColor),
                        'Pin', () {
                      togglePin(timerID);
                    }),
                    menuItem(
                        context,
                        isRightHanded,
                        Icon(Icons.label_outline, color: foregroundColor),
                        'Title', () {
                      final wk = timerWidgets[timerID]?.key
                          as GlobalKey<TimerBaseState>?;
                      wk?.currentState?.enterTitleEditMode();
                    }, isLast: true),
                  ]);
            },
          );
        });
  }

  void takeActionOn(MobjID<TimerData> timerID) {
    String mode = actionMode.peek();
    if (mode == 'pin') {
      togglePin(timerID);
    } else if (mode == 'delete') {
      deleteTimer(timerID);
    } else {
      mode = 'play';
      toggleRunning(Mobj.getAlreadyLoaded(timerID, TimerDataType()),
          reset: false);
    }
    modeActivationPulse.add(null);
    _selectTimer(null);
  }

  double nextRandomHue() {
    final ret = nextHueMobj.value!;
    final increment = 0.1 + Random().nextDouble() * 0.15;
    nextHueMobj.value = (ret + increment) % 1;
    return ret;
  }

  void numeralPressed(List<int> number, {bool viaKeyboard = false}) {
    if (selectedTimer.peek() == null) {
      isFirstPressForSelectedTimer.value = true;
      addNewTimer(
        selected: true,
        digits: stripZeroes(number),
      );
    } else {
      isFirstPressForSelectedTimer.value = false;
      final mt = Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      List<int> ct = List.from(mt.peek()!.digits);
      for (int n in number) {
        ct.add(n);
      }
      mt.value = mt.peek()!.withChanges(digits: ct);
    }
    if (viaKeyboard) {
      final flashAnimation = numeralKeys[number.first].currentState?.longFlash;
      if (flashAnimation != null) {
        flashAnimation.forward(from: 0);
      }
    }
  }

  void togglePin(MobjID<TimerData> timerID) {
    Mobj.fetch(timerID, type: TimerDataType()).then((mt) {
      bool pp = mt.peek()!.pinned;
      // this feature is benign but behaviorally maximalist to the point of being ugly and confusing
      // if (pp && !mt.peek()!.isRunning) {
      //   deleteTimer(timerID);
      // } else {
      //   mt.value = mt.peek()!.withChanges(pinned: !pp);
      // }
      mt.value = mt.peek()!.withChanges(pinned: !pp);
    });
  }

  // Add new method to handle key events
  void _handleKeyPress(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return;
    }
    // Handle number keys 0-9
    int? kn = recognizeDigitPress(event.logicalKey);
    if (kn != null) {
      numeralPressed([kn], viaKeyboard: true);
    } else {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.backspace:
          _backspace();
          break;
        case LogicalKeyboardKey.keyP:
        case LogicalKeyboardKey.space:
        case LogicalKeyboardKey.enter:
          pausePlaySelected();
          break;
        case LogicalKeyboardKey.keyN:
          addNewTimer(selected: true);
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print('TimerScreenState build');
    ThemeData theme = Theme.of(context);
    Size screenSize = MediaQuery.sizeOf(context);
    MakoThemeData mt = MakoThemeData.fromTheme(theme);
    final thumbSpan = Thumbspan.of(context);

    final buttonSpan = watchSignal(context, buttonSpanMobj)!;
    final bottomGutter =
        max(thumbSpan * 0.3, MediaQuery.of(context).padding.bottom);
    final controlsh = bottomGutter + 4 * buttonSpan;
    // Calculate the vertical space generally taken by Timer widgets (tallest, including padding).
    final timerHeight = Timer.usualHeight();
    bool isRightHanded = watchSignal(context, isRightHandedMobj)!;

    Widget proportionedIcon(IconData icon, {double size = 22}) {
      return ScalingAspectRatio(
          child: SizedBox(
              width: 50,
              height: 50,
              child: Center(child: Icon(size: size, icon))));
    }

    var selectButton = Builder(
      builder: (context) => TimersButton(
          // label: Icon(Icons.select_all),
          // label: Icon(Icons.border_outer_rounded),
          key: selectButtonKey,
          label: const SpecialTimerShapesLabel(),
          onPanDown: (Offset p) {
            specialTimerCreateDragRingController.onPanDown(
                context, p, boxRect(selectButtonKey as GlobalKey)!.center);
          },
          onPanUpdate: (Offset p) {
            specialTimerCreateDragRingController.onPanUpdate(context, p);
          },
          onPanEnd: () {
            specialTimerCreateDragRingController.onPanEnd(context);
          }),
    );

    var backspaceButton = TimersButton(
        key: deleteButtonKey,
        label: proportionedIcon(Icons.backspace),
        onPanDown: (_) {
          _backspace();
        });

    var pinButton = TimersButton(
        key: pinButtonKey,
        label: Transform.rotate(
            angle: pi / 4, child: proportionedIcon(Icons.push_pin)),
        onPanEnd: () {
          _selectAction('pin');
        });

    final addButton = TimersButton(
        label: proportionedIcon(Icons.add_circle),
        onPanDown: (_) {
          addNewTimer(selected: true);
        });

    // stopwatches probably shouldn't be timers, but need to go in the timer list
    // final createStopwatchButton = TimersButton(
    //     label: proportionedIcon(Icons.stop),
    //     onPanDown: (_) {
    //       addNewStopwatch();
    //     },
    //     onPanEnd: () {
    //       // start the stopwatch (starting on end gives the user more precision)
    //       pausePlaySelected();
    //     });

    // todo: animate the play icon out when playing
    Widget playIcon(Icon otherIcon) {
      // todo: measure the width of the icons to make this precise
      double dispf = 0.3;
      return Stack(children: [
        FractionalTranslation(translation: Offset(-dispf, 0), child: otherIcon),
        Transform.scale(
            scale: 0.8,
            child: FractionalTranslation(
                translation: Offset(dispf, 0),
                child: Icon(Icons.play_arrow_rounded)))
      ]);
    }

    // final pausePlayButton = TimersButton(
    //     label: playIcon(Icon(Icons.pause_rounded)),
    //     onPanDown: (_) {
    //       pausePlaySelected();
    //     });
    final stopPlayButton = TimersButton(
        label: playIcon(Icon(Icons.restart_alt_rounded)),
        onPanDown: (_) {
          pausePlaySelected(reset: true);
        });

    final buttonScaleDial = Watch(
      (context) {
        if (buttonScaleDialCenter.value == null) {
          // Offset p = Offset(screenSize.width * 0.23, screenSize.height / 2);
          // if (!isRightHanded) {
          //   p = Offset(screenSize.width - p.dx, p.dy);
          // }
          buttonScaleDialCenter.value = sizeToOffset(screenSize / 2);
        }
        return positionedAt(
          buttonScaleDialCenter.value!,
          FractionalTranslation(
              translation: Offset(-0.5, -0.5),
              child: AnimatedBuilder(
                animation: Listenable.merge(
                    [buttonScaleDialAnimation, buttonScaleFlashAnimation]),
                builder: (context, child) {
                  final fa = buttonScaleFlashAnimation.value;
                  double flashu =
                      fa == 1.0 ? 0 : moduloProperly(-fa, 1.0 / 5.0);
                  return Transform.scale(
                      scale: Curves.easeOutCubic
                          .transform(buttonScaleDialAnimation.value),
                      child: GestureDetector(
                        onPanDown: (details) {
                          buttonScaleDialLeavingTimer?.cancel();
                        },
                        onPanUpdate: (details) {
                          final aa = angleFrom(buttonScaleDialCenter.peek()!,
                              details.globalPosition - details.delta);
                          final ab = angleFrom(buttonScaleDialCenter.peek()!,
                              details.globalPosition);
                          final a = shortestAngleDistance(aa, ab);
                          buttonScaleDialAngle.value += a;
                          buttonSpanMobj.value = clampDouble(
                              buttonSpanMobj.value! + a * 1.2,
                              12,
                              screenSize.width / 5);
                        },
                        onPanEnd: (details) {
                          buttonScaleDialLeavingTimer =
                              async.Timer(Duration(milliseconds: 470), () {
                            buttonScaleDialOn.value = false;
                          });
                        },
                        child: Transform.rotate(
                          transformHitTests: false,
                          angle: buttonScaleDialAngle.value,
                          child: Container(
                            width: 140,
                            height: 140,
                            decoration: BoxDecoration(
                              color: lerpColor(mt.midBackColor,
                                  theme.colorScheme.primary, flashu),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanDown: (details) {},
                                onPanUpdate: (details) {
                                  buttonScaleDialCenter.value =
                                      buttonScaleDialCenter.value! +
                                          details.delta;
                                },
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    color: mt.foreBackColor,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Text("turn me",
                                          textAlign: TextAlign.center)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ));
                },
              )),
        );
      },
    );

    // the lower part of the screen
    final buttonSize = Size(buttonSpan, buttonSpan);
    // this code is supposed to nudge things over a little to be perfectly centered if stuff is very close to being centered.
    // double backingDeflation = backingDeflationProportion * buttonSpan;
    // makes it much easier to keep gaps between timers and gap between bottom timer and control pad backing equal
    double backingDeflation = timerGap / 2;
    // positioned to make the space between the number pad backing and the edge of the screen equal
    double tentativeRightPos =
        screenSize.width - buttonSpan / 2 - backingDeflation;
    // double tentativeRightPos = screenSize.width - buttonSpan / 2;
    final imperfection =
        ((tentativeRightPos - 2 * buttonSpan) - screenSize.width / 2) /
            screenSize.width;
    if (imperfection < 0.055) {
      tentativeRightPos = screenSize.width / 2 + 2 * buttonSpan;
    }
    final topRightControlAnchor = Offset(
        tentativeRightPos, screenSize.height - controlsh + buttonSpan / 2);

    // final topLeftPos = topRightPos + Offset(-buttonSpan * 5, 0);
    /// pi and spani are in buttonSpan units
    Rect controlGridBound(Offset pi, Size spani) {
      Offset point = (topRightControlAnchor + pi * buttonSpan);
      if (!isRightHanded) {
        point = Offset(
            screenSize.width - point.dx - (spani.width - 1) * buttonSpan,
            point.dy);
      }
      return ((point - sizeToOffset(buttonSize / 2)) & (spani * buttonSpan));
    }

    final configButton = TimersButton(
        key: configButtonKey,
        label: SizedBox(
          width: buttonSpan * 0.54,
          height: buttonSpan * 0.54,
          child: Hero(
              tag: 'configButton',
              child: ScalingAspectRatio(
                  child: Icon(
                size: 10,
                Icons.settings_rounded,
              ))),
        ),
        // onPanDown feels more responsive of course, but it's inconsistent with usual behavior of touch interfaces, so I'm not sure which is better
        // onPanDown: (_) {
        onPanEnd: () {
          Navigator.push(
            context,
            CircularRevealRoute(
              builder: (context) => SettingsScreen(flipBackgroundColors: false),
              iconOriginKey: configButtonKey,
            ),
          );
        });

    Widget numeralBacking = Positioned.fromRect(
        rect: controlGridBound(Offset(-3, 0), Size(3, 4))
            .deflate(backingDeflation),
        child: Container(
            constraints: BoxConstraints.expand(),
            decoration: BoxDecoration(
                color: mt.foreBackColor,
                borderRadius: BorderRadius.circular(
                    backingCornerRounding * buttonSpan))));

    final double modalHighlightSpan = buttonSpan - 2 * backingDeflation;
    Widget modalHighlightBacking = Watch((context) {
      final anchor = modeHighlightAnchor.watch(context);
      return AnimatedBuilder(
        animation: modeLivenessAnimation,
        builder: (context, child) {
          return positionedAt(
              anchor,
              Animove(
                key: modeHighlightAnimoveKey,
                enabled: modeLivenessAnimation.value > 0,
                simulationFactory: (c, t, v) => TimelyParabolicSimulation(
                  c,
                  t,
                  v,
                  duration: 0.2,
                ),
                child: FractionalTranslation(
                  translation: Offset(-0.5, -0.5),
                  child: SizedBox(
                    width: modalHighlightSpan * modeLivenessAnimation.value,
                    height: modalHighlightSpan * modeLivenessAnimation.value,
                    child: PulserAnimation(
                        pulses: modeActivationPulse.stream,
                        duration: Duration(milliseconds: 440),
                        builder: (context, child, progresses) {
                          final p = min(
                              1.0,
                              progresses.fold(
                                  0.0,
                                  (a, b) =>
                                      a + 0.55 * defaultPulserFunction(b)));
                          return Container(
                              decoration: BoxDecoration(
                                  color: lerpColor(mt.foreBackColor,
                                      theme.colorScheme.primary, p),
                                  borderRadius: BorderRadius.circular(
                                      backingCornerRounding * buttonSpan)));
                        }),
                  ),
                ),
              ));
        },
      );
    });

    final numeralPartAnchor = Offset(-3, 0);
    final outerPaletteAnchor = Offset(-4, 0);
    final innerPaletteAnchor = Offset(0, 0);

    final controls = [
      modalHighlightBacking,
      numeralBacking,
      ...List.generate(9, (i) {
        int ix = i % 3;
        int iy = i ~/ 3;
        // double invert
        if (!isRightHanded) {
          ix = 2 - ix;
        }
        if (watchSignal(context,
            Mobj.getAlreadyLoaded(padVerticallyAscendingID, BoolType()))!) {
          iy = 2 - iy;
        }
        final ii = i + 1;
        return Positioned.fromRect(
            rect: controlGridBound(
                numeralPartAnchor + Offset(ix.toDouble(), iy.toDouble()),
                Size(1, 1)),
            child: NumeralButton(
                digits: [ii],
                timerButtonKey: numeralKeys[ii],
                otherDragActionRingStarted: onNewNumeralDragActionRing));
      }),
      Positioned.fromRect(
          rect: controlGridBound(numeralPartAnchor + Offset(0, 3), Size(1, 1)),
          child: NumeralButton(
              digits: [0],
              timerButtonKey: numeralKeys[0],
              otherDragActionRingStarted: onNewNumeralDragActionRing)),
      Positioned.fromRect(
          rect: controlGridBound(innerPaletteAnchor + Offset(0, 0), Size(1, 1)),
          child: configButton),
      // Positioned.fromRect(
      //     rect: positionAt(outerPaletteAnchor, Size(1, 1)),
      //     child: backspaceButton),
      // Positioned.fromRect(
      //     rect: controlGridBound(innerPaletteAnchor + Offset(0, 1), Size(1, 1)),
      //     child: pinButton),
      // Positioned.fromRect(
      //     rect: controlGridBound(innerPaletteAnchor + Offset(0, 1), Size(1, 1)),
      //     child: createStopwatchButton),
      Positioned.fromRect(
          rect: controlGridBound(innerPaletteAnchor + Offset(0, 1), Size(1, 1)),
          child: selectButton),
      Positioned.fromRect(
        rect: controlGridBound(innerPaletteAnchor + Offset(0, 2), Size(1, 1)),
        child: TimersButton(
          label: proportionedIcon(Icons.view_sidebar_outlined),
          onPanEnd: () {
            if (squishPanelController.status == AnimationStatus.forward ||
                squishPanelController.status == AnimationStatus.completed) {
              squishPanelController.reverse();
            } else {
              squishPanelController.forward();
            }
          },
        ),
      ),
    ];

    Widget editPopoverIcon(
        Offset gridPos, IconData icon, Function() onTap, double size) {
      return AnimatedBuilder(
        animation: editPopoverAnimation,
        builder: (context, child) {
          final opacity =
              unlerpUnit(0.5, 1.0, editPopoverAnimation.scalarValue);
          return Positioned.fromRect(
            rect: controlGridBound(gridPos, Size(1, 1)),
            child: IgnorePointer(
              ignoring: selectedTimer.value == null,
              child: Opacity(
                opacity: opacity,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: SizedBox.expand(
                    child: Icon(
                      icon,
                      color: theme.colorScheme.primary,
                      size: buttonSpan * size,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    // edit popover
    final editPopoverOrigin = Offset(-4, 1);
    final editPopoverBacking = AnimatedBuilder(
      animation: editPopoverAnimation,
      builder: (context, child) {
        final fromRect = controlGridBound(editPopoverOrigin, Size(1, 1))
            .deflate(backingDeflation)
            .shift(Offset(buttonSpan * 0.4, 0));
        final toRect = controlGridBound(editPopoverOrigin, Size(1, 2))
            .deflate(backingDeflation);
        final backingRectProgress =
            unlerpUnit(0, 0.7, editPopoverAnimation.scalarValue);
        // deflated to nothing by targetRad at first
        final targetRad = buttonSpan - backingDeflation * 2;
        final backingRect = Rect.lerp(
                fromRect,
                toRect,
                Curves.easeInOutCubic
                    .transform(unlerpUnit(0.3, 1, backingRectProgress)))!
            .deflate((1 - Curves.easeOut.transform(backingRectProgress)) *
                targetRad);
        return Positioned.fromRect(
          rect: backingRect,
          child: Container(
            constraints: BoxConstraints.expand(),
            decoration: BoxDecoration(
              color: mt.foreBackColor,
              borderRadius:
                  BorderRadius.circular(backingCornerRounding * buttonSpan),
            ),
          ),
        );
      },
    );

    final editPopoverBackspaceButton =
        editPopoverIcon(editPopoverOrigin, Icons.backspace_rounded, () {
      _backspace();
    }, 0.4);
    final editPopoverPlayButton = editPopoverIcon(
        editPopoverOrigin + Offset(0, 1), Icons.play_arrow_rounded, () {
      pausePlaySelected();
    }, 0.6);

    // I considered adding another hint text (suggesting that the user go into settings and choose a preferred audio) but to do this properly we should have like a toast behavior, and it was such a bizarre feature and not worth it yet.

    final hintMargin = thumbSpan * 0.2;
    final hintTray = Positioned(
      left: hintMargin,
      top: MediaQuery.of(context).padding.top + hintMargin,
      // width: screenSize.width * 0.71 - hintMargin,
      right: hintMargin,
      child: Column(
        spacing: 8,
        children: [
          Builder(builder: (context) {
            final dir = isRightHanded ? "left" : "right";
            return HintToast(
                showCondition: userDragActionHintCondition,
                message:
                    """when you press a number, you can drag up or to the $dir. this will activate the new timer. (dragging $dir adds a pair of zeroes to it before activating it.)""");
          }),
          HintToast(
            showCondition: hasUsedMenuTwice,
            message:
                "you can press and hold (and release) a timer to bring open a menu that allows additional actions (such as deleting or editing it)",
          ),
          HintToast(
              showCondition: hintGetsCompositeTimersCondition,
              message:
                  "'timercules' like 'cycle' and 'series' allow you to drag other timers into them, to build structures. You can use those to create pomodoro timers, which some people find useful for productivity and focus, or multi-stage sequence timers, which are useful for carrying out complex recipes with precise timings. Play around with them.")
        ],
      ),
    );

    final timersWidget = TimerTray(
      key: timerTrayKey,
      timerWidgets: timerWidgets,
      mobj: timerListMobj,
      backgroundColor: mt.lowestBackColor,
      icon: Icon(Icons.push_pin), // You can customize this icon
      useScrollView: true,
    );

    return nesting(
        [
          (child) => AnimoveFrame(child: child),
          (child) => AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                systemNavigationBarContrastEnforced: false,
                systemNavigationBarDividerColor:
                    mt.lowestBackColor.withAlpha(0),
                systemNavigationBarColor: mt.lowestBackColor.withAlpha(0),
                systemNavigationBarIconBrightness:
                    theme.brightness == Brightness.dark
                        ? Brightness.light
                        : Brightness.dark,
              ),
              child: child),
          (child) => Scaffold(
              backgroundColor: mt.lowestBackColor,
              resizeToAvoidBottomInset: false,
              body: child),
          (child) => Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (FocusManager.instance.primaryFocus != node) {
                  return KeyEventResult.ignored;
                }
                _handleKeyPress(event);
                return KeyEventResult.handled;
              },
              child: child),
          // the dragtarget for the timer tray encompasses the entire TimerScreen so that you can drop above or below the widget to get above or below the top or bottom row. Otherwise, this can be difficult or impossible, which is a problem when you consider timercules, which unlike timers, can't be dragged after by dragging onto the second half
          (child) => DragTarget<GlobalKey<TimerBaseState>>(
              builder: (context, candidateData, rejectedData) => child,
              onMove: (DragTargetDetails<GlobalKey<TimerBaseState>> details) {},
              onAcceptWithDetails: (details) {
                final wrapKey = timerTrayKey.currentState!.wrapKey;
                final p = timerListMobj.peek()!;
                final insertion = insertionOf(wrapKey, details.offset);
                final timerId =
                    (details.data.currentWidget! as TimerBase).mobj.id;
                final currentIndex = p.indexWhere((t) => t == timerId);
                final Mobj<TimerData> cm =
                    (details.data.currentWidget! as TimerBase).mobj;
                doInsertion(int at) {
                  writeBackChildren(
                      timerListMobj, p.toList()..insert(at, timerId));
                }

                //transaction start
                if (cm.peek()!.parentId == null) {
                  doInsertion(insertion.midwayInsertionIndex());
                } else {
                  final oldList = Mobj.seekTypedsAlreadyLoaded(
                      cm.peek()!.parentId!,
                      [TimerDataType(), ListType(StringType())])!;
                  final oldChildren = childrenOf(oldList);
                  final oldIndex = oldChildren.indexOf(timerId);
                  simpleRemove() {
                    writeBackChildren(
                        oldList, oldChildren.toList()..removeAt(oldIndex));
                  }

                  if (cm.peek()!.parentId == timerListMobj.id) {
                    assert(currentIndex != -1,
                        "item wasn't found inside of its owningList");
                    if (insertion.index != currentIndex) {
                      final (operative, at) = insertion.cleverInsertionIndexFor(
                          currentIndex, p.length);
                      if (operative) {
                        timerListMobj.value = p.toList()
                          ..insert(at, timerId)
                          ..removeAt(currentIndex > at
                              ? currentIndex + 1
                              : currentIndex);
                      }
                    }
                  } else {
                    doInsertion(insertion.midwayInsertionIndex());
                    simpleRemove();
                  }
                }
                cm.value = cm.peek()!.withChanges(parentId: timerListMobj.id);

                bool noDuplicates<T>(List<T> v) {
                  for (int i = 0; i < v.length; ++i) {
                    for (int j = i + 1; j < v.length; ++j) {
                      if (v[i] == v[j]) return false;
                    }
                  }
                  return true;
                }

                assert(noDuplicates(p));
                //transaction end
              }),
        ],
        SelfRemovalHost(
          key: ephemeralAnimationLayer,
          builder: (children, context) => ConstrainedBox(
              constraints: BoxConstraints.expand(),
              child: Stack(
                  children: [
                        hintTray,
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          top: 0,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AnimatedBuilder(
                                animation: squishPanelController,
                                builder: (context, child) {
                                  final w = screenSize.width *
                                      0.7 *
                                      squishPanelController.value;
                                  return SizedBox(
                                    width: w,
                                    child: w <= 0
                                        ? null
                                        : SquishBoundaryPlane(
                                            theme: theme, mt: mt),
                                  );
                                },
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                    controller: timersScroller,
                                    reverse: true,
                                    child: Column(children: [
                                      SizedBox(
                                          height: screenSize.height -
                                              controlsh -
                                              timerHeight),
                                      timersWidget,
                                      SizedBox(height: controlsh),
                                    ])),
                              ),
                            ],
                          ),
                        ),
                        ...controls,
                        editPopoverBacking,
                        editPopoverBackspaceButton,
                        editPopoverPlayButton,
                        buttonScaleDial,
                      ] +
                      children)),
          // we stack a bunch of stuff here that's not ephemeral because that's allowed
        ));
  }

  void pausePlaySelected({bool reset = false}) {
    final id = selectedTimer.peek();
    if (id != null) {
      if (toggleRunning(Mobj.getAlreadyLoaded(id, TimerDataType()),
          reset: reset)) {
        _selectTimer(null);
      }
    }
  }

  void addNewTimer({
    int? runningState,
    bool? selected,
    List<int>? digits,
  }) {
    final ntid = UuidV4().generate();

    bool selecting = selected ?? false;

    // we leak this. By not deleting it, it will stay in the db and registry as a root object
    Mobj<TimerData>.clobberCreate(
      ntid,
      type: TimerDataType(),
      initial: TimerData(
        startTime: null,
        runningState: runningState ?? TimerData.paused,
        hue: nextRandomHue(),
        selected: selecting,
        digits: digits ?? const [],
        ranTime: Duration.zero,
        parentId: timerListMobj.id,
        isGoingOff: false,
      ),
    );
    Mobj.getAlreadyLoaded(hasCreatedTimerID, BoolType()).value = true;
    final n = Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType());
    n.value = n.peek()! + 1;

    timerListMobj.value = peekTimers().toList()..add(ntid);
    if (selecting) {
      _selectTimer(ntid);
    }

    cleanOldTimers(except: ntid);

    timersScroller.animateTo(0,
        duration: Duration(milliseconds: 180), curve: Curves.easeInOutCubic);
  }

  void addNewStopwatch() {
    final ntid = UuidV4().generate();

    // we leak this. By not deleting it, it will stay in the db and registry as a root object
    Mobj<TimerData>.clobberCreate(
      ntid,
      type: TimerDataType(),
      initial: TimerData(
        startTime: DateTime.now(),
        runningState: TimerData.running,
        hue: nextRandomHue(),
        selected: false,
        digits: const [],
        ranTime: Duration.zero,
        isGoingOff: false,
        parentId: timerListMobj.id,
        kind: TimerKind.stopwatch,
      ),
    );
    Mobj.getAlreadyLoaded(hasCreatedTimerID, BoolType()).value = true;
    final n = Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType());
    n.value = n.peek()! + 1;

    timerListMobj.value = peekTimers().toList()..add(ntid);

    cleanOldTimers(except: ntid);

    timersScroller.animateTo(0,
        duration: Duration(milliseconds: 180), curve: Curves.easeInOutCubic);
  }

  void addNewCompositeTimer(TimerKind kind) {
    final ntid = UuidV4().generate();
    Mobj<TimerData>.clobberCreate(
      ntid,
      type: TimerDataType(),
      // pinned starts true for composite timers because they're not so often faster to recreate than to reuse, so it's going to be very rare that the user wants them autodeleted
      initial: TimerData(
          kind: kind,
          hue: nextRandomHue(),
          selected: false,
          parentId: timerListMobj.id),
    );
    timerListMobj.value = peekTimers().toList()..add(ntid);
    final n = Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType());
    n.value = n.peek()! + 1;

    cleanOldTimers(except: ntid);
    timersScroller.animateTo(0,
        duration: Duration(milliseconds: 180), curve: Curves.easeInOutCubic);
  }

  void cleanOldTimers({MobjID<TimerData>? except}) {
    // remove (previous) unpinned nonplaying timers
    final curTimers = peekTimers();
    for (final tid in curTimers) {
      if (tid == except) continue;
      final t = Mobj.getAlreadyLoaded(tid, TimerDataType());
      if (trivialAndClearable(t, null)) {
        deleteTimer(tid);
      }
    }
  }

  void _selectTimer(MobjID<TimerData>? timerID) {
    if (selectedTimer.peek() != null) {
      final oldMobj =
          Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      oldMobj.value = oldMobj.peek()!.withChanges(selected: false);
    }
    selectedTimer.value = timerID;
    if (timerID != null) {
      final newMobj = Mobj.getAlreadyLoaded(timerID, TimerDataType());
      newMobj.value = newMobj.peek()!.withChanges(selected: true);
    }
  }

  void _backspace() {
    if (selectedTimer.peek() != null) {
      final mobj =
          Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      List<int> digits = List.from(mobj.peek()!.digits);

      if (digits.isEmpty) {
        deleteTimer(selectedTimer.peek()!);
      } else {
        digits.removeLast();
        if (digits.isEmpty) {
          deleteTimer(selectedTimer.peek()!);
        } else {
          mobj.value = mobj.peek()!.withChanges(digits: digits);
        }
      }
    } else {
      // _selectAction('delete');
      if (timers().isNotEmpty) {
        deleteTimer(timers().last);
      }
    }
  }

  void _selectAction(String action) {
    if (actionMode.peek() != action) {
      actionMode.value = action;
    } else {
      actionMode.value = 'play';
    }
  }

  void deleteTimer(MobjID ki) {
    // everything is triggered by this and code that responds to it in various places
    Mobj.getAlreadyLoaded(ki, TimerDataType()).value = null;
  }

  void removeTimer(MobjID ki) {
    // Check if timer exists in the list
    if (!peekTimers().contains(ki)) {
      return;
    }

    timerListMobj.value = peekTimers().toList()
      ..removeWhere((timer) => timer == ki);

    if (selectedTimer.peek() == ki) {
      _selectTimer(null);
    }
  }

  Mobj<TimerData>? selectedOrLastTimerState() {
    if (selectedTimer.peek() != null) {
      return Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
    } else {
      final lt = peekTimers().lastOrNull;
      if (lt != null) {
        return Mobj.getAlreadyLoaded(lt, TimerDataType());
      }
      return null;
    }
  }
}

/// manages a drag action ring. Use by calling the onPanDown, onPanUpdate, and onPanEnd methods from yours. Assumes that there's a SelfRemovalHostState above the given context, for the DragActionRing to live in.
/// dispose when you're done with it
class DragActionRingController {
  /// just visually closes the ring on trigger. Doesn't really need to be in controller but whatever.
  final ChangeNotifier? suppressingNotifier;

  /// -1 means nothing is selected, number means item has been selected, null means dismissed
  late final Signal<int?> _dragEvents = Signal(null, debugLabel: 'dragEvents');
  ReadonlySignal<int?> get dragEvents => _dragEvents;
  // UpDownAnimationController? get numeralDragIndicator =>
  //     numeralDragActionRing?.currentState?.widget.upDownAnimation;
  // AnimationController? get numeralDragIndicatorSelect =>
  //     numeralDragActionRing?.currentState?.widget.optionActivationAnimation;
  // GlobalKey<NumeralDragActionRingState>? numeralDragActionRing;
  Offset _startDrag = Offset.zero;
  bool dragActionRingDisabled = false;
  final List<Function()> radialActivatorFunctions;
  final List<double> radialActivatorPositions;
  final List<Widget>? radialActivatorLabels;
  final List<Widget> radialActivatorIcons;

  /// whether to shunt text to the right or to the left, when the angle is close to a vertical position. Important for radial menus that're closer to the side of the screen. It's with respect to handedness, the meaning flips when the handedness flips.
  final bool? shuntRight;

  DragActionRingController(
      {this.suppressingNotifier,
      required this.radialActivatorFunctions,
      required this.radialActivatorPositions,
      this.radialActivatorLabels,
      required this.radialActivatorIcons,
      this.shuntRight}) {
    assert(radialActivatorIcons.length == radialActivatorPositions.length,
        'DragActionRingController: radialActivatorIcons and radialActivatorPositions should have the same length');
    assert(radialActivatorFunctions.length == radialActivatorIcons.length,
        'DragActionRingController: radialActivatorFunctions and radialActivatorIcons should have the same length');
  }

  void disable() {
    dragActionRingDisabled = true;
  }

  void dispose() {
    _dragEvents.dispose();
    suppressingNotifier?.removeListener(disable);
  }

  SelfRemovalHostState getSelfRemovalHostState(BuildContext context) {
    final srh = context.findAncestorStateOfType<SelfRemovalHostState>();
    if (srh == null) {
      throw Exception(
          'DragActionRingController: We require a SelfRemovalHostState as an ancestor of the context given to onPanDown, so that the DragActionRing we create can live in.');
    }
    return srh;
  }

  void onPanDown(
      BuildContext context, Offset touchOrigin, Offset visualCenter) {
    dragActionRingDisabled = false;
    _startDrag = touchOrigin;

    _dragEvents.value = -1;
    // it's a void listenable, so we can't just set the value (it'll be equivalent to the previous value and wont notify listeners)
    // ignore: invalid_use_of_protected_member
    final numeralDragActionRing = DragActionRing(
      key: UniqueKey(),
      position: touchOrigin,
      visualPosition: visualCenter,
      suppressionBus: suppressingNotifier,
      dragEvents: _dragEvents,
      shuntRight: shuntRight,
      radialActivatorIcons: radialActivatorIcons,
      radialActivatorLabels: radialActivatorLabels,
      radialActivatorPositions: radialActivatorPositions,
    );
    getSelfRemovalHostState(context).add(numeralDragActionRing);
  }

  void onPanUpdate(BuildContext context, Offset p) {
    Offset dp = p - _startDrag;
    if (!dragActionRingDisabled) {
      if (dp.distance > Thumbspan.of(context) * 0.3) {
        bool isRightHanded =
            Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).peek()!;
        final rectifiedActivatorPositions = isRightHanded
            ? radialActivatorPositions
            : radialActivatorPositions.map(flipAngleHorizontally).toList();
        _dragEvents.value = radialDragResult(
            rectifiedActivatorPositions, offsetAngle(dp),
            hitSpan: pi);
      } else {
        _dragEvents.value = -1;
      }
    }
  }

  void onPanEnd(BuildContext context) {
    if (_dragEvents.peek() != -1 && _dragEvents.peek() != null) {
      radialActivatorFunctions[_dragEvents.peek()!]();
    }
    _dragEvents.value = null;
    suppressingNotifier?.removeListener(disable);
  }
}

class NumeralButton extends StatefulWidget {
  final List<int> digits;
  final GlobalKey<TimersButtonState>? timerButtonKey;
  final ChangeNotifier otherDragActionRingStarted;
  const NumeralButton(
      {super.key,
      required this.digits,
      this.timerButtonKey,
      required this.otherDragActionRingStarted});
  @override
  State<NumeralButton> createState() => _NumeralButtonState();
}

class _NumeralButtonState extends State<NumeralButton> {
  late final DragActionRingController dragActionRingController;

  @override
  void initState() {
    super.initState();
    dragActionRingController = DragActionRingController(
      suppressingNotifier: widget.otherDragActionRingStarted,
      radialActivatorFunctions: List.generate(
        numericRadialActivatorFunctions.length,
        (i) => () {
          final tss = context.findAncestorStateOfType<TimerScreenState>();
          if (tss == null) {
            return;
          }
          numericRadialActivatorFunctions[i](tss);
          // cause the affected timer to bounce
          final isRightHanded = tss.isRightHandedMobj.peek()!;
          final rectifiedActivatorPositions = isRightHanded
              ? numericRadialActivatorPositions
              : numericRadialActivatorPositions
                  .map(flipAngleHorizontally)
                  .toList();
          final lti = tss.timerListMobj.peek()!.lastOrNull;
          if (lti != null) {
            final sts = tss.selectedTimer.peek();
            if (sts != null) {
              final ts =
                  (tss.timerWidgetCache[sts]?.key as GlobalKey<TimerState>?)
                      ?.currentState;
              ts?._slideActivateBounceAnimation.forward(from: 0);
              ts?._slideBounceDirection =
                  Offset.fromDirection(rectifiedActivatorPositions[i], 1);
            }
          }
        },
      ),
      radialActivatorPositions: numericRadialActivatorPositions,
      radialActivatorIcons: [
        Icon(Icons.play_arrow_rounded),
        Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 0,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [Icon(Icons.play_arrow_rounded), Text('+00')]),
      ],
    );
  }

  @override
  void dispose() {
    dragActionRingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TimersButton(
      key: widget.timerButtonKey,
      label: widget.digits.join(),
      onPanDown: (Offset p) {
        final tss = context.findAncestorStateOfType<TimerScreenState>()!;
        tss.numeralPressed(widget.digits);
        // ignore: invalid_use_of_protected_member
        widget.otherDragActionRingStarted.notifyListeners();
        widget.otherDragActionRingStarted
            .addListener(dragActionRingController.disable);
        dragActionRingController.onPanDown(
            context, p, boxRect(widget.timerButtonKey! as GlobalKey)!.center);
      },
      onPanUpdate: (Offset p) {
        dragActionRingController.onPanUpdate(context, p);
      },
      onPanEnd: () {
        dragActionRingController.onPanEnd(context);
      },
    );
  }
}

const controlPadTextStyle = TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.normal,
  fontFamily: 'Dongle',
  height: 1.71, // Controls line height, adjust to fine-tune vertical centering
);

class TimersButton extends StatefulWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback? onTap;
  final bool accented;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final bool solidColor;
  final Animation<double>? dialBloomAnimation;

  const TimersButton(
      {super.key,
      required this.label,
      this.onTap,
      this.solidColor = false,
      this.accented = false,
      this.onPanDown,
      this.onPanUpdate,
      this.onPanEnd,
      this.dialBloomAnimation});

  @override
  State<TimersButton> createState() => TimersButtonState();
}

class TimersButtonState extends State<TimersButton>
    with TickerProviderStateMixin {
  late AnimationController shortFlash;
  late AnimationController longFlash;
  @override
  initState() {
    super.initState();
    shortFlash =
        AnimationController(vsync: this, duration: Duration(milliseconds: 450))
          ..value = 1;
    longFlash =
        AnimationController(vsync: this, duration: Duration(milliseconds: 800))
          ..value = 1;
  }

  @override
  void dispose() {
    shortFlash.dispose();
    longFlash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final buttonSpan = 0.7 * Thumbspan.of(context);

    return nesting(
      [
        // we make sure to pass null if they're null because having a non-null value massively lowers the slopping radius
        (child) => GestureDetector(
              onPanDown: (details) {
                final tss = context.findAncestorStateOfType<TimerScreenState>();
                tss?.currentlyPressingKey.value += 1;
                widget.onPanDown?.call(details.globalPosition);
              },
              onPanUpdate: widget.onPanUpdate != null
                  ? (details) =>
                      widget.onPanUpdate?.call(details.globalPosition)
                  : null,
              onPanCancel: () {
                final tss = context.findAncestorStateOfType<TimerScreenState>();
                tss?.currentlyPressingKey.value -= 1;
                widget.onPanEnd?.call();
              },
              onPanEnd: (details) {
                final tss = context.findAncestorStateOfType<TimerScreenState>();
                tss?.currentlyPressingKey.value -= 1;
                widget.onPanEnd?.call();
              },
              child: child,
            ),
        // todo: this is wrong, we shouldn't be setting the size here, unfortunately there's a layout overflow behavior with rows that I don't understand
        (child) => Container(
              constraints:
                  BoxConstraints(maxWidth: buttonSpan, maxHeight: buttonSpan),
              child: child,
            ),
        // most of this is junk, you can just cut it down to the label widget if you ever need to
        (child) => InkWell(
              onTap: widget.onTap,
              splashColor: widget.accented ? Colors.transparent : null,
              highlightColor: widget.accented ? Colors.transparent : null,
              hoverColor: widget.accented ? Colors.transparent : null,
              focusColor: widget.accented ? Colors.transparent : null,
              // overlayColor: WidgetStateColor.resolveWith((_) => Colors.white),
              child: child,
            ),
      ],
      AnimatedBuilder(
        animation: Listenable.merge([shortFlash, longFlash]),
        builder: (context, child) {
          double flash = max((1 - Curves.easeIn.transform(shortFlash.value)),
              (1 - Curves.easeInOutCubic.transform(longFlash.value)));
          Color? textColor = widget.accented ? theme.colorScheme.primary : null;
          final backingColor = lerpColor(
              widget.accented
                  ? theme.colorScheme.primary
                  : widget.solidColor
                      ? theme.colorScheme.surfaceContainerLowest
                      : Colors.white.withAlpha(0),
              Colors.white,
              flash);
          final backing = Container(
              decoration: BoxDecoration(
            color: backingColor,
            border: Border.all(
              width: standardLineWidth,
              color: widget.accented
                  ? theme.colorScheme.primary
                  : Colors.transparent,
            ),
            // borderRadius: BorderRadius.circular(9)
          ));
          final Widget labelWidget;
          if (widget.label is String) {
            labelWidget = ScalingAspectRatio(
                child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                        child: Text(widget.label as String,
                            style: controlPadTextStyle
                                .merge(TextStyle(color: textColor))))));
          } else {
            labelWidget = widget.label as Widget;
          }
          return Center(
            child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [backing, labelWidget]),
          );
        },
      ),
    );
  }
}

class _NumpadTypeIndicator extends StatelessWidget {
  final bool isAscending;
  final Color? color;
  final double width;

  const _NumpadTypeIndicator(
      {required this.isAscending, this.color, this.width = 100.0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cellSpan = width / 3;
    final fontSize = 14.0;
    final fontScale = cellSpan / 10;
    final color = this.color ?? theme.colorScheme.onSurface;
    return SizedBox(
      width: width,
      height: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(9, (index) {
          final widg = Text((index + 1).toString(),
              style: TextStyle(
                  fontSize: fontSize,
                  color: color,
                  fontWeight: index == 0 ? FontWeight.w900 : FontWeight.w400,
                  fontFamily: 'Dongle'));
          // : Icon(Icons.circle, size: 3.0, color: theme.colorScheme.primary);
          final x = index % 3;
          int y = index ~/ 3;
          int py = isAscending ? 2 - y : y;
          return AnimatedPositioned(
            key: ValueKey((x, y)),
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: cellSpan / 2 + x * cellSpan,
            top: cellSpan / 2 + py * cellSpan + fontSize * 0.25,
            child: FractionalTranslation(
                translation: Offset(-0.5, -0.5),
                child: Transform.scale(scale: fontScale, child: widg)),
          );
        }),
      ),
    );
  }
}

double halfScreenHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  final screenHeight = mq.size.height;
  return screenHeight / 2 - mq.viewPadding.top;
}

// it would also look nice if you used this to size the app bar, but half is better for now
// double screenWidth(BuildContext context) {
//   final mq = MediaQuery.of(context);
//   return mq.size.width;
// }

(Color, Color) maybeFlippedBackgroundColors(
    ThemeData theme, bool flipBackgroundColors) {
  if (flipBackgroundColors) {
    return (
      theme.colorScheme.surfaceContainerLow,
      theme.colorScheme.surfaceContainerLowest
    );
  } else {
    return (
      theme.colorScheme.surfaceContainerLowest,
      theme.colorScheme.surfaceContainerLow
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  const SettingsScreen({super.key, this.flipBackgroundColors = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: 0,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, widget.flipBackgroundColors);
    final listItemPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0);

    Widget trailing(Widget child) =>
        SizedBox(width: 32.0, child: Center(child: child));

    Widget setupTile = ListTile(
      title: Text('Setup', style: theme.textTheme.bodyLarge),
      subtitle: Text('Resume setup',
          style: theme.textTheme.bodySmall!
              .copyWith(color: theme.colorScheme.onSurfaceVariant)),
      onTap: () {
        Navigator.push(
            context,
            CircularRevealRoute(
                builder: (context) => OnboardScreen(),
                iconOriginKey: configButtonKey));
      },
    );

    return Scaffold(
      backgroundColor: backgroundColorA,
      resizeToAvoidBottomInset: false,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Collapsible app bar with title
          SliverAppBar(
            pinned: true,
            centerTitle: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale:
                  1.0, // Disable title scaling to prevent Hero discontinuity
              title: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 40,
                      height: 40,
                      child: Hero(
                        tag: 'configButton',
                        createRectTween: (begin, end) => DelayedRectTween(
                            begin: begin, end: end, delay: 0.14),
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.settings_rounded,
                          color: theme.colorScheme.onSurface,
                          size: 10,
                        )),
                      )),
                  SizedBox(width: 5),
                  Text('Settings',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: backgroundColorB,
            surfaceTintColor: backgroundColorB,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              // Right-handed mode setting
              Watch((context) {
                final isRightHandedMobj =
                    Mobj.getAlreadyLoaded(isRightHandedID, BoolType());
                final isRightHanded = isRightHandedMobj.value ?? true;
                return ListTile(
                  title: Text('${isRightHanded ? 'Right' : 'Left'}-handed mode',
                      style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                    'optimize for ${isRightHanded ? 'right' : 'left'}-handed use',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  // splashColor: Colors.black,

                  // aaargh I can't fix the awful white-grey aspect of the highlight and the smash
                  // focusColor: Colors.red,
                  // selectedColor: Colors.red,
                  // // tileColor: Colors.red,
                  // selectedTileColor: Colors.red,
                  // textColor: Colors.red,
                  // hoverColor: Colors.red,
                  // splashColor: Colors.black,

                  trailing: trailing(TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: isRightHanded ? -1.0 : 1.0,
                      end: isRightHanded ? -1.0 : 1.0,
                    ),
                    duration: Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    builder: (context, scaleX, child) {
                      return Transform.scale(
                        scaleX: scaleX,
                        child: child,
                      );
                    },
                    child: Transform.rotate(
                      angle: 45 * pi / 180, // 45 degrees clockwise
                      child: Icon(
                        Icons.back_hand_rounded,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  )),
                  onTap: () {
                    isRightHandedMobj.value = !isRightHanded;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Watch((context) {
                final padVerticallyAscendingMobj =
                    Mobj.getAlreadyLoaded(padVerticallyAscendingID, BoolType());
                final padVerticallyAscending =
                    padVerticallyAscendingMobj.value ?? false;
                return ListTile(
                  title: Text('Numpad type', style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                    padVerticallyAscending
                        ? 'calculator/keyboard style'
                        : 'phone style',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  trailing: trailing(_NumpadTypeIndicator(
                    isAscending: padVerticallyAscending,
                    width: 36,
                  )),
                  onTap: () {
                    padVerticallyAscendingMobj.value = !padVerticallyAscending;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              // Alarm sound setting
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title: Text('Alarm sound', style: theme.textTheme.bodyLarge),
                  subtitle: Watch((context) {
                    return Text(
                      Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType())
                          .value!
                          .name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    );
                  }),
                  trailing: trailing(SizedBox(
                      width: 26,
                      height: 26,
                      child: Hero(
                        tag: 'alarm-sound-icon',
                        child: ScalingAspectRatio(
                            child: Icon(Icons.music_note,
                                key: hereIconKey,
                                color: theme.colorScheme.primary)),
                      ))),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => AlarmSoundPickerScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconOriginKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              // Persistent alarm mode setting
              Watch((context) {
                final persistentAlarmModeMobj =
                    Mobj.getAlreadyLoaded(persistentAlarmModeID, BoolType());
                final persistentAlarmMode =
                    persistentAlarmModeMobj.value ?? false;
                return SwitchListTile(
                  title: Text('Persistent alarm',
                      style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                    persistentAlarmMode
                        ? 'Alarm loops until you open the app'
                        : 'Alarm plays once',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  value: persistentAlarmMode,
                  onChanged: (value) {
                    persistentAlarmModeMobj.value = value;
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Watch((context) {
                final buttonScaleDialOnOn =
                    Mobj.getAlreadyLoaded(buttonScaleDialOnID, BoolType());
                return ListTile(
                  title: Text('Button size', style: theme.textTheme.bodyLarge),
                  subtitle: Text(
                      buttonScaleDialOnOn.value!
                          ? "Button scale dial is currently deployed, tap here to turn it off"
                          : 'Introduce a dial by which you can adjust UI scale',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  onTap: () {
                    buttonScaleDialOnOn.value = !buttonScaleDialOnOn.value!;
                    if (buttonScaleDialOnOn.value!) {
                      Navigator.of(context).pop();
                    }
                  },
                );
              }),
              Builder(builder: (context) {
                // Need a Builder to get the correct context for finding the icon's position
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title:
                      Text('About this app', style: theme.textTheme.bodyLarge),
                  trailing: trailing(SizedBox(
                    width: 26,
                    height: 26,
                    child: Hero(
                        tag: 'about-icon',
                        child: ScalingAspectRatio(
                            child: Icon(Icons.info_outline,
                                key: hereIconKey,
                                size: 10,
                                color: theme.colorScheme.primary))),
                  )),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => AboutScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconOriginKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                final hereIconKey = GlobalKey();
                return ListTile(
                  title: Text('Thank the author',
                      style: theme.textTheme.bodyLarge),
                  trailing: trailing(SizedBox(
                    width: 26,
                    height: 26,
                    child: Hero(
                        tag: 'thank-author-icon',
                        child: ScalingAspectRatio(
                          child: Icon(
                            Icons.heart_broken,
                            key: hereIconKey,
                            color: theme.colorScheme.primary,
                          ),
                        )),
                  )),
                  onTap: () {
                    Navigator.push(
                      context,
                      CircularRevealRoute(
                        builder: (context) => ThankAuthorScreen(
                            iconKey: iconKey,
                            flipBackgroundColors: !widget.flipBackgroundColors),
                        buttonCenter: widgetCenter(hereIconKey),
                        iconOriginKey: iconKey,
                      ),
                    );
                  },
                  contentPadding: listItemPadding,
                );
              }),
              // ---------------
              // Divider(indent: 22, endIndent: 22, height: 34),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: SeparatorGradient(
                    color:
                        MakoThemeData.fromContext(context).lowestIndentColor),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 0.0, bottom: 3.0),
                child: Text('Extra',
                    style: theme.textTheme.bodyMedium!
                        .copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
              ),
              Builder(builder: (context) {
                final GlobalKey iconKey = GlobalKey();
                Offset? tapPosition;
                return GestureDetector(
                  onTapDown: (details) {
                    tapPosition = details.globalPosition;
                  },
                  child: ListTile(
                    title: Text('Crank game', style: theme.textTheme.bodyLarge),
                    subtitle: Text(
                      "This is a game that came to me in a dream while I was making this timer app. I kind of hate it. It's about time, though, it's about the virtues of clocks.",
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: trailing(SizedBox(
                      width: 26,
                      height: 26,
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
                    )),
                    onTap: () {
                      Navigator.push(
                        context,
                        CircularRevealRoute(
                          builder: (context) => CrankGameScreen(
                              iconKey: iconKey,
                              flipBackgroundColors:
                                  !widget.flipBackgroundColors),
                          buttonCenter: tapPosition ?? Offset.zero,
                          iconOriginKey: iconKey,
                        ),
                      );
                    },
                    contentPadding: listItemPadding,
                  ),
                );
              }),

              ListTile(
                title:
                    Text('Journeying game', style: theme.textTheme.bodyLarge),
                subtitle: Text(
                  "A world to wander.",
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: trailing(Icon(
                  Icons.explore_rounded,
                  color: theme.colorScheme.primary,
                  size: 24,
                )),
                onTap: () {
                  Navigator.pushReplacement(
                    context,
                    CircularRevealRoute(
                      builder: (context) => const JourneyingGameScreen(),
                    ),
                  );
                },
                contentPadding: listItemPadding,
              ),

              // if (!completedSetup) ...[
              if (true) ...[
                setupTile,
              ],
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ]),
          ),
        ],
      ),
    );
  }
}

class ThankAuthorScreen extends StatelessWidget {
  final bool flipBackgroundColors;
  const ThankAuthorScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, flipBackgroundColors);
    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                      width: 32,
                      height: 32,
                      child: Hero(
                        tag: 'thank-author-icon',
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.heart_broken,
                          color: theme.colorScheme.primary,
                        )),
                      )),
                  SizedBox(width: 16),
                  Text('Thank the author',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: backgroundColorB,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverList(
            delegate: SliverChildListDelegate(
              [
                Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Text(
                      'The audience for this app is large. Even a small payment in total would enable the author to go on to create much more ambitious projects.',
                      style: theme.textTheme.bodyLarge,
                    )),
                SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  final bool flipBackgroundColors;
  const AboutScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, flipBackgroundColors);
    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                    width: 35,
                    height: 35,
                    child: Hero(
                        tag: 'about-icon',
                        child: ScalingAspectRatio(
                            child: Icon(
                          Icons.info_outline,
                          color: theme.colorScheme.primary,
                        ))),
                  ),
                  SizedBox(width: 9),
                  Text("About Mako's Timer",
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: backgroundColorB,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          SliverPadding(
            padding: EdgeInsets.all(24.0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                SizedBox(height: 24),
                Text(
                  "This was made over the span of many months of work and through much experimentation.",
                  style: theme.textTheme.bodyMedium,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class AlarmSoundPickerScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  const AlarmSoundPickerScreen(
      {super.key, this.iconKey, this.flipBackgroundColors = false});
  final GlobalKey? iconKey;

  @override
  State<AlarmSoundPickerScreen> createState() => _AlarmSoundPickerScreenState();
}

class _AlarmSoundPickerScreenState extends State<AlarmSoundPickerScreen>
    with SignalsMixin, TickerProviderStateMixin {
  List<AudioInfo>? _alarmSounds;
  List<AudioInfo>? _notificationSounds;
  List<AudioInfo>? _ringtoneSounds;
  final List<AudioInfo> _assetSounds = PlatformAudio.assetSounds;
  late Function() listeningAudioEffectChange;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSounds();
    listeningAudioEffectChange =
        Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType())
            .subscribe((event) {
      Mobj.getAlreadyLoaded(hasSelectedAudioID, BoolType()).value = true;
    });
  }

  @override
  void dispose() {
    listeningAudioEffectChange();
    super.dispose();
  }

  Future<void> _loadSounds() async {
    try {
      if (platformIsDesktop()) {
        setState(() {
          _loading = false;
        });
        return;
      } else {
        final alarmsFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.alarm);
        final notificationsFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.notification);
        final ringtonesFuture =
            PlatformAudio.getPlatformAudio(PlatformAudioType.ringtone);
        final [alarms, notifications, ringtones] = await Future.wait([
          alarmsFuture,
          notificationsFuture,
          ringtonesFuture,
        ]);
        setState(() {
          _alarmSounds = alarms;
          _notificationSounds = notifications;
          _ringtoneSounds = ringtones;
          _loading = false;
        });
      }
    } catch (e) {
      print('Error loading sounds: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (backgroundColorA, backgroundColorB) =
        maybeFlippedBackgroundColors(theme, widget.flipBackgroundColors);

    Widget section(String title, List<AudioInfo> sounds,
        {Duration? fadeDelay}) {
      final animDuration = Duration(milliseconds: 100);
      final totalDuration =
          fadeDelay != null ? fadeDelay + animDuration : animDuration;
      final delayFraction = fadeDelay != null
          ? fadeDelay.inMicroseconds / totalDuration.inMicroseconds
          : 0.0;

      final selectedAudio =
          Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType());
      final jukeBox = Provider.of<JukeBox>(context, listen: false);

      Widget radioSelector(AudioInfo audio) {
        bool hasPlayed = false;
        return RadioItem<AudioInfo?>(
          equalityComparison: (AudioInfo? a, AudioInfo? b) => a?.url == b?.url,
          me: audio,
          selection: selectedAudio,
          onTap: () {
            jukeBox.pauseAudio();
            if (selectedAudio.value?.url != audio.url) {
              hasPlayed = false;
            }
            if (!hasPlayed) {
              jukeBox.playAudio(audio);
            }
            hasPlayed = !hasPlayed;
          },
          builder: (context, isOn) {
            final textTheme = isOn
                ? theme.textTheme.bodyMedium!
                    .copyWith(color: theme.colorScheme.onPrimary)
                : theme.textTheme.bodyMedium!;
            final backgroundColor = isOn
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerLowest;
            return Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(audio.name, style: textTheme));
          },
        );
      }

      return SliverToBoxAdapter(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: totalDuration,
          curve: Interval(delayFraction, 1.0, curve: Curves.linear),
          builder: (context, value, child) =>
              Opacity(opacity: value, child: child!),
          child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                        padding: EdgeInsets.fromLTRB(0, 0, 0, 7),
                        child: Text(title,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: theme.colorScheme.primary))),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: sounds
                            .map((audio) => radioSelector(audio))
                            .toList()),
                  ])),
        ),
      );
    }

    return Scaffold(
      backgroundColor: backgroundColorA,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: halfScreenHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              expandedTitleScale: 1.0,
              title: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Hero(
                      tag: 'alarm-sound-icon',
                      createRectTween: (begin, end) =>
                          DelayedRectTween(begin: begin, end: end, delay: 0.14),
                      child: ScalingAspectRatio(
                          child: Icon(
                        Icons.music_note,
                        color: theme.colorScheme.primary,
                      )),
                    ),
                  ),
                  SizedBox(width: 16),
                  Text('Alarm sound',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
              titlePadding: EdgeInsetsDirectional.only(
                start: 72.0,
                bottom: 16.0,
              ),
            ),
            backgroundColor: backgroundColorB,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
          ),
          if (!_loading) ...[
            if (_assetSounds.isNotEmpty)
              section("Our Sounds", _assetSounds,
                  fadeDelay: Duration(milliseconds: 0)),
            if (_notificationSounds != null && _notificationSounds!.isNotEmpty)
              section('Phone Notification Sounds', _notificationSounds!,
                  fadeDelay: Duration(milliseconds: 200)),
            if (_alarmSounds != null && _alarmSounds!.isNotEmpty)
              section('Phone Alarm Sounds (long duration)', _alarmSounds!,
                  fadeDelay: Duration(milliseconds: 100)),
            if (_ringtoneSounds != null && _ringtoneSounds!.isNotEmpty)
              section('Your Ringtones', _ringtoneSounds!,
                  fadeDelay: Duration(milliseconds: 300)),
            SliverToBoxAdapter(
              child:
                  SizedBox(height: 16 + MediaQuery.of(context).padding.bottom),
            ),
          ],
        ],
      ),
    );
  }
}

Future<bool> hasBackgroundPermission() {
  if (Platform.isAndroid) {
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } else if (Platform.isIOS) {
    // iOS does not allow persistent background execution for timers.
    return Future.value(false);
  } else {
    // Other platforms (web, desktop) do not support background execution for this app.
    return Future.value(false);
  }
}

class OnboardScreen extends StatefulWidget {
  /// whether it's kind of the root screen, which is the case when it's the first run. in this case, it has to do something special before it pops, creating the TimerScreen. If it's not rootal, then a new timer screen would likely be a duplicate and cause problems.
  final bool isRootal;
  const OnboardScreen({super.key, this.isRootal = false});

  @override
  State<OnboardScreen> createState() => _OnboardScreenState();
}

const double standardSpacing = 18;
const spacer = SizedBox(width: standardSpacing, height: standardSpacing);
const double standardButtonHeight = 80;
const double buttonCornerRadius = 16;

class _OnboardScreenState extends State<OnboardScreen> with SignalsMixin {
  late ScrollController _scrollController;
  late Signal<bool?> setIsRightHanded = Signal(null);
  final GlobalKey handednessKey = GlobalKey();
  final GlobalKey skipKey = GlobalKey();
  final GlobalKey padKey = GlobalKey();
  final GlobalKey ringModeKey = GlobalKey();
  late List<GlobalKey> allKeys = [
    handednessKey,
    padKey,
    ringModeKey,
    if (Platform.isAndroid) notifKey,
    if (Platform.isAndroid) batteryOptimKey,
    skipKey
  ];
  late Signal<bool?> numpadOrientation = Signal(null);
  late Signal<bool?> ringMode = Signal(null);
  late List<Signal<dynamic>> allChoices = [
    setIsRightHanded,
    numpadOrientation,
    ringMode,
    if (Platform.isAndroid) notifGranted,
    if (Platform.isAndroid) batteryOptimGranted
  ];
  late Signal<bool> allChoicesCompleted = Signal(false);
  async.Timer? autoMoveOn;
  late Signal<bool?> notifGranted = Signal(null);
  bool _notifWasAlreadyGranted = false;
  final GlobalKey notifKey = GlobalKey();
  late Signal<bool?> batteryOptimGranted = Signal(null);
  bool _batteryOptimWasAlreadyGranted = false;
  final GlobalKey batteryOptimKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final isRightHanded = Mobj.getAlreadyLoaded(isRightHandedID, BoolType());
    createEffect(() {
      if (setIsRightHanded.value != null) {
        isRightHanded.value = setIsRightHanded.value!;
      }
    });
    createEffect(() {
      if (numpadOrientation.value != null) {
        Mobj.getAlreadyLoaded(padVerticallyAscendingID, BoolType()).value =
            numpadOrientation.value!;
      }
    });
    createEffect(() {
      if (ringMode.value != null) {
        Mobj.getAlreadyLoaded(persistentAlarmModeID, BoolType()).value =
            ringMode.value!;
      }
    });
    //when all choices are non-null, navigate away
    createEffect(() {
      if (allChoices.every((signal) => signal.value != null)) {
        // redundant but might as well set it as soon as possible, may change it later to only set exit in moveOn
        Mobj.getAlreadyLoaded(completedSetupID, BoolType()).value = true;
        // final messenger = globalScaffoldMessengerKey.currentState!;
        // tombstone, wanted to have a "setup completed" then "enjoy the app" tweened message, but snackbars can't retain state between route transitions: https://github.com/flutter/flutter/issues/180212
        // final messenger = ScaffoldMessenger.of(context);
        // messenger.showSnackBar(
        //   SnackBar(
        //     content: const Text('Setup completed'),
        //     duration: Duration(seconds: 3),
        //   ),
        // );
        // autoMoveOn = async.Timer(Duration(milliseconds: 1000), () => on());
        allChoicesCompleted.value = true;
      }
    });
    _scrollController = ScrollController();
    if (Platform.isAndroid) {
      _checkNotificationPermission();
      _checkBatteryOptimization();
    }
  }

  Future<void> _checkNotificationPermission() async {
    final status = await FlutterForegroundTask.checkNotificationPermission();
    final granted = status == NotificationPermission.granted;
    _notifWasAlreadyGranted = granted;
    notifGranted.value = granted ? true : null;
  }

  Future<void> _requestNotificationPermission() async {
    final result = await FlutterForegroundTask.requestNotificationPermission();
    notifGranted.value = result == NotificationPermission.granted ? true : null;
    if (result == NotificationPermission.granted) {
      inputCompleted(notifKey);
    }
  }

  Future<void> _checkBatteryOptimization() async {
    final granted = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    _batteryOptimWasAlreadyGranted = granted;
    batteryOptimGranted.value = granted ? true : null;
  }

  Future<void> _requestBatteryOptimization() async {
    final granted =
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    batteryOptimGranted.value = granted ? true : null;
    if (granted) {
      inputCompleted(batteryOptimKey);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    setIsRightHanded.dispose();
    numpadOrientation.dispose();
    ringMode.dispose();
    allChoicesCompleted.dispose();
    notifGranted.dispose();
    batteryOptimGranted.dispose();
    super.dispose();
  }

  void _scrollTo(GlobalKey key) {
    // Scrollable.ensureVisible(
    //   key.currentContext!,
    //   duration: const Duration(milliseconds: 700),
    //   alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    //   curve: Interval(0.4, 1.0, curve: Curves.easeInOutCubic),
    // );
    boring.scrollToWithPadding(key.currentContext!, _scrollController);
  }

  void inputCompleted(GlobalKey key) {
    // If all choices are non-null, navigate away
    int idx = allKeys.indexOf(key);
    if (idx != -1) {
      while (idx < allKeys.length - 1) {
        idx += 1;
        if (allChoices.elementAtOrNull(idx)?.value == null) {
          break;
        }
      }
      _scrollTo(allKeys[idx]);
    }
  }

  void moveOn() {
    autoMoveOn?.cancel();
    autoMoveOn = null;
    // time should be the same as the interval delay in _scrollTo
    async.Timer(Duration(milliseconds: (0.4 * 700).round()), () {
      final navigator = Navigator.of(context);
      if (widget.isRootal) {
        final currentRoute = ModalRoute.of(context)!;
        // we're now ready to create timerscreen, replace the blank placeholder below us with it
        navigator.replaceRouteBelow(
          anchorRoute: currentRoute,
          newRoute: CircularRevealRoute(
            builder: (context) => TimerScreen(),
          ),
        );
      }
      navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final backgroundColor = theme.colorScheme.surfaceContainerLow;
    final isRightHanded = Mobj.getAlreadyLoaded(isRightHandedID, BoolType());
    const buttonAnimationDuration = Duration(milliseconds: 270);

    Widget handButton({
      required bool isRight,
    }) {
      return Expanded(
        child: RadioItem<bool?>(
          selection: setIsRightHanded,
          duration: buttonAnimationDuration,
          me: isRight,
          onTap: () => inputCompleted(handednessKey),
          builder: (context, isOn) {
            final leftHand = Transform.rotate(
              angle: 1 / 8 * tau,
              child: Icon(Icons.back_hand_rounded,
                  size: 36, color: foregroundColorFor(theme, isOn)),
            );
            final rightHand = Transform.scale(
              scaleX: -1,
              child: leftHand,
            );
            return Container(
              height: standardButtonHeight,
              decoration: BoxDecoration(
                color: backgroundColorFor(theme, isOn),
                borderRadius: BorderRadius.circular(buttonCornerRadius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: isRight
                    ? [
                        Text('right',
                            style: theme.textTheme.titleMedium!.copyWith(
                                color: foregroundColorFor(theme, isOn))),
                        spacer,
                        rightHand,
                      ]
                    : [
                        leftHand,
                        spacer,
                        Text('left',
                            style: theme.textTheme.titleMedium!.copyWith(
                                color: foregroundColorFor(theme, isOn))),
                      ],
              ),
            );
          },
        ),
      );
    }

    Widget numpadForSetup(bool isAscending) {
      return RadioItem<bool?>(
        selection: numpadOrientation,
        duration: buttonAnimationDuration,
        onTap: () => inputCompleted(padKey),
        me: isAscending,
        builder: (context, isOn) {
          final theme = Theme.of(context);
          const double gap = 16;
          final double diameter = 132;
          return Container(
            width: diameter,
            height: diameter,
            padding: EdgeInsets.all(gap),
            decoration: BoxDecoration(
              color: backgroundColorFor(theme, isOn),
              borderRadius: BorderRadius.circular(buttonCornerRadius),
            ),
            child: _NumpadTypeIndicator(
              isAscending: isAscending,
              color: foregroundColorFor(theme, isOn),
              width: 132 - 2 * gap,
            ),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Handedness selection - full screen
          SliverToBoxAdapter(
              key: handednessKey,
              child: Container(
                  height: screenHeight,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                  ),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                            padding: EdgeInsets.all(standardSpacing),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                            ),
                            child: Text("Setup",
                                style: theme.textTheme.titleLarge)),
                        Container(
                            padding: EdgeInsets.all(standardSpacing),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                            ),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Are you left or right-handed?',
                                      style: theme.textTheme.bodyMedium!),
                                  SizedBox(height: standardSpacing),
                                  Row(
                                    children: [
                                      handButton(
                                        isRight: false,
                                      ),
                                      spacer,
                                      handButton(
                                        isRight: true,
                                      ),
                                    ],
                                  )
                                ]))
                      ]))),
          SliverToBoxAdapter(
              key: padKey,
              child: Container(
                  padding: EdgeInsets.all(
                    standardSpacing,
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text("Which kind of numpad is more familiar to you?",
                            style: theme.textTheme.bodyMedium!),
                        spacer,
                        Watch((context) {
                          return AnimatedAlign(
                            duration: Duration(milliseconds: 340),
                            curve: Curves.easeInOutCubic,
                            alignment: isRightHanded.value == true
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Column(
                                children: [
                                  Text(
                                    "phone style",
                                    style: theme.textTheme.bodyMedium!,
                                  ),
                                  spacer,
                                  numpadForSetup(
                                    false,
                                  ),
                                ],
                              ),
                              spacer,
                              Column(
                                children: [
                                  Text(
                                    "calculator style",
                                    style: theme.textTheme.bodyMedium!,
                                  ),
                                  spacer,
                                  numpadForSetup(
                                    true,
                                  ),
                                ],
                              ),
                            ]),
                          );
                        })
                      ]))),
          SliverToBoxAdapter(
              key: ringModeKey,
              child: Padding(
                  padding: EdgeInsets.all(standardSpacing),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            """Are you forgetful or absentminded? You may want to set this to "require acknowledgement", to make it so that alarms keep ringing until you interact with them to confirm that you heard them.
Otherwise, if you generally pay close attention to your phone, it's much more convenient to have it set to "ring once".""",
                            style: theme.textTheme.bodyMedium!),
                        SizedBox(height: standardSpacing),
                        Row(
                          children: [
                            Flexible(flex: 20, child: Container()),
                            Flexible(
                              flex: 50,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    RadioItem<bool?>(
                                      selection: ringMode,
                                      duration: buttonAnimationDuration,
                                      me: true,
                                      onTap: () => inputCompleted(ringModeKey),
                                      builder: (context, isOn) => Container(
                                        height: standardButtonHeight,
                                        decoration: BoxDecoration(
                                          color:
                                              backgroundColorFor(theme, isOn),
                                          borderRadius: BorderRadius.circular(
                                              buttonCornerRadius),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 22.0),
                                          child: Center(
                                            child: Text(
                                                textAlign: TextAlign.center,
                                                'require acknowledgement',
                                                style: theme
                                                    .textTheme.titleMedium!
                                                    .copyWith(
                                                        color:
                                                            foregroundColorFor(
                                                                theme, isOn))),
                                          ),
                                        ),
                                      ),
                                    ),
                                    spacer,
                                    RadioItem<bool?>(
                                      selection: ringMode,
                                      duration: buttonAnimationDuration,
                                      me: false,
                                      onTap: () => inputCompleted(ringModeKey),
                                      builder: (context, isOn) => Container(
                                        height: standardButtonHeight,
                                        decoration: BoxDecoration(
                                          color:
                                              backgroundColorFor(theme, isOn),
                                          borderRadius: BorderRadius.circular(
                                              buttonCornerRadius),
                                        ),
                                        child: Center(
                                          child: Text('ring once',
                                              style: theme
                                                  .textTheme.titleMedium!
                                                  .copyWith(
                                                      color: foregroundColorFor(
                                                          theme, isOn))),
                                        ),
                                      ),
                                    ),
                                  ]),
                            ),
                          ],
                        ),
                      ]))),
          if (Platform.isAndroid)
            SliverToBoxAdapter(
                key: notifKey,
                child: Padding(
                    padding: EdgeInsets.all(standardSpacing),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: reverseIfNot(isRightHanded.value ?? true, [
                          Flexible(
                              child: Text('Enable notifications permission',
                                  style: theme.textTheme.bodyMedium!)),
                          spacer,
                          Flexible(
                            child: Watch((context) {
                              final granted = notifGranted.value;
                              final isOn = granted == true;
                              final label = granted == null
                                  ? 'request'
                                  : granted
                                      ? (_notifWasAlreadyGranted
                                          ? 'already granted'
                                          : 'granted')
                                      : 'request';
                              return InkButton(
                                backgroundColor:
                                    backgroundColorFor(theme, isOn),
                                onTap: granted == true
                                    ? null
                                    : _requestNotificationPermission,
                                borderRadius:
                                    BorderRadius.circular(buttonCornerRadius),
                                child: SizedBox(
                                  height: standardButtonHeight,
                                  child: Center(
                                      child: Text(label,
                                          style: theme.textTheme.titleMedium!
                                              .copyWith(
                                                  color: foregroundColorFor(
                                                      theme, isOn)))),
                                ),
                              );
                            }),
                          ),
                        ])))),
          if (Platform.isAndroid)
            SliverToBoxAdapter(
                key: batteryOptimKey,
                child: Padding(
                    padding: EdgeInsets.all(standardSpacing),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: reverseIfNot(isRightHanded.value ?? true, [
                          Flexible(
                              child: Text(
                                  'Give permission to run in background / Prevent android from randomly killing the app even if timers are running',
                                  style: theme.textTheme.bodyMedium!)),
                          spacer,
                          Flexible(
                            child: Watch((context) {
                              final granted = batteryOptimGranted.value;
                              final isOn = granted == true;
                              final label = granted == null
                                  ? 'request'
                                  : granted
                                      ? (_batteryOptimWasAlreadyGranted
                                          ? 'already granted'
                                          : 'granted')
                                      : 'request';
                              return InkButton(
                                backgroundColor:
                                    backgroundColorFor(theme, isOn),
                                onTap: granted == true
                                    ? null
                                    : _requestBatteryOptimization,
                                borderRadius:
                                    BorderRadius.circular(buttonCornerRadius),
                                child: SizedBox(
                                  height: standardButtonHeight,
                                  child: Center(
                                      child: Text(label,
                                          style: theme.textTheme.titleMedium!
                                              .copyWith(
                                                  color: foregroundColorFor(
                                                      theme, isOn)))),
                                ),
                              );
                            }),
                          ),
                        ])))),
          // Skip button - full screen
          SliverToBoxAdapter(
              key: skipKey,
              child: Padding(
                padding: EdgeInsets.all(standardSpacing),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    // this looked kinda nice, but it was confusing, and wouldn't feel good for left handers
                    // if (allChoicesCompleted.value) ...[
                    //   Text('done'),
                    //   spacer
                    // ],
                    Expanded(
                      child: InkButton(
                          onTap: () {
                            moveOn();
                          },
                          borderRadius:
                              BorderRadius.circular(buttonCornerRadius),
                          builder: (context, isOn) => Container(
                                color:
                                    backgroundColorFor(Theme.of(context), isOn),
                                child: SizedBox(
                                  height: standardButtonHeight,
                                  child: Center(
                                      child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                        Watch(
                                          (context) => Text(
                                              allChoicesCompleted.value
                                                  ? 'setup complete, click to continue'
                                                  : 'skip setup',
                                              style: theme
                                                  .textTheme.titleMedium!
                                                  .copyWith(
                                                      color: foregroundColorFor(
                                                          Theme.of(context),
                                                          isOn))),
                                        ),
                                      ])),
                                ),
                              )),
                    ),
                  ],
                ),
              )),
          SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.of(context).padding.bottom)),
        ],
      ),
    );
  }
}
