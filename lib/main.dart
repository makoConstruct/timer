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
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
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
// import 'package:makos_timer/journeying_game.dart';
import 'package:makos_timer/database.dart';
import 'package:makos_timer/size_reporter.dart';
import 'package:makos_timer/mobj.dart';
import 'package:makos_timer/type_help.dart';
import 'package:provider/provider.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
import 'package:animove/animove.dart';
import 'package:signals/signals_flutter.dart';
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

const double defaultTimerOutline = 7;
const double timerGap = 11;
// might make this user-configurable
final Signal<double> timerWidgetRadius = Signal(25);

const double standardLineWidth = 6;

final GlobalKey<ScaffoldMessengerState> globalScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey configButtonKey = GlobalKey();

const backingCornerRounding = 0.37;
const backingDeflationProportion = 0.07;

/// A common thickness for thick lines
const makoLineThickness = 8.0;

Widget fittedPlayIcon(color) => PaintedPlayIcon(size: 10, color: color);

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
  final fversion = Mobj.getOrCreate(
    dbVersionID,
    type: IntType(),
    initial: () => 0,
    debugLabel: "version",
  );
  await Future.wait(<Future>[
    // we know that the data required for the app is minimal enough that we should wait until it's loaded before showing anything... idk not sure I believe this
    Mobj.getOrCreate(
      timerListID,
      type: ListType(StringType()),
      initial: () => <MobjID>[],
    ),
    Mobj.getOrCreate(
      transientTimerListID,
      type: ListType(StringType()),
      initial: () => <MobjID>[],
    ),
    Mobj.getOrCreate(
      binListID,
      type: ListType(StringType()),
      initial: () => <MobjID>[],
    ),
    Mobj.getOrCreate(nextHueID, type: DoubleType(), initial: () => 0.252),
    Mobj.getOrCreate(
      isRightHandedID,
      type: BoolType(),
      initial: () => true,
      debugLabel: "is right handed",
    ),
    Mobj.getOrCreate(
      padVerticallyAscendingID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "pad vertically ascending",
    ),
    Mobj.getOrCreate(
      padLandscapeID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "pad landscape",
    ),
    Mobj.getOrCreate(
      selectedAudioID,
      type: AudioInfoType(),
      initial: () => PlatformAudio.assetSounds[0],
      debugLabel: "selected audio",
    ),
    Mobj.getOrCreate(
      hasSelectedAudioID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "has selected audio",
    ),
    Mobj.getOrCreate(
      persistentAlarmModeID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "persistent alarm mode",
    ),
    Mobj.getOrCreate(
      timeFirstUsedApp,
      type: DateTimeType(),
      initial: () => DateTime.now(),
      debugLabel: "first used app",
    ),
    Mobj.getOrCreate(
      hasCreatedTimerID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "has created timer",
    ),
    Mobj.getOrCreate(
      exitedSetupID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "left setup",
    ),
    Mobj.getOrCreate(
      completedSetupID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "completed setup",
    ),
    Mobj.getOrCreate(
      buttonSpanID,
      type: DoubleType(),
      initial: () => 64.0,
      debugLabel: "button span",
    ),
    Mobj.getOrCreate(
      buttonScaleDialOnID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "button scale dial on",
    ),
    Mobj.getOrCreate(
      crankGameWinMessageIndexID,
      type: IntType(),
      initial: () => 0,
      debugLabel: "crank game win message index",
    ),
    Mobj.getOrCreate(
      usedDragActionRecordID,
      type: IntType(),
      initial: () => 0,
      debugLabel: "used drag action count",
    ),
    Mobj.getOrCreate(
      usedMenuCountID,
      type: IntType(),
      initial: () => 0,
      debugLabel: "used menu count",
    ),
    Mobj.getOrCreate(
      hintGetsCompositeTimersID,
      type: BoolType(),
      initial: () => false,
      debugLabel: "has created cycle timer",
    ),
    Mobj.getOrCreate(
      numberOfTimersCreatedID,
      type: IntType(),
      initial: () => 0,
      debugLabel: "number of timers created",
    ),
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
        notificationResponseReceivePort!.sendPort,
        mainNotificationPortName,
      );
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
    }),
  ]);
  runApp(const TimersApp());
}

void _sendDismissAlarms() {
  IsolateNameServer.lookupPortByName(
    mainNotificationPortName,
  )?.send('dismissAlarms');
  IsolateNameServer.lookupPortByName(
    foregroundServicePortName,
  )?.send('dismissAlarms');
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
  TimerHolm({
    required this.list,
    required this.jukeBox,
    bool dismissOnForeground = true,
  }) {
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

  AudioInfo _audioForTimer(TimerData d) =>
      d.soundEffect ??
      Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType()).value!;

  void _timerStartAlarm(TimerTrack tt, Mobj<TimerData> mobj) {
    tt.startAlarmTimer = null;
    vibrateAlertOnce();
    jukeBox.playAudio(_audioForTimer(mobj.peek()!));
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
      final audio = _audioForTimer(d);
      final persistentAlarmMode =
          Mobj.getAlreadyLoaded(persistentAlarmModeID, BoolType()).value ??
          false;
      if (isBackgrounded.peek() && (d.persistentAlarm ?? persistentAlarmMode)) {
        // then it needs to send a notification and scream repeatedly until acknowledged
        jukeBox.playAudioLooping(audio);
        mobj.value = d
            .withRunningState(TimerData.completed)
            .withChanges(isGoingOff: true);
        tt.vibrationRepeatTimer?.cancel();
        tt.vibrationRepeatTimer = async.Timer.periodic(
          const Duration(seconds: 8),
          (_) => vibrateAlertOnce(),
        );
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

    final parentMobj = Mobj.seekTypedAlreadyLoaded(
      child!.parentId!,
      TimerDataType(),
    );
    // if the parent isn't a timer, can't be actuated
    if (parentMobj == null) return;
    TimerData parent = parentMobj.peek()!;

    switch (parent.kind) {
      case TimerKind.series:
      case TimerKind.loop:
        final childIdx = parent.children.indexOf(childMobj.id);
        while (true) {
          final nextIdx = (childIdx + 1) % parent.children.length;
          if (parent.kind != TimerKind.loop && nextIdx == 0) {
            parentMobj.value = parent.withChanges(
              runningState: TimerData.completed,
              completedRecently: true,
            );
            return returnAndContinueParent(parentMobj);
          } else {
            bool timerComplete = startTimer(
              parentMobj,
              reset: false,
              suggestedStart: nextIdx,
            );
            if (!timerComplete) {
              return;
            } else if (nextIdx == childIdx) {
              // breaks out of instant loops
              parentMobj.value = parent.withChanges(
                runningState: TimerData.completed,
                completedRecently: true,
              );
              return returnAndContinueParent(parentMobj);
            }
          }
        }
      case TimerKind.parallelStartJustified:
        final allCompleted = parent.children.every(
          (id) =>
              Mobj.getAlreadyLoaded(id, TimerDataType()).peek()?.isCompleted ??
              false,
        );
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
    TimerTrack tt,
    Mobj<TimerData> mobj,
    JukeBox jukeBox,
  ) {
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
        final parent = Mobj.seekTypedsAlreadyLoaded(prev!.parentId!, [
          TimerDataType(),
          ListType(StringType()),
        ]);
        if (parent != null && parent.peek() != null) {
          writeBackChildren(
            parent,
            childrenOf(parent).toList()..remove(mobj.id),
          );
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
                  microseconds: (totalDuration(d) * 1000000).round(),
                );
                final elapsed = DateTime.now().difference(d.startTime);
                if (d.soundsOnStart) {
                  // fire start alarm when startTime arrives (startTime is in the future by the delay)
                  final timeUntilStart = d.startTime.difference(DateTime.now());
                  tt.startAlarmTimer = async.Timer(
                    timeUntilStart.isNegative ? Duration.zero : timeUntilStart,
                    () => _timerStartAlarm(tt, mobj),
                  );
                }
                tt.completionTimer = async.Timer(
                  Duration(
                    milliseconds: (total - elapsed).inMilliseconds.ceil(),
                  ),
                  () => _timerGoesOff(tt, mobj),
                );
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
                  microseconds: (totalDuration(d) * 1000000).round(),
                );
                final elapsed = DateTime.now().difference(d.startTime);
                tt.completionTimer = async.Timer(
                  Duration(
                    milliseconds: (total - elapsed).inMilliseconds.ceil(),
                  ),
                  () => _timerGoesOff(tt, mobj),
                );
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
    completedRecently: false,
  );
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
bool startTimer(
  Mobj<TimerData> mobj, {
  bool reset = false,
  Duration? delay,
  int suggestedStart = 0,
}) {
  print("starting timer ${mobj.id}");
  if (reset) {
    resetTimer(mobj.id);
  }
  final d = mobj.peek()!;
  _startAncestors(d.parentId);
  if (d.isComposite) {
    bool ret = _startChildren(d, delay: delay, suggestedStart: suggestedStart);
    mobj.value = d.withRunningState(
      ret ? TimerData.completed : TimerData.running,
    );
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
              'Invalid timer state: ${child.peek()!.runningState}',
            );
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
            .map(
              (childId) => remainingTimerDuration(
                Mobj.seekAlreadyLoaded(childId, TimerDataType())?.peek(),
              ),
            )
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
            alreadyCompleted =
                _startSingle(
                  Mobj.getAlreadyLoaded(host.children[i], TimerDataType()),
                  delay: innerDelay,
                ) &&
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
        'Invalid timer kind: ${host.kind}, _startChildren should only be passed composite timers',
      );
  }
}

bool _startSingle(Mobj<TimerData> mobj, {Duration? delay}) {
  final data = mobj.peek()!;
  if (data.isRunning) return false;
  if (data.isComposite) {
    bool r = _startChildren(data, delay: delay);
    mobj.value = data.withRunningState(
      r ? TimerData.completed : TimerData.running,
    );
    return r;
  } else {
    if ((delay == null || delay == Duration.zero) &&
        data.duration <= Duration.zero) {
      mobj.value = data.withRunningState(TimerData.completed);
      return true;
    }
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
      if (!pp.children.any(
        (id) => Mobj.getAlreadyLoaded(id, TimerDataType()).peek()!.isRunning,
      )) {
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
  if (d.parentId == null) {
    return true;
  }
  final parent = Mobj.seekTypedAlreadyLoaded(d.parentId!, TimerDataType());
  if (parent == null) {
    return true;
  }
  return trivialAndClearable(parent, null);
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
          create: (context) => Thumbspan(lpixPerThumbspan(context)),
        ),
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
            return CircularRevealRoute(builder: (context) => TimerScreen());
          }
          if (settings.name == '/onboard') {
            return CircularRevealRoute(
              builder: (context) => OnboardScreen(),
              iconOriginKey: configButtonKey,
            );
          }
          // abandoned on journey_game branch
          // if (settings.name == '/journeying') {
          //   return CircularRevealRoute(
          //     builder: (context) => const JourneyingGameScreen(),
          //   );
          // }
          return null;
        },
        onGenerateInitialRoutes: (initialRouteName) {
          // if (initialRouteName == '/journeying') {
          //   return <Route<dynamic>>[
          //     CircularRevealRoute(
          //       builder: (context) => const JourneyingGameScreen(),
          //     ),
          //   ];
          // }
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
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                ),
                transitionDuration: Duration.zero,
              ),
              CircularRevealRoute(
                builder: (context) => OnboardScreen(isRootal: true),
                reverseTransitionDuration: Duration(milliseconds: 350),
                iconOriginKey: configButtonKey,
              ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        const double margin = 12;
        final theme = Theme.of(context);
        final mt = MakoThemeData.fromTheme(theme);
        final backgroundColor = this.backgroundColor ?? mt.foreBackColor;
        final buttonSpan = Mobj.getAlreadyLoaded(
          buttonSpanID,
          DoubleType(),
        ).value!;
        Offset tentativeArrowCenter = topLeftManhattanCenter(centerOn);
        // correct arrowCenter to make sure it's not too close to either side
        final minDistanceFromSide =
            margin + backingCornerRounding * buttonSpan + arrowHeight;
        final arrowCenter = Offset(
          clampDouble(
            tentativeArrowCenter.dx,
            minDistanceFromSide,
            constraints.maxWidth - minDistanceFromSide,
          ),
          tentativeArrowCenter.dy,
        );
        final width = min(
          estimatedWidth ?? buttonSpan * 3.8,
          constraints.maxWidth - margin * 2,
        );
        final left = min(
          max(margin, arrowCenter.dx - width / 2),
          constraints.maxWidth - margin - width,
        );
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
            return Stack(
              children: [
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
                        opacity: Curves.easeInOut.transform(
                          unlerpUnit(0.37, 1, p),
                        ),
                        child: Column(children: items.toList()),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
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
    final arrowProgress = Curves.easeOut.transform(
      unlerpUnit(0.15, 0.7, progress),
    );

    final lerpr = RRect.lerp(
      RRect.fromRectAndRadius(
        Rect.fromCircle(center: origin, radius: 0),
        Radius.circular(lerp(size.width / 2, cornerRounding, progress)),
      ),
      targetRect,
      progress,
    )!;

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
      arrowPath.relativeArcToPoint(
        Offset(basew, -basew),
        radius: Radius.circular(basew),
        rotation: pi / 2,
        clockwise: false,
      );
      arrowPath.relativeLineTo(0, additionalHeight);
      arrowPath.relativeArcToPoint(
        Offset(stemw, 0),
        radius: Radius.circular(stemw / 2),
        rotation: pi,
        clockwise: true,
      );
      arrowPath.relativeLineTo(0, -additionalHeight);
      arrowPath.relativeArcToPoint(
        Offset(basew, basew),
        radius: Radius.circular(basew),
        rotation: pi / 2,
        clockwise: false,
      );
      arrowPath.close();
    }

    return Path.combine(
      PathOperation.union,
      Path()..addRRect(lerpr),
      arrowPath,
    );
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
  static const Duration _deletionAnimationDuration = Duration(
    milliseconds: 270,
  );
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

  late final Signal<double> depth = Signal(0.0);
  void Function()? _parentDepthDispose;

  /// added to the parent Timercule's depth to derive this widget's depth.
  /// Timercule nests (1.0); Timer mirrors its parent (0.0).
  double get depthOffset => 0.0;

  void _subscribeToParentDepth() {
    _parentDepthDispose?.call();
    final parent = context.findAncestorStateOfType<TimerculeState>();
    if (parent != null) {
      _parentDepthDispose = effect(() {
        depth.value = parent.depth.value + depthOffset;
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
      duration: const Duration(milliseconds: 180),
      vsync: this,
    );
    if (widget.animateIn) {
      _appearanceAnimation.forward();
    } else {
      _appearanceAnimation.value = 1;
    }
    _unpinnedIndicatorShowing = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _unpinnedIndicatorFullyShowing = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    onInitState();
    createEffect(() {
      final TimerData? d = widget.mobj.value;
      if (d == null) {
        // move this widget into a transient overlay deletion animation, and trust timerHolm to remove this from its parent in time for the next render so that there wont be a globalkey collision.
        // but only do this if its parent was also not deleted, because if the parent was deleted, it will be animating the disappearance instead
        final parent = Mobj.seekTypedsAlreadyLoaded(previousValue!.parentId!, [
          TimerDataType(),
          ListType(StringType()),
        ]);
        if (parent == null ||
            parent.peek() != null ||
            parent is Mobj<List<String>>) {
          playExitAnimation();
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
    _parentDepthDispose?.call();
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

  /// Lifts this widget out of its place in the tray into the TimerScreen's
  /// background ephemeral layer and plays the slide-up / fuzzy-clip
  /// disappearance. Used both when the timer is truly deleted (its Mobj goes
  /// null) and when it's shelved into the trash bin (the Mobj is kept). The
  /// caller is responsible for removing the timer from whatever list was
  /// rendering it so there's no GlobalKey collision on the next frame.
  void playExitAnimation() {
    if (!mounted || _deleted) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    final timerScreen = context.findAncestorStateOfType<TimerScreenState>();
    timerScreen?.timerWidgetCache.remove(widget.mobj.id);
    if (renderBox == null || !renderBox.hasSize || timerScreen == null) return;
    final ephemeralAnimationLayer = timerScreen.backgroundEphemeralAnimationLayer;
    final tr = boxRectRelativeTo(
      boring.renderBox(widget.key as GlobalKey),
      ephemeralAnimationLayer.currentContext?.findRenderObject() as RenderBox?,
    )!;
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
      final timerScreen = context.findAncestorStateOfType<TimerScreenState>();
      if (_deletionHostChild != null) {
        timerScreen?.backgroundEphemeralAnimationLayer.currentState?.remove(
          _deletionHostChild!,
        );
        _deletionHostChild = null;
      }
    });
    _deletionHostChild = Positioned(left: tr.left, top: tr.top, child: widget);
    ephemeralAnimationLayer.currentState!.add(_deletionHostChild!);
    setState(() {
      _deleted = true;
    });
    _deletionAnimation!.forward();
  }

  void enterTitleEditMode() {
    final current = p.title ?? '';
    widget.mobj.value = p.withChanges(title: current);
    _titleController.text = current;
    _titleController.selection = TextSelection.collapsed(
      offset: current.length,
    );
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
    final pcs = childrenOf(
      Mobj.seekTypedsAlreadyLoaded(widget.mobj.peek()!.parentId!, [
        TimerDataType(),
        ListType(StringType()),
      ])!,
    );
    return pcs.indexOf(widget.mobj.id);
  }

  Widget buildShell(BuildContext context, Widget content) {
    return nesting([
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
            context.findAncestorStateOfType<TimerScreenState>()?.openTimerMenu(
              context,
              widget.key as GlobalKey<TimerBaseState>,
              widget.mobj.id,
            );
          }
        },
        child: next,
      ),
      // (next) => AnimatedTo.spring(
      //     globalKey: animatedToKey,
      //     enabled: !watchSignal(context, animatedToDisabled)!,
      //     // tighter than default. ios sets this to .55
      //     description: const Spring.withDamping(durationSeconds: 0.2),
      //     child: next),
      // (next) => AnimoveFrame(child: next),
      (next) => Animove(key: animatedToKey, child: next),
      (next) => AnimatedBuilder(
        animation: _appearanceAnimation,
        child: next,
        builder: (context, child) => FractionalTranslation(
          translation: Offset(
            0,
            0.6 * (1.0 - Curves.easeOut.transform(_appearanceAnimation.value)),
          ),
          child: FuzzyLinearClip(
            angle: pi / 2,
            progress: _appearanceAnimation.value,
            child: child!,
          ),
        ),
      ),
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
                final progress = Curves.easeOut.transform(
                  _deletionAnimation!.value,
                );
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
          child: child,
        ),
      ),
      (next) => GestureDetector(
        onTap: () {
          // a shelved (inactive) timer lives in the trash bin, where tapping
          // restores it rather than playing it; an active one takes the
          // current TimerScreen action (play / pin / delete).
          if (!widget.mobj.isActive) {
            context.findAncestorStateOfType<BinScreenState>()?.restoreTimer(
              widget.mobj.id,
            );
          } else {
            context.findAncestorStateOfType<TimerScreenState>()?.takeActionOn(
              widget.mobj.id,
            );
          }
        },
        behavior: HitTestBehavior.opaque,
        child: next,
      ),
    ], content);
  }
}

/// Timer widget, contrast with Timer row from the database orm
class Timer extends TimerBase {
  Timer({super.key, required super.mobj, super.animateIn = true}) {
    assert(
      !mobj.peek()!.isComposite,
      "For composite timers, use a Timercule rather than a Timer",
    );
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
      duration: const Duration(milliseconds: 80),
      vsync: this,
    );
    _slideActivateBounceAnimation = AnimationController(
      duration: const Duration(milliseconds: 180),
      vsync: this,
    );
    _selectedUnderlineAnimation = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _completedRecentlyAnimation = AnimationController(
      duration: const Duration(milliseconds: 510),
      vsync: this,
    );
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
    final moveTextWhenUp = 0.1;
    final clockRadius = watchSignal(context, timerWidgetRadius);
    final outerBackground = mt.timerculeHighlightBackground(0);
    final depth = watchSignal(context, this.depth);

    // final thumbSpan = Thumbspan.of(context);

    final totalDuration = durationToSeconds(digitsToDuration(d.digits));
    double dt = d.transpired;
    double pieCompletion = dt / totalDuration;
    final durationDigits = d.digits;
    bool timeIsNegative = dt < 0;
    final timeDigits = durationToDigits(
      dt.abs(),
      isNegative: timeIsNegative,
      padLevel: padLevelFor(durationDigits.length),
    );

    List<int> withDigitsReplacedWith(List<int> v, int d) =>
        List.filled(v.length, d);

    // Selected underline animation
    Widget selectionUnderline = AnimatedBuilder(
      animation: _selectedUnderlineAnimation,
      builder: (context, child) {
        final progress = Curves.easeOut.transform(
          _selectedUnderlineAnimation.value,
        );
        final underlineHeight = makoLineThickness;
        final gap = 3.0;

        // the underline form
        // return Positioned(
        //   left: 0,
        //   right: 0,
        //   bottom: -underlineHeight - gap,
        //   child: FractionallySizedBox(
        //     alignment: Alignment.centerLeft,
        //     widthFactor: progress,
        //     child: Container(
        //       height: underlineHeight,
        //       decoration: BoxDecoration(
        //         color: mt.foreBackColor,
        //         borderRadius: BorderRadius.circular(underlineHeight / 2),
        //       ),
        //     ),
        //   ),
        // );

        // the hind glow form
        return Positioned.fill(
          child: SignedPadding(
            insets: EdgeInsets.symmetric(
              vertical: -underlineHeight / 2,
              horizontal: -(underlineHeight / 2 + 3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress,
              child: Container(
                height: underlineHeight / 2,
                decoration: BoxDecoration(
                  color: mt.foreBackColor.withAlpha(128),
                  borderRadius: BorderRadius.circular(underlineHeight * 1.5),
                ),
              ),
            ),
          ),
        );
      },
    );

    Widget timeText(
      List<int> digits, {
      int? centiseconds,
      bool withTimeLevel = false,
      bool isNegative = false,
    }) {
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
          cs == null ? base : '$base.${cs.toString().padLeft(2, '0')}',
        );
      }

      return Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(
            opacity: 0,
            child: fmt(
              withDigitsReplacedWith(digits, 0),
              centiseconds != null ? 0 : null,
            ),
          ),
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

    /// this whole feature ended up being insufficiently visually clean, but I can't bring myself to remove the code yet.
    const bool showingTimeLevels = false;

    var animatedTextPartForTimer = AnimatedBuilder(
      animation: _runningAnimation,
      builder: (context, child) {
        final v = Curves.easeInCubic.transform(_runningAnimation.value);
        return FractionalTranslation(
          translation: Offset(0, lerp(-moveTextWhenUp, moveTextWhenUp, v)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Transform.scale(
                alignment: Alignment.bottomLeft,
                scale: lerp(0.63, 1, v),
                child: timeText(timeDigits, isNegative: timeIsNegative),
              ),
              Transform.scale(
                alignment: Alignment.topLeft,
                scale: lerp(1, 0.63, v),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    selectionUnderline,
                    // this is where you'd set withTimeLevel to true to have that feature
                    timeText(durationDigits, withTimeLevel: showingTimeLevels),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    Widget titledTextPart() {
      final Widget titleWidget = DefaultTextStyle.merge(
        style: TextStyle(fontSize: 26),
        child: _titleEditMode
            ? IntrinsicWidth(
                child: TextField(
                  focusNode: _titleFocusNode,
                  controller: _titleController,
                  decoration: InputDecoration.collapsed(
                    hintText: 'description',
                  ),
                  onChanged: (text) {
                    widget.mobj.value = p.withChanges(title: text);
                  },
                ),
              )
            : Text(d.title!, overflow: TextOverflow.clip),
      );
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
                Text('/'),
                timeText(durationDigits, withTimeLevel: showingTimeLevels),
              ],
            ),
            TimerKind.stopwatch => timeText(
              timeDigits,
              centiseconds: ((dt % 1) * 100).toInt(),
              isNegative: timeIsNegative,
              withTimeLevel: true,
            ),
            _ => throw wrongTimerVariantError(d.kind),
          },
        ],
      );
    }

    final Widget textPart = ignoreVerticalHeight(
      DefaultTextStyle.merge(
        style: TextStyle(height: 0.71, fontSize: 35, fontFamily: 'DongleLatin'),
        child: (d.title != null || _titleEditMode)
            ? titledTextPart()
            : switch (d.kind) {
                TimerKind.timer => animatedTextPartForTimer,
                TimerKind.stopwatch => timeText(
                  timeDigits,
                  centiseconds: ((dt % 1) * 100).toInt(),
                  isNegative: timeIsNegative,
                  withTimeLevel: showingTimeLevels,
                ),
                _ => throw wrongTimerVariantError(d.kind),
              },
      ),
    );

    final playIconRadius = 10;
    Offset playIconPos =
        Offset(clockRadius, clockRadius) +
        Offset.fromDirection(-pi / 4, clockRadius + 8 + playIconRadius);

    final stopwatchPulse = d.transpired % 1;
    final stopwatchPulseProgress =
        stopwatchPulse *
        (1 -
            Curves.easeOutCubic.transform(unlerpUnit(0.84, 1, stopwatchPulse)));
    final double timerOutline = depth > 0 ? 1.4 : defaultTimerOutline;
    final double innerTimerSpan = 2 * (clockRadius - defaultTimerOutline);
    final stopwatchPulseSize = lerp(
      innerTimerSpan - defaultTimerOutline * 2,
      (clockRadius - timerGap / 2) * 2 * 0.28,
      // Curves.easeOutCubic.transform(stopwatchPulse) *
      stopwatchPulseProgress,
    );

    Decoration containerShape(Color color) => d.kind == TimerKind.stopwatch
        ? ShapeDecoration(
            shape: StarBorder.polygon(
              sides: 8,
              pointRounding: 0.5,
              rotation: 45 / 2,
            ),
            color: color,
          )
        : BoxDecoration(shape: BoxShape.circle, color: color);

    Widget clockDial = nesting(
      [
        (next) {
          return PinAnimation(
            isPinned: whetherPinned,
            child: Container(
              width: 2 * clockRadius,
              height: 2 * clockRadius,
              padding: EdgeInsets.all(defaultTimerOutline - timerOutline),
              child: Container(
                padding: EdgeInsets.all(timerOutline),
                decoration: containerShape(outerBackground),
                child: next,
              ),
            ),
          );
        },
      ],
      switch (d.kind) {
        TimerKind.timer => AnimatedBuilder(
          animation: _completedRecentlyAnimation,
          builder: (context, child) {
            var pie = Pie(
              innerRadp:
                  (1 -
                      Curves.easeOutCubic.transform(
                            unlerpUnit(
                              0.2,
                              0.46,
                              _completedRecentlyAnimation.value,
                            ),
                          ) *
                          ((defaultTimerOutline * 2) / innerTimerSpan)) *
                  (1 -
                      unlerpUnit(
                        0.5,
                        1,
                        Curves.easeInCubic.transform(
                          _completedRecentlyAnimation.value,
                        ),
                      )),
              backgroundColor: TimerBaseState.backgroundColor(d.hue),
              color: TimerBaseState.primaryColor(d.hue),
              value: pieCompletion,
              size: innerTimerSpan,
            );
            return pie;
          },
        ),
        TimerKind.stopwatch => Container(
          width: innerTimerSpan,
          height: innerTimerSpan,
          decoration: containerShape(TimerBaseState.backgroundColor(d.hue)),
          child: Center(
            child: Container(
              width: stopwatchPulseSize,
              height: stopwatchPulseSize,
              decoration: ShapeDecoration(
                shape: StarBorder.polygon(
                  sides: 8,
                  // it should linger in the full roundness for a moment
                  pointRounding: lerp(
                    0.5,
                    1,
                    unlerpUnit(0.0, 0.8, stopwatchPulseProgress),
                  ),
                  rotation: 45 / 2,
                ),
                color: TimerBaseState.primaryColor(d.hue),
              ),
            ),
          ),
        ),
        _ => throw wrongTimerVariantError(d.kind),
      },
      // size: 90),
    );

    return buildShell(
      context,
      Container(
        clipBehavior: Clip.none,
        height: clockRadius * 2 + timerGap,
        padding: EdgeInsets.all(timerGap / 2),
        // do a bounce animation to respond to slide to start interactions
        child: AnimatedBuilder(
          animation: _slideActivateBounceAnimation,
          builder: (context, child) => Transform.translate(
            offset:
                _slideBounceDirection *
                10 *
                defaultPulserFunction(_slideActivateBounceAnimation.value),
            child: child,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              clockDial,
              SizedBox(width: timerGap * 0.4),
              textPart,
            ],
          ),
        ),
      ),
    );
  }
}

class Timercule extends TimerBase {
  const Timercule({super.key, required super.mobj, super.animateIn = true});

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

  @override
  double get depthOffset => 1.0;

  @override
  Widget build(BuildContext context) {
    final d = watchSignal(context, widget.mobj) ?? previousValue!;
    final theme = Theme.of(context);
    final double timerHeight = watchSignal(context, timerWidgetRadius) * 2;
    final depth = watchSignal(context, this.depth);
    final mt = MakoThemeData.fromContext(context);
    final backgroundColor = mt.timerculeHighlightBackground(depth);
    final buttonSpan = watchSignal(
      context,
      Mobj.getAlreadyLoaded(buttonSpanID, DoubleType()),
    )!;
    final cornerRadius = backingCornerRounding * buttonSpan;
    Widget? titleWidget;
    if (d.title != null || _titleEditMode) {
      final titleStyle = TextStyle(
        color: theme.colorScheme.onSurface,
        height: 0.71,
        fontFamily: 'DongleLatin',
        fontSize: 26,
      );
      titleWidget = Padding(
        padding: const EdgeInsets.all(timerGap / 2),
        child: DefaultTextStyle.merge(
          style: titleStyle,
          child: _titleEditMode
              ? TextField(
                  focusNode: _titleFocusNode,
                  controller: _titleController,
                  style: titleStyle,
                  decoration: InputDecoration.collapsed(
                    hintText: 'description',
                  ),
                  onChanged: (text) {
                    widget.mobj.value = p.withChanges(title: text);
                  },
                )
              : Text(d.title!, overflow: TextOverflow.clip),
        ),
      );
    }

    Widget handleContainer({required Widget child}) => Container(
      constraints: BoxConstraints(
        minWidth: timerHeight * 0.7,
        minHeight: timerHeight + timerGap,
        maxWidth: timerHeight * 3,
      ),
      child: child,
    );

    Widget handle = handleContainer(
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned.fill(
            child: Center(
              child: timerKindIcon(
                d.kind,
                color: mt.timerculeHighlightBackground(depth + 1),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            child: titleWidget ?? const SizedBox.shrink(),
          ),
        ],
      ),
    );

    Widget tail = Container(
      width: timerHeight * 0.333,
      height: timerHeight * 0.333,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5)),
    );

    // apparently, sometimes Timers have to build in places where TimerScreenState is no longer in the ancestry (probably from the overlay, during dragging), so we have to retain the map and not assume we'll always be able to make the connection and fetch it.
    timerWidgetCache ??= context
        .findAncestorStateOfType<TimerScreenState>()
        ?.timerWidgetCache;

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
                      ...d.children.map<Widget>(
                        (id) => getOrCreateTimerWidget(
                          timerWidgetCache,
                          id,
                          animateIn: true,
                        ),
                      ),
                      tail,
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                child: SizeReporter(
                  previousSize: _handleSizeNotifier,
                  child: handle,
                ),
              ),
            ],
          ),
        ),
      ),
    );

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
            ancestor.peek()!.parentId!,
            TimerDataType(),
          );
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
        final insertAt = (iWrapInsertion.midwayInsertionIndex() - 1).clamp(
          0,
          children.length,
        );
        final childIndex = children.indexOf(timerId);
        if (childIndex != -1) {
          // Already a child - reorder
          final (operative, atIWrap) = iWrapInsertion.cleverInsertionIndexFor(
            childIndex + 1,
            children.length + 2,
          );
          if (operative) {
            final at = (atIWrap - 1).clamp(0, children.length);
            widget.mobj.value = widget.mobj.peek()!.withChanges(
              children: children.toList()
                ..insert(at, timerId)
                ..removeAt(childIndex > at ? childIndex + 1 : childIndex),
            );
          }
        } else {
          if (cm.peek()!.parentId != null) {
            final oldList = Mobj.seekTypedsAlreadyLoaded(cm.peek()!.parentId!, [
              TimerDataType(),
              ListType(StringType()),
            ])!;
            final oldChildren = childrenOf(oldList);
            writeBackChildren(
              oldList,
              oldChildren.toList()..removeAt(oldChildren.indexOf(timerId)),
            );
          }
          widget.mobj.value = widget.mobj.peek()!.withChanges(
            children: children.toList()..insert(insertAt, timerId),
          );
          // why selected false? because if a user drags a timer onto a composite timer, it indicates that they're done editing it
          cm.value = cm.peek()!.withChanges(
            parentId: widget.mobj.id,
            selected: false,
          );
        }
      },
    );
  }

  @override
  void dispose() {
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
              painter: SweepGradientCirclePainter(
                topColor,
                bottomColor,
                holeRadius: holeRadius,
              ),
            ),
          ),
        ),
      ),
    );
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
    return Watch((context) {
      final isRightHanded = Mobj.getAlreadyLoaded(
        isRightHandedID,
        BoolType(),
      ).value!;
      return nesting<Widget>(
        [
          (child) => Align(
            alignment: isRightHanded
                ? FractionalOffset(0.8, 1)
                : FractionalOffset(0.2, 1),
            child: child,
          ),
          // very minor bug: we can't have this yet, because resizes cause movement discontinuities. This will make scrolling the timertray feel sluggish. Fix animove.
          // (child) => AnimoveFrame(child: child),
        ],
        IWrap(
          key: wrapKey,
          textDirection: isRightHanded ? TextDirection.ltr : TextDirection.rtl,
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
        ),
      );
    });
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
    lerp(lower.lightness, upper.lightness, t),
  );
}

final List<double> numericRadialActivatorPositions = [-pi / 2, -pi];
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

/// Geometry handed to a [DragRingClipBuilder] so it can shape the colored backdrop of a drag ring. The builder returns a [Path] in the coordinate space of a [totalSpan]-square box whose center sits at [center].
class DragRingClipArgs {
  /// grow-in/out only: 0 = collapsed into the button, 1 = fully open. Does not itself account for selection — that's [swipep] and [selections].
  final double growth;

  /// 0..1 "something is considered selected"; stays raised while a choice is held, so a builder can keep its base collapsed during the commit.
  final double swipep;

  /// 0..1 release/dismissal commit (the option-activation animation). A builder uses this to finish collapsing onto the chosen item as the ring bows out.
  final double releasep;

  /// per-item selection amount (eased, with release recede applied). A builder uses this to slide/highlight toward the chosen item.
  final List<double> selections;

  /// distance of the icon centers from [center].
  final double radius;

  /// radius of an individual icon disc (half of actionRadiusMax).
  final double actionRadius;

  /// icon angles, already rectified for handedness.
  final List<double> angles;
  final bool isRightHanded;
  final Offset center;

  /// the button's span; the resting shape is sized off this.
  final double buttonSpan;

  /// 0..1 scalar on the resting centerline radius, played on every ring's first build. At 0 the rest band collapses to a [halfThickness]-radius filled circle (since the cap discs merge); at 1 it's the normal rest shape. Has no effect once the ring is fully open.
  final double growIn;

  /// spring-driven angle of the arc's start cap (in the same handedness-rectified space as [angles]). Equals [angles].first at rest, slides to the selected item's angle.
  final double selectionStartAngle;

  /// spring-driven angle of the arc's end cap. Equals [angles].last at rest, slides to the selected item's angle.
  final double selectionEndAngle;

  const DragRingClipArgs({
    required this.growth,
    required this.swipep,
    this.releasep = 0,
    required this.selections,
    required this.radius,
    required this.actionRadius,
    required this.angles,
    required this.isRightHanded,
    required this.center,
    required this.buttonSpan,
    required this.selectionStartAngle,
    required this.selectionEndAngle,
    this.growIn = 1.0,
  });
}

class _DragRingPathClipper extends CustomClipper<Path> {
  final Path path;
  const _DragRingPathClipper(this.path);
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(covariant _DragRingPathClipper oldClipper) =>
      oldClipper.path != path;
}

/// Reveal clip for a drag ring label pill: a fully-rounded rect that grows from a point at one end, lengthening with the constant-change-in-area math of the crank game progress bar.
class _FluidPillClipper extends CustomClipper<Path> {
  final double progress;
  final bool growFromLeft;
  const _FluidPillClipper({required this.progress, required this.growFromLeft});

  @override
  Path getClip(Size size) {
    final (radius, length) = fluidBarRadiusAndHeightForProgress(
      size.height,
      size.width,
      progress,
    );
    final left = growFromLeft ? 0.0 : size.width - length;
    return Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height / 2 - radius, length, radius * 2),
        Radius.circular(radius),
      ),
    );
  }

  @override
  bool shouldReclip(covariant _FluidPillClipper oldClipper) =>
      oldClipper.progress != progress ||
      oldClipper.growFromLeft != growFromLeft;
}

/// A selected item's highlight disc, as a multiple of the icon disc radius — a touch bigger than the resting dot it grows out of.
const double dragRingSelectedClipScale = 1.12;

/// how far the sweep has collapsed by the time a choice is fully held (before release finishes it off). Just shy of 1 so a sliver of the ring still rides on the chosen item during the hold.
const double dragRingSweepHoldShrink = 0.9;

/// Drag-to-play style clip. The total surface is
///   union(selectedItemClips…, intersect(sweep, union(centerRing, unselectedItemClips…)))
/// The center disc and each item's resting dot live *inside* a big "sweep"
/// circle that, as a choice is made, collapses down onto the chosen item — its
/// center eased toward the spring-tracked selection focus — wiping the rest of
/// the ring away in the direction of the choice (driven by [DragRingClipArgs.swipep]
/// while held, finished off by [DragRingClipArgs.releasep] on dismissal). Each
/// selected item's highlight disc is unioned on *top* of the sweep so it stays
/// crisp while everything else collapses onto it.
Path circlesDragRingClip(DragRingClipArgs args) {
  // center + unselected dots: presence follows grow-in/out only. The sweep
  // (below), not the swipe, is what hides them once a choice is underway.
  final e = Curves.easeOut.transform(args.growth);
  final leafp = unlerpUnit(0.7, 1, e);

  // --- inside the sweep: the center ring and the unselected item dots ---
  Path inner = Path()
    ..addOval(Rect.fromCircle(center: args.center, radius: args.radius * e));
  for (final angle in args.angles) {
    final c = args.center + Offset.fromDirection(angle, args.radius * leafp);
    inner = Path.combine(
      PathOperation.union,
      inner,
      Path()..addOval(
        Rect.fromCircle(center: c, radius: args.actionRadius * leafp),
      ),
    );
  }

  // --- the sweep: a circle that collapses onto the selection focus ---
  final dismiss = max(
    Curves.easeOut.transform(args.swipep) * dragRingSweepHoldShrink,
    Curves.easeOut.transform(args.releasep),
  );
  final focusAngle = (args.selectionStartAngle + args.selectionEndAngle) / 2;
  final focusPoint =
      args.center + Offset.fromDirection(focusAngle, args.radius);
  // the center stays put while the sweep is still large (easeIn), then rides in
  // onto the chosen item as it closes, so we never clip the far side early.
  final sweepCenter = Offset.lerp(
    args.center,
    focusPoint,
    Curves.easeIn.transform(dismiss),
  )!;
  final sweepRadius = lerp(args.radius + args.actionRadius * 2.5, 0, dismiss);
  final sweep = Path()
    ..addOval(Rect.fromCircle(center: sweepCenter, radius: sweepRadius));

  Path path = Path.combine(PathOperation.intersect, sweep, inner);

  // --- on top of the sweep: the selected item highlight discs ---
  for (int i = 0; i < args.selections.length; i++) {
    // hold full through the release, then a quick final shrink so the highlight
    // doesn't pop out of existence when the ring is removed.
    final sel =
        args.selections[i] *
        (1 - Curves.easeOut.transform(unlerpUnit(0.7, 1, args.releasep)));
    if (sel <= 0) continue;
    final c = args.center + Offset.fromDirection(args.angles[i], args.radius);
    path = Path.combine(
      PathOperation.union,
      path,
      Path()..addOval(
        Rect.fromCircle(
          center: c,
          radius: args.actionRadius * dragRingSelectedClipScale * sel,
        ),
      ),
    );
  }
  return path;
}

/// A thick arc band with rounded caps. Built as a single closed contour
/// (outer arc → end cap semicircle → inner arc → start cap semicircle) so the
/// caps and band aren't separate `Path.combine` operands — earlier union-based
/// versions glitched for a frame because each cap disc's diameter coincided
/// exactly with the band's flat radial edge, which is a known SkPathOps
/// instability with tangent-sharing curves.
///
/// Degenerates: [startAngle] == [endAngle] collapses to a single cap disc; the
/// sub-thickness regime ([radius] < [halfThickness], hit briefly during the
/// initial grow-in when the caps cross the center) falls back to a
/// `Path.combine` of the two cap discs and a pie sector — those operands have
/// area overlap rather than tangent contact, which Skia handles cleanly.
Path roundedArcBand({
  required Offset center,
  required double radius,
  required double halfThickness,
  required double startAngle,
  required double endAngle,
}) {
  if (startAngle == endAngle) {
    return Path()..addOval(
      Rect.fromCircle(
        center: center + Offset.fromDirection(startAngle, radius),
        radius: halfThickness,
      ),
    );
  }

  if (radius < halfThickness) {
    final startCapCenter = center + Offset.fromDirection(startAngle, radius);
    final endCapCenter = center + Offset.fromDirection(endAngle, radius);
    final ro = radius + halfThickness;
    final sweep = endAngle - startAngle;
    Path p = Path()
      ..addOval(Rect.fromCircle(center: startCapCenter, radius: halfThickness));
    p = Path.combine(
      PathOperation.union,
      p,
      Path()
        ..addOval(Rect.fromCircle(center: endCapCenter, radius: halfThickness)),
    );
    final sector = Path()
      ..moveToOffset(center)
      ..lineTo(
        center.dx + ro * cos(startAngle),
        center.dy + ro * sin(startAngle),
      )
      ..arcTo(
        Rect.fromCircle(center: center, radius: ro),
        startAngle,
        sweep,
        false,
      )
      ..close();
    return Path.combine(PathOperation.union, p, sector);
  }

  final ro = radius + halfThickness;
  final ri = radius - halfThickness;
  final sweep = endAngle - startAngle;
  final dir = sweep.sign;
  final startOuter = center + Offset.fromDirection(startAngle, ro);
  final startCapCenter = center + Offset.fromDirection(startAngle, radius);
  final endCapCenter = center + Offset.fromDirection(endAngle, radius);

  final p = Path()
    ..moveToOffset(startOuter)
    ..arcTo(
      Rect.fromCircle(center: center, radius: ro),
      startAngle,
      sweep,
      false,
    )
    ..arcTo(
      Rect.fromCircle(center: endCapCenter, radius: halfThickness),
      endAngle,
      dir * pi,
      false,
    );
  if (ri > 0) {
    p.arcTo(
      Rect.fromCircle(center: center, radius: ri),
      endAngle,
      -sweep,
      false,
    );
  }
  p
    ..arcTo(
      Rect.fromCircle(center: startCapCenter, radius: halfThickness),
      startAngle + pi,
      dir * pi,
      false,
    )
    ..close();
  return p;
}

/// Special-timer style clip: a rounded-cap arc straddling the icon ring. It grows out of the button (centerRadius 0 -> radius), and on selection slides its caps together onto the chosen item (the caps are spring-tracked by the host state and handed in via [DragRingClipArgs.selectionStartAngle]/[DragRingClipArgs.selectionEndAngle]), becoming the highlight itself.
Path arcDragRingClip(DragRingClipArgs args) {
  final g = args.growth;
  final fullStart = args.angles.first;
  final fullEnd = args.angles.last;
  final restArc = lerp(2 * pi, pi, Curves.easeOutCubic.transform(args.growIn));
  final restFocus = (fullStart + fullEnd) / 2;
  final fullArc = fullEnd - fullStart;
  final appearanceSpin = -(1 - args.growIn) * pi * 1.6;
  final restStart = restFocus - fullArc.sign * restArc / 2 + appearanceSpin;
  final restEnd = restFocus + fullArc.sign * restArc / 2 + appearanceSpin;

  // at rest, a thin half-arc whose radial profile matches the old icon (centerline radius and thickness), opening out to straddle the icon ring.
  final restOuterR = 0.2 * args.buttonSpan;
  final restHalfThickness =
      makoLineThickness / 2 * unlerpUnit(0, 0.4, args.growIn);
  final restRadius = restOuterR - restHalfThickness;
  final handednessSign = args.isRightHanded ? 1 : -1;

  return roundedArcBand(
    center:
        args.center + Offset(handednessSign * restRadius * 0.34, 0) * (1 - g),
    radius: lerp(restRadius, args.radius, g),
    halfThickness: lerp(restHalfThickness, args.actionRadius, g),
    startAngle: lerp(restStart, args.selectionStartAngle, g),
    endAngle: lerp(restEnd, args.selectionEndAngle, g),
  );
}

class DragActionRing extends StatefulWidget {
  final Offset position;
  final Signal<int?> dragEvents;

  /// used to close the ring if another one opens
  final Listenable? suppressionBus;
  final List<Widget> radialActivatorIcons;
  final List<Widget>? radialActivatorLabels;
  final List<double> radialActivatorPositions;
  final Path Function(DragRingClipArgs args) clipBuilder;

  /// position represents the touch origin, visualPosition is where the visual should be centered. The reason we distinguish these things is it looks wrong or imprecise if the visual origin doesn't come from the UI element it's associated with, while the touch origin also absolutely needs to be correct or else you're injecting random error to the user choice.
  final Offset visualPosition;
  final bool? shuntRight;

  /// when true, the ring is rendered permanently (its collapsed phase is the
  /// button itself) instead of being added/removed ephemerally: it starts
  /// closed, opens on pan-down, and returns to rest instead of self-removing.
  final bool persistent;

  /// set true (by the persistent host) on the ring that's bowing out after a selection. The ring stops taking input and plays its [completionAnimation] down — thinning its arc to nothing while its selection keeps sliding home — then calls [onRetireComplete] so the host drops it.
  final bool retiring;

  /// a persistent live ring calls this when its selection lands, so the host can retire it and stand up a fresh live ring in its place.
  final VoidCallback? onRetire;

  /// a retiring ring calls this once its completion animation finishes, so its container can remove it.
  final VoidCallback? onRetireComplete;

  final bool useSpringExpansion;

  const DragActionRing({
    super.key,
    required this.position,
    required this.dragEvents,
    this.suppressionBus,
    required this.visualPosition,
    this.shuntRight,
    required this.radialActivatorIcons,
    this.radialActivatorLabels,
    required this.radialActivatorPositions,
    required this.clipBuilder,
    this.persistent = false,
    this.retiring = false,
    this.onRetire,
    this.onRetireComplete,
    this.useSpringExpansion = false,
  });

  @override
  State<DragActionRing> createState() => DragActionRingState();
}

class DragActionRingState extends State<DragActionRing>
    with TickerProviderStateMixin, SignalsMixin {
  int numberSelected = -1;
  // mirrors numberSelected, but not always
  int centeredNumber = -1;
  late final List<LabelSpring> labelAnimations;

  /// per-item growth of the selection circle, so the highlight animates as the selection moves between items.
  late final List<AnimationController> selectionAnimations;

  /// physical springs tracking the arc's start and end cap angles (in handedness-rectified space). They rest at the first/last activator and both retarget to the current selection when one exists. The arc clip reads their values in lieu of a linear average over the per-item selection animations.
  late final TargetSpring _arcStartSpring;
  late final TargetSpring _arcEndSpring;

  UpDownAnimationController? _upDown;
  SpringExpansionController? _spring;

  Listenable get _expansionListenable => _upDown ?? _spring!;
  double get _expansionGrowth =>
      _upDown != null ? _upDown!.scalarValue : _spring!.value;
  void _expansionForward() {
    if (_upDown != null) {
      _upDown!.forward();
    } else {
      _spring!.forward();
    }
  }

  void _expansionReverse() {
    if (_upDown != null) {
      _upDown!.reverse();
    } else {
      _spring!.reverse();
    }
  }

  void _addExpansionClosedListener(VoidCallback listener) {
    if (_upDown != null) {
      _upDown!.addStatusListener((status) {
        if (status == AnimationStatus.dismissed) listener();
      });
    } else {
      _spring!.addClosedListener(listener);
    }
  }

  late final AnimationController optionActivationAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));
  late final AnimationController optionConsiderationAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 200));

  /// 0 = fully present, 1 = thinned away to nothing. A retiring ring plays this forward to vanish; while it runs, build scales the arc's thickness (and the icons/labels) down by it.
  late final AnimationController completionAnimation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 350),
  );

  /// 0 = unborn (rest radius scaled to 0, so the band collapses to a filled disc of halfThickness), 1 = normal rest. Forwarded on initState so every fresh ring eases in.
  late final AnimationController growInAnimation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 220),
  );
  Function()? dragEventsSubscription;

  void _onOtherRingOpens() {
    _expansionReverse();
  }

  /// persistent rings call this once fully closed (upDown dismissed): clear the selection state. It's invisible because at growth 0 the arc is collapsed to a disc at the center regardless of selection.
  void _silentReset() {
    if (!mounted) return;
    for (final c in selectionAnimations) {
      c.value = 0;
    }
    for (final c in labelAnimations) {
      c.reset();
    }
    optionConsiderationAnimation.value = 0;
    optionActivationAnimation.value = 0;
    setState(() {
      numberSelected = -1;
      centeredNumber = -1;
    });
    // ring's invisible — jump the springs straight to rest instead of animating, so they're ready for the next open.
    final (restStart, restEnd) = _restCapAngles();
    _arcStartSpring.jump(restStart);
    _arcEndSpring.jump(restEnd);
  }

  /// rendered-space (handedness-rectified) angles of the first and last activators — where the arc's caps rest when nothing is selected.
  (double, double) _restCapAngles() {
    if (widget.radialActivatorPositions.isEmpty) return (0, 0);
    final isRightHanded =
        Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).peek() ?? true;
    double rectify(double a) =>
        conditionallyApplyIf<double>(!isRightHanded, flipAngleHorizontally, a);
    return (
      rectify(widget.radialActivatorPositions.first),
      rectify(widget.radialActivatorPositions.last),
    );
  }

  /// retarget the cap springs based on [numberSelected]: both onto the chosen item, or back to rest if nothing's selected.
  void _retargetArcSprings() {
    if (numberSelected == -1) {
      final (restStart, restEnd) = _restCapAngles();
      _arcStartSpring.target = restStart;
      _arcEndSpring.target = restEnd;
    } else {
      final isRightHanded =
          Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).peek() ?? true;
      final a = conditionallyApplyIf<double>(
        !isRightHanded,
        flipAngleHorizontally,
        widget.radialActivatorPositions[numberSelected],
      );
      _arcStartSpring.target = a;
      _arcEndSpring.target = a;
    }
  }

  /// the raw selection-animation value at which a freshly chosen item's
  /// highlight disc exactly matches the unselected dot it grows out of, so the
  /// first selection grows continuously from the still-visible dot. Mirrors the
  /// dot/disc radius math in [circlesDragRingClip].
  double _firstSelectionStartValue() {
    final growth = widget.useSpringExpansion
        ? _expansionGrowth.clamp(0.0, 1.0)
        : Curves.easeOut.transform(unlerpUnit(0, 0.6, _expansionGrowth));
    final leafp = unlerpUnit(0.7, 1, Curves.easeOut.transform(growth));
    return (leafp / dragRingSelectedClipScale).clamp(0.0, 1.0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.useSpringExpansion) {
      _spring = SpringExpansionController(vsync: this);
    } else {
      _upDown = UpDownAnimationController(
        vsync: this,
        riseDuration: Duration(milliseconds: 300),
        fallDuration: Duration(milliseconds: 200),
      );
    }
    labelAnimations = List.generate(
      widget.radialActivatorPositions.length,
      (_) => LabelSpring(
        vsync: this,
        kickSpeed: 10,
        delay: Duration(milliseconds: 300),
        spring: SpringDescription.withDampingRatio(mass: 1, stiffness: 250),
      ),
    );
    selectionAnimations = List.generate(
      widget.radialActivatorPositions.length,
      (_) => AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 220),
      ),
    );
    final (restStart, restEnd) = _restCapAngles();
    _arcStartSpring = TargetSpring(vsync: this, initial: restStart);
    _arcEndSpring = TargetSpring(vsync: this, initial: restEnd);
    widget.suppressionBus?.addListener(_onOtherRingOpens);
    if (!widget.persistent) {
      _expansionForward();
    }
    completionAnimation.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onRetireComplete?.call();
    });
    growInAnimation.forward();
    if (widget.persistent) {
      // once fully closed, clear selection state for the next interaction.
      _addExpansionClosedListener(_silentReset);
    } else {
      optionActivationAnimation.addStatusListener((status) {
        if (!mounted) {
          return;
        }
        if (status == AnimationStatus.completed) {
          context.findAncestorStateOfType<SelfRemovalHostState>()?.remove(
            widget,
          );
        }
      });
      _addExpansionClosedListener(() {
        // wait for option activation if it's going
        if (optionActivationAnimation.isAnimating) return;
        if (!mounted) return;
        context.findAncestorStateOfType<SelfRemovalHostState>()?.remove(widget);
      });
    }
    dragEventsSubscription = widget.dragEvents.subscribe((v) {
      if (v == null) {
        if (numberSelected != -1) {
          if (widget.persistent) {
            // hand off: the host retires this ring (it'll thin away while its selection finishes sliding home) and stands up a fresh live ring.
            widget.onRetire?.call();
          } else {
            optionActivationAnimation.forward();
          }
        } else {
          _expansionReverse();
        }
        if (!widget.persistent) dragEventsSubscription?.call();
      } else if (v != -1) {
        if (v != numberSelected) {
          HapticFeedback.heavyImpact();
          final wasNothingSelected = numberSelected == -1;
          if (numberSelected != -1) {
            labelAnimations[numberSelected].reverse();
            selectionAnimations[numberSelected].reverse();
          }
          labelAnimations[v].forward();
          if (wasNothingSelected) {
            // first selection: the unselected dot is still visible, so grow the
            // highlight continuously out of it (from the selection value whose
            // disc matches the dot's current radius).
            selectionAnimations[v].forward(from: _firstSelectionStartValue());
          } else {
            // a choice was already held, so the sweep has hidden the dots —
            // starting from the (now-invisible) dot's width would pop. Grow from
            // wherever this item's animation already sits (usually 0).
            selectionAnimations[v].forward();
          }
          setState(() {
            numberSelected = v;
            centeredNumber = v;
            optionConsiderationAnimation.forward();
          });
          _retargetArcSprings();
        } else {
          setState(() {
            optionConsiderationAnimation.forward();
          });
        }
      } else {
        if (numberSelected != -1) {
          labelAnimations[numberSelected].reverse();
          selectionAnimations[numberSelected].reverse();
        }
        setState(() {
          numberSelected = -1;
          optionConsiderationAnimation.reverse();
          _expansionForward();
        });
        _retargetArcSprings();
      }
    });
  }

  @override
  void didUpdateWidget(DragActionRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.retiring && !oldWidget.retiring) {
      // freeze input but let the selection animation keep running; just thin the arc out to nothing, then ask the host to drop us.
      dragEventsSubscription?.call();
      dragEventsSubscription = null;
      widget.suppressionBus?.removeListener(_onOtherRingOpens);
      for (final c in labelAnimations) {
        c.reverse();
      }
      completionAnimation.forward();
    }
  }

  @override
  void dispose() {
    for (final c in labelAnimations) {
      c.dispose();
    }
    for (final c in selectionAnimations) {
      c.dispose();
    }
    optionActivationAnimation.dispose();
    optionConsiderationAnimation.dispose();
    completionAnimation.dispose();
    growInAnimation.dispose();
    _arcStartSpring.dispose();
    _arcEndSpring.dispose();
    _upDown?.dispose();
    _spring?.dispose();
    dragEventsSubscription?.call();
    widget.suppressionBus?.removeListener(_onOtherRingOpens);
    super.dispose();
  }

  Widget buildWithGivenAnimationParameters(
    double growp,
    double swipep,
    double releasep,
  ) {
    final theme = Theme.of(context);
    final mt = MakoThemeData.fromContext(context);
    final thumbSpan = Thumbspan.of(context);
    final isRightHanded = watchSignal(
      context,
      Mobj.getAlreadyLoaded(isRightHandedID, BoolType()),
    )!;
    final buttonSpan = watchSignal(
      context,
      Mobj.getAlreadyLoaded(buttonSpanID, DoubleType()),
    )!;

    final radialRadiusMax = thumbSpan * (0.5 + 0.17);
    // how grown the ring is overall (grow-in, fall-out). selection collapse is handled by the clip builder via swipep / selections, not here.
    final baseGrow = widget.useSpringExpansion
        ? growp.clamp(0.0, 1.0)
        : Curves.easeOut.transform(unlerpUnit(0, 0.6, growp));
    final completion = Curves.easeInCubic.transform(completionAnimation.value);
    final iconFade =
        unlerpUnit(0.6, 1, baseGrow) *
        // fades a bit immediately on completion, but doesn't fade all the way out
        lerp(1, 0.7, unlerpUnit(0, 0.36, completionAnimation.value));
    final ringColor = lerpColor(
      theme.colorScheme.onSurface,
      // mt.reducedProminenceColor,
      theme.colorScheme.primary,
      baseGrow,
    );
    // final ringColor = mt.reducedProminenceColor;
    // final ringColor = theme.colorScheme.onSurface;

    // raw per-item selection growth; the clip builder owns any release recede
    // (it keeps the chosen item's highlight crisp while the sweep collapses onto
    // it, only shrinking it away at the very end of the dismissal).
    final selections = [for (final c in selectionAnimations) c.value];

    final actionRadiusMax = thumbSpan * 0.6;
    Widget dragChoiceWidget(Widget child) {
      return SizedBox(
        width: actionRadiusMax,
        height: actionRadiusMax,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Opacity(
            opacity: iconFade,
            child: IconTheme(
              data: IconThemeData(color: theme.colorScheme.surface),
              child: DefaultTextStyle(
                style: controlPadTextStyle.merge(
                  TextStyle(color: theme.colorScheme.surface),
                ),
                child: FittedBox(fit: BoxFit.scaleDown, child: child),
              ),
            ),
          ),
        ),
      );
    }

    Offset positionFor(int actionIndex) {
      final angle = conditionallyApplyIf<double>(
        !isRightHanded,
        flipAngleHorizontally,
        widget.radialActivatorPositions[actionIndex],
      );
      return Offset.fromDirection(angle, radialRadiusMax);
    }

    final List<Widget> radialActivatorIcons = List.generate(
      widget.radialActivatorPositions.length,
      (i) {
        Offset o = positionFor(i);
        return Positioned(
          left: o.dx,
          top: o.dy,
          child: FractionalTranslation(
            translation: Offset(-0.5, -0.5),
            child: dragChoiceWidget(widget.radialActivatorIcons[i]),
          ),
        );
      },
    );

    double totalSpan = 2 * radialRadiusMax + 2 * actionRadiusMax;
    final center = Offset(totalSpan / 2, totalSpan / 2);

    // the builder shapes the colored backdrop, including its response to
    // selection (a sliding arc, or per-item circles).
    final Path clipPath = widget.clipBuilder(
      DragRingClipArgs(
        growth: baseGrow,
        swipep: swipep,
        releasep: releasep,
        selections: selections,
        radius: radialRadiusMax,
        // at full growth this is the arc's half-thickness, so playing completion
        // up to 1 thins the retiring arc down to nothing in place.
        actionRadius: (actionRadiusMax / 2) * (1 - completion),
        angles: widget.radialActivatorPositions
            .map(
              (a) => conditionallyApplyIf<double>(
                !isRightHanded,
                flipAngleHorizontally,
                a,
              ),
            )
            .toList(),
        isRightHanded: isRightHanded,
        center: center,
        buttonSpan: buttonSpan,
        growIn: Curves.easeOutCubic.transform(growInAnimation.value),
        selectionStartAngle: _arcStartSpring.value,
        selectionEndAngle: _arcEndSpring.value,
      ),
    );

    final Widget clippedRing = ClipPath(
      clipper: _DragRingPathClipper(clipPath),
      child: SizedBox(
        width: totalSpan,
        height: totalSpan,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ColoredBox(color: ringColor)),
            Transform.translate(
              offset: center,
              child: Stack(
                clipBehavior: Clip.none,
                children: radialActivatorIcons,
              ),
            ),
          ],
        ),
      ),
    );

    Widget labelWidgetAt(int index, double progress) {
      final angle = conditionallyApplyIf<double>(
        !isRightHanded,
        flipAngleHorizontally,
        widget.radialActivatorPositions[index],
      );
      final labelPos = Offset.fromDirection(
        angle,
        radialRadiusMax + actionRadiusMax * 0.27,
      );
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
      final double fontSize = 30;
      // the pill grows from its edge nearest the ring: for a right-side label that's its left edge.
      final growFromLeft = rawTx > 0;
      return nesting([
        (w) => Positioned(left: labelPos.dx, top: labelPos.dy, child: w),
        (w) => FractionalTranslation(
          translation: (Offset(rawTx / m, rawTy / m) - Offset(1, 1)) / 2,
          child: w,
        ),
        (w) => ClipPath(
          clipper: _FluidPillClipper(
            progress: progress,
            growFromLeft: growFromLeft,
          ),
          child: w,
        ),
        (w) => ColoredBox(color: theme.colorScheme.primary, child: w),
        (w) => Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: w,
        ),
        (w) => DefaultTextStyle(
          style: controlPadTextStyle.copyWith(
            color: theme.colorScheme.surface,
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
          ),
          child: w,
        ),
      ], widget.radialActivatorLabels![index]);
    }

    return IgnorePointer(
      child: FractionalTranslation(
        translation: Offset(-0.5, -0.5),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            clippedRing,
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
                            // cut off the bottom part so that the very slow reduction to zero isn't visible
                            unlerpUnit(0.06, 1, labelAnimations[i].value) *
                                (1 - completion),
                          ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.visualPosition.dx,
      top: widget.visualPosition.dy,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _expansionListenable,
          optionConsiderationAnimation,
          optionActivationAnimation,
          completionAnimation,
          growInAnimation,
          ...labelAnimations,
          ...selectionAnimations,
          _arcStartSpring,
          _arcEndSpring,
        ]),
        builder: (context, child) {
          return buildWithGivenAnimationParameters(
            _expansionGrowth,
            optionConsiderationAnimation.value,
            optionActivationAnimation.value,
          );
        },
      ),
    );
  }
}

TimerBase getOrCreateTimerWidget(
  Map<MobjID<TimerData>, TimerBase>? timerWidgetCache,
  MobjID<TimerData> id, {
  bool animateIn = false,
}) {
  if (timerWidgetCache != null && timerWidgetCache.containsKey(id)) {
    return timerWidgetCache[id]!;
  }
  final mobj = Mobj.getAlreadyLoaded(id, TimerDataType());
  final widget = mobj.peek()!.isComposite
      ? Timercule(
          key: GlobalKey<TimerculeState>(),
          mobj: mobj,
          animateIn: animateIn,
        )
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

  TimerBase timerScreenGetOrCreateTimerWidget(
    MobjID<TimerData> id, {
    bool animateIn = false,
  }) {
    return getOrCreateTimerWidget(timerWidgetCache, id, animateIn: animateIn);
  }

  late final Mobj<bool> isRightHandedMobj = Mobj.getAlreadyLoaded(
    isRightHandedID,
    BoolType(),
  );
  late final Signal<Rect> numPadBounds = Signal(Rect.zero);
  late final JukeBox jukeBox = JukeBox.create();
  late final TimerHolm timerHolm;
  // note this subscribes to the mobj
  List<MobjID<TimerData>> timers() => timerListMobj.value!;
  List<MobjID<TimerData>> peekTimers() => timerListMobj.peek()!;

  GlobalKey<TimerTrayState> timerTrayKey = GlobalKey<TimerTrayState>();
  GlobalKey pinButtonKey = GlobalKey();
  GlobalKey deleteButtonKey = GlobalKey();
  GlobalKey<SelfRemovalHostState> foregroundEphemeralAnimationLayer =
      GlobalKey();
  GlobalKey<SelfRemovalHostState> backgroundEphemeralAnimationLayer =
      GlobalKey();
  final Mobj<List<MobjID<TimerData>>> timerListMobj = Mobj.getAlreadyLoaded(
    timerListID,
    timerListType,
  );
  final Mobj<List<MobjID<TimerData>>> binListMobj = Mobj.getAlreadyLoaded(
    binListID,
    timerListType,
  );
  // final Mobj<List<MobjID<TimerData>>> transientTimerListMobj =
  //     Mobj.getAlreadyLoaded(transientTimerListID, timerListType);
  late final Mobj<double> nextHueMobj = Mobj.getAlreadyLoaded(
    nextHueID,
    DoubleType(),
  );
  late final Mobj<bool> buttonScaleDialOn = Mobj.getAlreadyLoaded(
    buttonScaleDialOnID,
    BoolType(),
  );
  late final Mobj<double> buttonSpanMobj = Mobj.getAlreadyLoaded(
    buttonSpanID,
    DoubleType(),
  );
  final List<GlobalKey<TimersButtonState>> numeralKeys =
      List<GlobalKey<TimersButtonState>>.generate(10, (i) => GlobalKey());
  final GlobalKey modeHighlightAnimoveKey = GlobalKey();
  final Signal<Offset> modeHighlightAnchor = Signal(Offset.zero);
  late AnimationController modeLivenessAnimation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 200),
  );
  // emits whenever a drag action ring is created, so that older ones can disable themselves
  late final ChangeNotifier onNewNumeralDragActionRing = ChangeNotifier();
  late final Computed<bool> timerculeCurrentlyDeployed = Computed(
    () => timerListMobj.value!.any(
      // we peek, because the type of a timer never changes, so this shouldn't recompute every time a root timerdata changes
      (id) => Mobj.getAlreadyLoaded(id, TimerDataType()).peek()!.isComposite,
    ),
  );
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
        timerculeCurrentlyDeployed.value &&
        !(Mobj.getAlreadyLoaded(hintGetsCompositeTimersID, BoolType()).value ??
            false),
    // these were a bunch of conditions that would prevent it from being annoying despite it being shown appropos of nothing. Since we're showing it only appropos of the presence of a timercule, we no longer have to be careful in that way
    // // doesn't appear until the other two hints are solved
    // !userDragActionHintCondition.value &&
    // hasUsedMenuTwice.value &&
    // // also goes away if the user just uses timers and ignores the timercule feature
    // (Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType()).value! <
    //     10) &&
    // // user has been using the app for less than 7 days. This is an imperfect condition and we should probably track the number of timers they've created instead.
    // // (DateTime.now()
    // //         .difference(
    // //             Mobj.getAlreadyLoaded(timeFirstUsedApp, DateTimeType())
    // //                 .value!)
    // //         .inDays <
    // //     7) &&
    // !(Mobj.getAlreadyLoaded(hintGetsCompositeTimersID, BoolType()).value ??
    //     false),
    autoDispose: true,
  );
  late final AnimationController buttonScaleDialAnimation = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 200),
  );
  late final AnimationController buttonScaleFlashAnimation =
      AnimationController(vsync: this, duration: Duration(milliseconds: 1600));
  late final Signal<Offset?> buttonScaleDialCenter = Signal(Offset.zero);
  final GlobalKey specialTimerCreateButtonKey = GlobalKey();
  late final Signal<double> buttonScaleDialAngle = Signal(0.0);
  async.Timer? buttonScaleDialLeavingTimer;
  final Map<MobjID, Function()> _timerDeletionSubs = {};
  late final Signal<int> currentlyPressingKey = Signal(0);
  // whether the edit popover (and its pip icons) should be popped up: a plain
  // timer is selected and the user has released the key at least once. Hoisted
  // to a Computed so consumers can Watch it directly — synchronous flips (e.g. a
  // numeral drag that starts a timer) coalesce into a single frame-time rebuild
  // instead of flashing an eagerly-driven animation.
  late final Computed<bool> editPopoversUp = Computed(() {
    final sv = selectedTimer.value;
    final timerData = sv != null
        ? Mobj.getAlreadyLoaded(sv, TimerDataType()).value
        : null;
    return timerData != null &&
        timerData.kind == TimerKind.timer &&
        (!isFirstPressForSelectedTimer.value ||
            currentlyPressingKey.value == 0);
  });
  late final ScrollController timersScroller = ScrollController();
  late final AnimationController squishPanelController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 16000),
  );
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
    persistent: true,
    useSpringExpansion: true,
    clipBuilder: arcDragRingClip,
    radialActivatorFunctions: [
      addNewStopwatch,
      () => addNewCompositeTimer(TimerKind.loop),
      () => addNewCompositeTimer(TimerKind.series),
      () => addNewCompositeTimer(TimerKind.parallelStartJustified),
      () => addNewCompositeTimer(TimerKind.parallelEndJustified),
    ],
    radialActivatorPositions: List.generate(5, decAngleFor),
    radialActivatorIcons: [
      Container(
        width: dragActionRingIconSize.width,
        height: dragActionRingIconSize.height,
        decoration: ShapeDecoration(
          shape: StarBorder.polygon(
            sides: 8,
            pointRounding: 0.5,
            rotation: 45 / 2,
          ),
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
      Builder(
        builder: (context) => CustomPaint(
          size: dragActionRingIconSize,
          painter: TimerculeCyclePainter(
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ),
      Builder(
        builder: (context) => CustomPaint(
          size: dragActionRingIconSize,
          painter: TimerculeSerialPainter(
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ),
      Builder(
        builder: (context) => CustomPaint(
          size: dragActionRingIconSize,
          painter: TimerculeParallelPainter(
            color: Theme.of(context).colorScheme.onPrimary,
            rightJustified: false,
          ),
        ),
      ),
      Builder(
        builder: (context) => CustomPaint(
          size: dragActionRingIconSize,
          painter: TimerculeParallelPainter(
            color: Theme.of(context).colorScheme.onPrimary,
            rightJustified: true,
          ),
        ),
      ),
    ],
    radialActivatorLabels: const [
      Text('stopwatch'),
      Text('cycle'),
      Text('series'),
      Text('simultaneous start'),
      Text('simultaneous end'),
    ],
  );
  late final StreamController<void> modeActivationPulse =
      StreamController<void>.broadcast();

  @override
  void initState() {
    super.initState();

    timerHolm = globalTimerHolm = TimerHolm(
      list: timerListMobj,
      jukeBox: jukeBox,
    );

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
          selectedTimer.value =
              null; // note, this will recurse on this effect handler, we don't want that, but it's harmless
        }
      }
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
    Widget menuItem(
      BuildContext context,
      bool isRightHanded,
      Widget icon,
      String label,
      Function(Offset?) action, {
      bool isFirst = false,
      bool isLast = false,
      TextStyle? labelStyle,
    }) {
      return InkButton(
        backgroundColor: backgroundColor,
        inkColor: inkColor.withValues(alpha: 0.6),
        inkColorFaded: inkColor.withValues(alpha: 0.3),
        onTapUpGlobalPosition: action,
        onTap: () {
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: EdgeInsets.only(
            top: isFirst ? (menuItemPadding + arrowHeight) : 0,
            bottom: isLast ? menuItemPadding : 0,
            left: menuItemPadding,
            right: menuItemPadding,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: isRightHanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            children: reverseIfNot(isRightHanded, [
              SizedBox(
                width: TimerMenu.buttonHeight,
                height: TimerMenu.buttonHeight,
                child: Center(child: icon),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(
                    label,
                    style:
                        labelStyle ??
                        theme.textTheme.bodyMedium!.copyWith(
                          color: foregroundColor,
                        ),
                  ),
                ),
              ),
              SizedBox(width: TimerMenu.buttonHeight * 0.2),
            ]),
          ),
        ),
      );
    }

    double totalVisibleMenuItemHeight =
        TimerMenu.buttonHeight * 5 + 14 + menuItemPadding * 2;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Timer menu',
      barrierColor: mt.lowestBackColor.withAlpha(0),
      transitionDuration: Duration(milliseconds: 370),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
      pageBuilder: (context, animation, secondaryAnimation) {
        return Watch((context) {
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
                'Delete',
                (_) {
                  deleteTimer(timerID);
                },
                isFirst: true,
              ),
              SeparatorGradient(color: indentColor),
              menuItem(
                context,
                isRightHanded,
                Transform.rotate(
                  angle: -pi / 2,
                  child: Icon(
                    Icons.rotate_90_degrees_cw_rounded,
                    color: foregroundColor,
                  ),
                ),
                'Reset',
                (_) {
                  resetTimer(timerID);
                },
              ),
              menuItem(
                context,
                isRightHanded,
                Icon(Icons.push_pin, color: foregroundColor),
                'Pin',
                (_) {
                  togglePin(timerID);
                },
              ),
              Builder(
                builder: (context) {
                  return menuItem(
                    context,
                    isRightHanded,
                    Icon(Icons.music_note, color: foregroundColor),
                    td.soundEffect?.name ?? 'default',
                    (tapPoint) {
                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                        final result = await Navigator.push<AudioInfo?>(
                          this.context,
                          CircularRevealRoute(
                            builder: (context) => AlarmSoundPickerScreen(
                              perTimerMode: true,
                              initialPerTimerSelection: td.soundEffect,
                            ),
                            buttonCenter: tapPoint,
                          ),
                        );
                        final mobj = Mobj.getAlreadyLoaded(
                          timerID,
                          TimerDataType(),
                        );
                        mobj.value = mobj.peek()!.withChanges(
                          soundEffect: result,
                          soundEffectNull: result == null,
                        );
                      });
                    },
                    labelStyle: td.soundEffect == null
                        ? theme.textTheme.bodyMedium!.copyWith(
                            color: foregroundColor.withValues(alpha: 0.5),
                          )
                        : null,
                  );
                },
              ),
              menuItem(
                context,
                isRightHanded,
                Icon(Icons.label_outline, color: foregroundColor),
                'Title',
                (_) {
                  final wk =
                      timerWidgetCache[timerID]?.key
                          as GlobalKey<TimerBaseState>?;
                  wk?.currentState?.enterTitleEditMode();
                },
                isLast: true,
              ),
            ],
          );
        });
      },
    );
  }

  void takeActionOn(MobjID<TimerData> timerID) {
    String mode = actionMode.peek();
    if (mode == 'pin') {
      togglePin(timerID);
    } else if (mode == 'delete') {
      deleteTimer(timerID);
    } else {
      mode = 'play';
      toggleRunning(
        Mobj.getAlreadyLoaded(timerID, TimerDataType()),
        reset: false,
      );
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

  void numeralPressed(List<int> number) {
    if (selectedTimer.peek() == null) {
      isFirstPressForSelectedTimer.value = true;
      addNewTimer(selected: true, digits: stripZeroes(number));
    } else {
      isFirstPressForSelectedTimer.value = false;
      final mt = Mobj.getAlreadyLoaded(selectedTimer.peek()!, TimerDataType());
      List<int> ct = List.from(mt.peek()!.digits);
      for (int n in number) {
        ct.add(n);
      }
      mt.value = mt.peek()!.withChanges(digits: ct);
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
      numeralPressed([kn]);
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
    final bottomGutter = max(
      thumbSpan * 0.3,
      MediaQuery.of(context).padding.bottom,
    );
    final bool padLandscape =
        watchSignal(
          context,
          Mobj.getAlreadyLoaded(padLandscapeID, BoolType()),
        ) ??
        false;
    final int padWidth = padLandscape ? 4 : 3;
    final controlsh = bottomGutter + 4 * buttonSpan;
    // Calculate the vertical space generally taken by Timer widgets (tallest, including padding).
    final timerHeight = Timer.usualHeight();
    bool isRightHanded = watchSignal(context, isRightHandedMobj)!;

    Widget iconScaledToPip(Widget icon) {
      return Watch((context) {
        final up = editPopoversUp.value;
        return TweenAnimationBuilder<double>(
          // a transient flip of `up` within one tick coalesces away, so this
          // never animates toward a target that no longer holds. `t` is linear;
          // opacity uses it directly, scale curves it (per-direction) below.
          tween: Tween<double>(begin: 0.0, end: up ? 1.0 : 0.0),
          duration: up
              ? const Duration(milliseconds: 100) // rise
              : const Duration(milliseconds: 100), // fall
          builder: (context, t, child) {
            final p = (up ? Curves.easeInOut : Curves.easeInOut).transform(t);
            return Opacity(
              // a linear ease is correct for opacity
              opacity: lerp(0.07, 1.0, p),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (p != 1)
                    Container(
                      width: buttonSpan * 0.12,
                      height: buttonSpan * 0.12,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Transform.scale(scale: p, child: child),
                ],
              ),
            );
          },
          child: Center(child: icon),
        );
      });
    }

    Widget proportionedIcon(Widget icon) {
      return ScalingAspectRatio(
        child: SizedBox(width: 50, height: 50, child: Center(child: icon)),
      );
    }

    var specialTimerCreateButton = Builder(
      builder: (context) => TimersButton(
        // label: Icon(Icons.select_all),
        // label: Icon(Icons.border_outer_rounded),
        key: specialTimerCreateButtonKey,
        // label: const SpecialTimerShapesLabel(),
        // the ManyIcon is now drawn by the persistent drag ring (its collapsed
        // phase); this keeps the button's footprint for hit testing only.
        label: const ScalingAspectRatio(child: SizedBox(width: 50, height: 50)),
        onPanDown: (Offset p) {
          specialTimerCreateDragRingController.onPanDown(
            context,
            p,
            boxRect(specialTimerCreateButtonKey)!.center,
          );
        },
        onPanUpdate: (Offset p) {
          specialTimerCreateDragRingController.onPanUpdate(context, p);
        },
        onPanEnd: () {
          specialTimerCreateDragRingController.onPanEnd(context);
        },
      ),
    );

    // todo: animate the play icon out when playing
    Widget playIcon(Icon otherIcon) {
      // todo: measure the width of the icons to make this precise
      double dispf = 0.3;
      return Stack(
        children: [
          FractionalTranslation(
            translation: Offset(-dispf, 0),
            child: otherIcon,
          ),
          Transform.scale(
            scale: 0.8,
            child: FractionalTranslation(
              translation: Offset(dispf, 0),
              child: PaintedPlayIcon(),
            ),
          ),
        ],
      );
    }

    // final pausePlayButton = TimersButton(
    //     label: playIcon(Icon(Icons.pause_rounded)),
    //     onPanDown: (_) {
    //       pausePlaySelected();
    //     });
    // final stopPlayButton = TimersButton(
    //   label: playIcon(Icon(Icons.restart_alt_rounded)),
    //   onPanDown: (_) {
    //     pausePlaySelected(reset: true);
    //   },
    // );

    final buttonScaleDial = Watch((context) {
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
            animation: Listenable.merge([
              buttonScaleDialAnimation,
              buttonScaleFlashAnimation,
            ]),
            builder: (context, child) {
              final fa = buttonScaleFlashAnimation.value;
              double flashu = fa == 1.0 ? 0 : moduloProperly(-fa, 1.0 / 5.0);
              return Transform.scale(
                scale: Curves.easeOutCubic.transform(
                  buttonScaleDialAnimation.value,
                ),
                child: GestureDetector(
                  onPanDown: (details) {
                    buttonScaleDialLeavingTimer?.cancel();
                  },
                  onPanUpdate: (details) {
                    final aa = angleFrom(
                      buttonScaleDialCenter.peek()!,
                      details.globalPosition - details.delta,
                    );
                    final ab = angleFrom(
                      buttonScaleDialCenter.peek()!,
                      details.globalPosition,
                    );
                    final a = shortestAngleDistance(aa, ab);
                    buttonScaleDialAngle.value += a;
                    buttonSpanMobj.value = clampDouble(
                      buttonSpanMobj.value! + a * 1.2,
                      12,
                      screenSize.width / 5,
                    );
                  },
                  onPanEnd: (details) {
                    buttonScaleDialLeavingTimer = async.Timer(
                      Duration(milliseconds: 470),
                      () {
                        buttonScaleDialOn.value = false;
                      },
                    );
                  },
                  child: Transform.rotate(
                    transformHitTests: false,
                    angle: buttonScaleDialAngle.value,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: lerpColor(
                          mt.midBackColor,
                          theme.colorScheme.primary,
                          flashu,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanDown: (details) {},
                          onPanUpdate: (details) {
                            buttonScaleDialCenter.value =
                                buttonScaleDialCenter.value! + details.delta;
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
                              child: Text(
                                "turn me",
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    });

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
    // distance from the anchor (inner-palette column) to the horizontal center of the numeral pad
    final double padCenterOffset = (padWidth + 1) / 2.0 * buttonSpan;
    final imperfection =
        ((tentativeRightPos - padCenterOffset) - screenSize.width / 2) /
        screenSize.width;
    if (imperfection.abs() < 0.034) {
      tentativeRightPos = screenSize.width / 2 + padCenterOffset;
    }
    final topRightControlAnchor = Offset(
      tentativeRightPos,
      screenSize.height - controlsh + buttonSpan / 2,
    );

    // final topLeftPos = topRightPos + Offset(-buttonSpan * 5, 0);
    /// pi and spani are in buttonSpan units
    Rect controlGridBound(Offset pi, Size spani) {
      Offset point = (topRightControlAnchor + pi * buttonSpan);
      if (!isRightHanded) {
        point = Offset(
          screenSize.width - point.dx - (spani.width - 1) * buttonSpan,
          point.dy,
        );
      }
      return ((point - sizeToOffset(buttonSize / 2)) & (spani * buttonSpan));
    }

    final configButton = TimersButton(
      key: configButtonKey,
      label: SizedBox(
        width: buttonSpan * 0.43,
        height: buttonSpan * 0.43,
        child: Hero(
          tag: 'configButton',
          child: HamburgerIcon(
            lineWidth: makoLineThickness,
            color: theme.colorScheme.onSurface,
          ),
        ),
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
      },
    );

    Widget numeralBacking = Positioned.fromRect(
      rect: controlGridBound(
        padLandscape ? Offset(-4, 0) : Offset(-3, 0),
        padLandscape ? Size(4, 3) : Size(3, 4),
      ).deflate(backingDeflation),
      child: Container(
        constraints: BoxConstraints.expand(),
        decoration: BoxDecoration(
          color: mt.foreBackColor,
          borderRadius: BorderRadius.circular(
            backingCornerRounding * buttonSpan,
          ),
        ),
      ),
    );

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
              simulationFactory: (c, t, v) =>
                  TimelyParabolicSimulation(c, t, v, duration: 0.2),
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
                          (a, b) => a + 0.55 * defaultPulserFunction(b),
                        ),
                      );
                      return Container(
                        decoration: BoxDecoration(
                          color: lerpColor(
                            mt.foreBackColor,
                            theme.colorScheme.primary,
                            p,
                          ),
                          borderRadius: BorderRadius.circular(
                            backingCornerRounding * buttonSpan,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      );
    });

    final numeralPartAnchor = Offset(-3, 0);
    final outerPaletteAnchor = Offset(-4, 0);
    final innerPaletteAnchor = Offset(0, 0);
    final numeralColor = theme.colorScheme.onSurface;

    final controls = [
      modalHighlightBacking,
      numeralBacking,
      ...List.generate(9, (i) {
        int ix = i % 3;
        int iy = i ~/ 3;
        if (watchSignal(
          context,
          Mobj.getAlreadyLoaded(padVerticallyAscendingID, BoolType()),
        )!) {
          iy = 2 - iy;
        }
        if (!isRightHanded) {
          ix = 2 - ix;
        }
        final ii = i + 1;
        return Positioned.fromRect(
          rect: controlGridBound(
            numeralPartAnchor + Offset(ix.toDouble(), iy.toDouble()),
            Size(1, 1),
          ),
          child: NumeralButton(
            digits: [ii],
            timerButtonKey: numeralKeys[ii],
            otherDragActionRingStarted: onNewNumeralDragActionRing,
          ),
        );
      }),
      Positioned.fromRect(
        rect: controlGridBound(
          numeralPartAnchor + (padLandscape ? Offset(-1, 0) : Offset(0, 3)),
          Size(1, 1),
        ),
        child: NumeralButton(
          digits: [0],
          timerButtonKey: numeralKeys[0],
          otherDragActionRingStarted: onNewNumeralDragActionRing,
        ),
      ),
      Positioned.fromRect(
        rect: controlGridBound(innerPaletteAnchor + Offset(0, 0), Size(1, 1)),
        child: specialTimerCreateButton,
      ),
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
        child: configButton,
      ),
      // // squish button
      // Positioned.fromRect(
      //   rect: controlGridBound(innerPaletteAnchor + Offset(0, 2), Size(1, 1)),
      //   child: TimersButton(
      //     label: proportionedIcon(Icons.view_sidebar_outlined),
      //     onPanEnd: () {

      //       // if (squishPanelController.status == AnimationStatus.forward ||
      //       //     squishPanelController.status == AnimationStatus.completed) {
      //       //   squishPanelController.reverse();
      //       // } else {
      //       //   squishPanelController.forward();
      //       // }
      //     },
      //   ),
      // ),
    ];

    Widget editFadeButton(Offset gridPos, Widget button, int i) {
      return Positioned.fromRect(
        rect: controlGridBound(gridPos, Size(1, 1)),
        child: Watch(
          (context) =>
              IgnorePointer(ignoring: !editPopoversUp.value, child: button),
        ),
      );
    }

    final editBackspaceButton = editFadeButton(
      padLandscape ? Offset(-4, 1) : Offset(-2, 3),
      TimersButton(
        label: proportionedIcon(
          iconScaledToPip(PaintedBackspaceIcon(size: 12, color: numeralColor)),
        ),
        onPanDown: (_) {
          // without this, currentlyPressingKey going to 1 would briefly close the buttons (and ignore the press) while isFirstPressForSelectedTimer is still true
          isFirstPressForSelectedTimer.value = false;
          _backspace();
        },
      ),
      0,
    );
    final editPlayButton = editFadeButton(
      padLandscape ? Offset(-4, 2) : Offset(-1, 3),
      TimersButton(
        label: proportionedIcon(
          iconScaledToPip(PaintedPlayIcon(size: 10, color: numeralColor)),
        ),
        onPanDown: (_) {
          isFirstPressForSelectedTimer.value = false;
          pausePlaySelected();
        },
      ),
      1,
    );

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
          Builder(
            builder: (context) {
              final dir = isRightHanded ? "left" : "right";
              return HintToast(
                showCondition: userDragActionHintCondition,
                message:
                    """when you press a number, you can drag up or to the $dir. this will activate the new timer. (dragging $dir adds a pair of zeroes to it before activating it.)""",
              );
            },
          ),
          HintToast(
            showCondition: hasUsedMenuTwice,
            message:
                "you can press and hold (and release) a timer to bring open a menu that allows additional actions (such as deleting or editing it)",
          ),
          HintToast(
            showCondition: hintGetsCompositeTimersCondition,
            message:
                "'timercules' like 'cycle' and 'series' allow you to drag other timers into them, to build structures. You can use those to create pomodoro timers, which some people find useful for productivity and focus, or multi-stage sequence timers, which are useful for carrying out complex recipes with precise timings. Play around with them.",
          ),
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
            systemNavigationBarDividerColor: mt.lowestBackColor.withAlpha(0),
            systemNavigationBarColor: mt.lowestBackColor.withAlpha(0),
            systemNavigationBarIconBrightness:
                theme.brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: child,
        ),
        (child) => Scaffold(
          backgroundColor: mt.lowestBackColor,
          resizeToAvoidBottomInset: false,
          body: child,
        ),
        // Scrim behind a transparent status bar — rarely visible since the
        // timer UI sits below it, but keeps contrast if content reaches the top.
        (child) => Stack(
          children: [
            child,
            StatusBarScrim(background: mt.lowestBackColor),
          ],
        ),
        (child) => Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (FocusManager.instance.primaryFocus != node) {
              return KeyEventResult.ignored;
            }
            _handleKeyPress(event);
            return KeyEventResult.handled;
          },
          child: child,
        ),
        // the dragtarget for the timer tray encompasses the entire TimerScreen so that you can drop above or below the widget to get above or below the top or bottom row. Otherwise, this can be difficult or impossible, which is a problem when you consider timercules, which unlike timers, can't be dragged after by dragging onto the second half
        (child) => DragTarget<GlobalKey<TimerBaseState>>(
          builder: (context, candidateData, rejectedData) => child,
          onMove: (DragTargetDetails<GlobalKey<TimerBaseState>> details) {},
          onAcceptWithDetails: (details) {
            final wrapKey = timerTrayKey.currentState!.wrapKey;
            final p = timerListMobj.peek()!;
            final insertion = insertionOf(wrapKey, details.offset);
            final timerId = (details.data.currentWidget! as TimerBase).mobj.id;
            final currentIndex = p.indexWhere((t) => t == timerId);
            final Mobj<TimerData> cm =
                (details.data.currentWidget! as TimerBase).mobj;
            doInsertion(int at) {
              writeBackChildren(timerListMobj, p.toList()..insert(at, timerId));
            }

            //transaction start
            if (cm.peek()!.parentId == null) {
              doInsertion(insertion.midwayInsertionIndex());
            } else {
              final oldList = Mobj.seekTypedsAlreadyLoaded(
                cm.peek()!.parentId!,
                [TimerDataType(), ListType(StringType())],
              )!;
              final oldChildren = childrenOf(oldList);
              final oldIndex = oldChildren.indexOf(timerId);
              simpleRemove() {
                writeBackChildren(
                  oldList,
                  oldChildren.toList()..removeAt(oldIndex),
                );
              }

              if (cm.peek()!.parentId == timerListMobj.id) {
                assert(
                  currentIndex != -1,
                  "item wasn't found inside of its owningList",
                );
                if (insertion.index != currentIndex) {
                  final (operative, at) = insertion.cleverInsertionIndexFor(
                    currentIndex,
                    p.length,
                  );
                  if (operative) {
                    timerListMobj.value = p.toList()
                      ..insert(at, timerId)
                      ..removeAt(
                        currentIndex > at ? currentIndex + 1 : currentIndex,
                      );
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
          },
        ),
      ],
      SelfRemovalHost(
        key: backgroundEphemeralAnimationLayer,
        builder: (children, context) {
          return Stack(
            children: [
              ...children,
              SelfRemovalHost(
                key: foregroundEphemeralAnimationLayer,
                builder: (children, context) => ConstrainedBox(
                  constraints: BoxConstraints.expand(),
                  child: Stack(
                    children:
                        [
                          hintTray,
                          Positioned.fill(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                AnimatedBuilder(
                                  animation: squishPanelController,
                                  builder: (context, child) {
                                    final w =
                                        screenSize.width *
                                        0.7 *
                                        squishPanelController.value;
                                    return SizedBox(
                                      width: w,
                                      child: w <= 0
                                          ? null
                                          : SquishBoundaryPlane(
                                              theme: theme,
                                              mt: mt,
                                            ),
                                    );
                                  },
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    controller: timersScroller,
                                    reverse: true,
                                    child: Column(
                                      children: [
                                        SizedBox(
                                          height:
                                              screenSize.height -
                                              controlsh -
                                              timerHeight,
                                        ),
                                        timersWidget,
                                        SizedBox(height: controlsh),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ...controls,
                          editBackspaceButton,
                          editPlayButton,
                          buttonScaleDial,
                          specialTimerCreateDragRingController
                              .buildPersistentRing(
                                key: const ValueKey('specialTimerRing'),
                                visualCenter: controlGridBound(
                                  innerPaletteAnchor + Offset(0, 0),
                                  Size(1, 1),
                                ).center,
                              ),
                        ] +
                        children,
                  ),
                ),
                // we stack a bunch of stuff here that's not ephemeral because that's allowed
              ),
            ],
          );
        },
      ),
    );
  }

  void pausePlaySelected({bool reset = false}) {
    final id = selectedTimer.peek();
    if (id != null) {
      if (toggleRunning(
        Mobj.getAlreadyLoaded(id, TimerDataType()),
        reset: reset,
      )) {
        _selectTimer(null);
      }
    }
  }

  void addNewTimer({int? runningState, bool? selected, List<int>? digits}) {
    final ntid = UuidV4().generate();

    bool selecting = selected ?? false;

    // we leak this. By not deleting it, it will stay in the db and registry as a root object
    Mobj<TimerData>.clobberCreate(
      ntid,
      type: TimerDataType(),
      initial: TimerData(
        startTime: null,
        runningState: runningState ?? TimerData.completed,
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

    timersScroller.animateTo(
      0,
      duration: Duration(milliseconds: 180),
      curve: Curves.easeInOutCubic,
    );
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

    timersScroller.animateTo(
      0,
      duration: Duration(milliseconds: 180),
      curve: Curves.easeInOutCubic,
    );
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
        parentId: timerListMobj.id,
      ),
    );
    timerListMobj.value = peekTimers().toList()..add(ntid);
    final n = Mobj.getAlreadyLoaded(numberOfTimersCreatedID, IntType());
    n.value = n.peek()! + 1;

    cleanOldTimers(except: ntid);
    timersScroller.animateTo(
      0,
      duration: Duration(milliseconds: 180),
      curve: Curves.easeInOutCubic,
    );
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
      final oldMobj = Mobj.getAlreadyLoaded(
        selectedTimer.peek()!,
        TimerDataType(),
      );
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
      final mobj = Mobj.getAlreadyLoaded(
        selectedTimer.peek()!,
        TimerDataType(),
      );
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
    // everything the user deletes goes to the trash bin so it can be restored;
    // it's only truly destroyed later by the bin's pruning. (The cascade that
    // really nulls a composite's children on final deletion lives in
    // enlivenTimer, not here.)
    binTimer(ki);
  }

  /// Shelves a timer into the trash bin: keeps its Mobj (and, for a composite,
  /// its children) alive but inactive, pulls it off the screen with the usual
  /// disappearance animation, detaches it from its parent (the timer list, or
  /// the composite it lived in), and remembers it in [binListMobj] so it can be
  /// restored. Also prunes anything that's overstayed its welcome.
  void binTimer(MobjID<TimerData> ki) {
    final mobj = Mobj.getAlreadyLoaded(ki, TimerDataType());
    final d = mobj.peek();
    if (d == null) return;
    // stop it running so it doesn't keep ticking / fire an alarm while shelved
    if (d.isRunning) {
      pauseTimer(mobj, reset: false);
    }
    // play the slide-up exit animation on the live widget before it leaves its
    // tray (it gets lifted into the ephemeral overlay, so detaching it from the
    // list below won't collide with it)
    final exiting = timerWidgetCache[ki];
    final exitingState = (exiting?.key as GlobalKey?)?.currentState;
    if (exitingState is TimerBaseState) {
      exitingState.playExitAnimation();
    }
    // detach from whatever was holding it — the root timer list or a composite
    final parent = Mobj.seekTypedsAlreadyLoaded(d.parentId!, [
      TimerDataType(),
      ListType(StringType()),
    ]);
    if (parent != null && parent.peek() != null) {
      writeBackChildren(parent, childrenOf(parent).toList()..remove(ki));
    }
    if (selectedTimer.peek() == ki) {
      _selectTimer(null);
    }
    // shelve it: kept in the db but not preloaded next launch, and appended to
    // the bin (newest last, matching how the timer list appends new timers so
    // the tray lays them out the same way)
    mobj.isActive = false;
    binListMobj.value = [...binListMobj.peek()!, ki];
    cleanBin();
  }

  /// How long a deleted timer lingers in the trash bin before it's destroyed.
  static const Duration binRetention = Duration(days: 2);

  /// Destroys binned timers whose deletion (last write-back) was more than
  /// [binRetention] ago. Runs opportunistically each time something is binned.
  /// Loads the (inactive) timers from disk to read their timestamps, since
  /// older ones may not be in memory yet.
  Future<void> cleanBin() async {
    final now = DateTime.now();
    for (final id in binListMobj.peek()!.toList()) {
      Mobj<TimerData> m;
      try {
        m = await Mobj.fetch(id, type: TimerDataType());
      } catch (_) {
        // already gone from the db; just drop the dangling reference
        binListMobj.value = binListMobj.peek()!.toList()..remove(id);
        continue;
      }
      if (now.difference(m.lastTimestamp) > binRetention) {
        binListMobj.value = binListMobj.peek()!.toList()..remove(id);
        // a real deletion this time: cascades to children / parent via reactions
        m.value = null;
      }
    }
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
  final Path Function(DragRingClipArgs args) clipBuilder;

  /// when true, the ring is rendered permanently by [buildPersistentRing]
  /// instead of being added to a SelfRemovalHost on pan-down.
  final bool persistent;

  /// whether to shunt text to the right or to the left, when the angle is close to a vertical position. Important for radial menus that're closer to the side of the screen. It's with respect to handedness, the meaning flips when the handedness flips.
  final bool? shuntRight;

  final bool useSpringExpansion;

  DragActionRingController({
    this.suppressingNotifier,
    required this.radialActivatorFunctions,
    required this.radialActivatorPositions,
    this.radialActivatorLabels,
    required this.radialActivatorIcons,
    required this.clipBuilder,
    this.persistent = false,
    this.shuntRight,
    this.useSpringExpansion = false,
  }) {
    assert(
      radialActivatorIcons.length == radialActivatorPositions.length,
      'DragActionRingController: radialActivatorIcons and radialActivatorPositions should have the same length',
    );
    assert(
      radialActivatorFunctions.length == radialActivatorIcons.length,
      'DragActionRingController: radialActivatorFunctions and radialActivatorIcons should have the same length',
    );
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
        'DragActionRingController: We require a SelfRemovalHostState as an ancestor of the context given to onPanDown, so that the DragActionRing we create can live in.',
      );
    }
    return srh;
  }

  /// builds the always-rendered ring for [persistent] controllers; place it in
  /// the same Stack as the rest of the controls, centered on [visualCenter]. The
  /// host keeps one live ring plus any rings that are retiring after a commit.
  Widget buildPersistentRing({required Offset visualCenter, Key? key}) {
    return _PersistentDragRingHost(
      key: key,
      controller: this,
      visualCenter: visualCenter,
    );
  }

  /// builds one ring for the [_PersistentDragRingHost]: a live one (which calls
  /// [onRetire] when its selection lands) or a retiring one (which thins itself
  /// out, then calls [onRetireComplete]).
  Widget buildPersistentRingInstance({
    required Key key,
    required Offset visualCenter,
    required bool retiring,
    VoidCallback? onRetire,
    VoidCallback? onRetireComplete,
  }) {
    return DragActionRing(
      key: key,
      persistent: true,
      retiring: retiring,
      onRetire: onRetire,
      onRetireComplete: onRetireComplete,
      position: visualCenter,
      visualPosition: visualCenter,
      suppressionBus: suppressingNotifier,
      dragEvents: _dragEvents,
      shuntRight: shuntRight,
      radialActivatorIcons: radialActivatorIcons,
      radialActivatorLabels: radialActivatorLabels,
      radialActivatorPositions: radialActivatorPositions,
      clipBuilder: clipBuilder,
      useSpringExpansion: useSpringExpansion,
    );
  }

  void onPanDown(
    BuildContext context,
    Offset touchOrigin,
    Offset visualCenter,
  ) {
    dragActionRingDisabled = false;
    _startDrag = touchOrigin;

    // setting -1 opens the ring (the persistent one is already mounted).
    _dragEvents.value = -1;
    if (persistent) return;

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
      clipBuilder: clipBuilder,
      useSpringExpansion: useSpringExpansion,
    );
    getSelfRemovalHostState(context).add(numeralDragActionRing);
  }

  void onPanUpdate(BuildContext context, Offset p) {
    Offset dp = p - _startDrag;
    if (!dragActionRingDisabled) {
      if (dp.distance > Thumbspan.of(context) * 0.3) {
        bool isRightHanded = Mobj.getAlreadyLoaded(
          isRightHandedID,
          BoolType(),
        ).peek()!;
        final rectifiedActivatorPositions = isRightHanded
            ? radialActivatorPositions
            : radialActivatorPositions.map(flipAngleHorizontally).toList();
        _dragEvents.value = radialDragResult(
          rectifiedActivatorPositions,
          offsetAngle(dp),
          hitSpan: pi,
        );
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

/// hosts a persistent drag ring: one live ring (rebuilt each frame so it tracks [visualCenter]) plus any rings that committed and are now thinning themselves away. On a commit the live ring keeps its element/state (matched by key) and slides into the retiring list, while a fresh live ring is stood up in its place.
class _PersistentDragRingHost extends StatefulWidget {
  final DragActionRingController controller;
  final Offset visualCenter;
  const _PersistentDragRingHost({
    super.key,
    required this.controller,
    required this.visualCenter,
  });
  @override
  State<_PersistentDragRingHost> createState() =>
      _PersistentDragRingHostState();
}

class _PersistentDragRingHostState extends State<_PersistentDragRingHost> {
  Key _liveKey = UniqueKey();

  /// rings that have committed and are playing down. Their center is frozen at commit time; the live ring keeps tracking [_PersistentDragRingHost.visualCenter].
  final List<({Key key, Offset center})> _retiring = [];

  void _retireLive() {
    setState(() {
      _retiring.add((key: _liveKey, center: widget.visualCenter));
      _liveKey = UniqueKey();
    });
  }

  void _onRetireComplete(Key key) {
    if (!mounted) return;
    setState(() => _retiring.removeWhere((r) => r.key == key));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final r in _retiring)
          widget.controller.buildPersistentRingInstance(
            key: r.key,
            visualCenter: r.center,
            retiring: true,
            onRetireComplete: () => _onRetireComplete(r.key),
          ),
        widget.controller.buildPersistentRingInstance(
          key: _liveKey,
          visualCenter: widget.visualCenter,
          retiring: false,
          onRetire: _retireLive,
        ),
      ],
    );
  }
}

class NumeralButton extends StatefulWidget {
  final List<int> digits;
  final GlobalKey<TimersButtonState>? timerButtonKey;
  final ChangeNotifier otherDragActionRingStarted;
  const NumeralButton({
    super.key,
    required this.digits,
    this.timerButtonKey,
    required this.otherDragActionRingStarted,
  });
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
      clipBuilder: circlesDragRingClip,
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
            final ts =
                (tss.timerWidgetCache[lti]?.key as GlobalKey<TimerState>?)
                    ?.currentState;
            ts?._slideActivateBounceAnimation.forward(from: 0);
            ts?._slideBounceDirection = Offset.fromDirection(
              rectifiedActivatorPositions[i],
              1,
            );
          }
        },
      ),
      radialActivatorPositions: numericRadialActivatorPositions,
      radialActivatorIcons: [
        PaintedPlayIcon(size: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 0,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            PaintedPlayIcon(size: 12),
            SizedBox(width: 4),
            Text('+00', style: TextStyle(fontSize: 22)),
          ],
        ),
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
        widget.otherDragActionRingStarted.addListener(
          dragActionRingController.disable,
        );
        dragActionRingController.onPanDown(
          context,
          p,
          boxRect(widget.timerButtonKey! as GlobalKey)!.center,
        );
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
  fontSize: 40,
  fontWeight: FontWeight.normal,
  fontFamily: 'DongleLatin',
);

class TimersButton extends StatefulWidget {
  /// either a String or a Widget
  final Object label;
  final VoidCallback? onTap;
  final Function(Offset globalPosition)? onPanDown;
  final Function(Offset globalPosition)? onPanUpdate;
  final Function()? onPanEnd;
  final bool solidColor;
  final Animation<double>? dialBloomAnimation;

  const TimersButton({
    super.key,
    required this.label,
    this.onTap,
    this.solidColor = false,
    this.onPanDown,
    this.onPanUpdate,
    this.onPanEnd,
    this.dialBloomAnimation,
  });

  @override
  State<TimersButton> createState() => TimersButtonState();
}

class TimersButtonState extends State<TimersButton> {
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
              ? (details) => widget.onPanUpdate?.call(details.globalPosition)
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
          constraints: BoxConstraints(
            maxWidth: buttonSpan,
            maxHeight: buttonSpan,
          ),
          child: child,
        ),
      ],
      Builder(
        builder: (context) {
          final backingColor = widget.solidColor
              ? theme.colorScheme.surfaceContainerLowest
              : Colors.white.withAlpha(0);
          final backing = Container(
            decoration: BoxDecoration(
              color: backingColor,
              border: Border.all(
                width: standardLineWidth,
                color: Colors.transparent,
              ),
              // borderRadius: BorderRadius.circular(9)
            ),
          );
          final Widget labelWidget;
          if (widget.label is String) {
            labelWidget = Center(
              child: Text(widget.label as String, style: controlPadTextStyle),
            );
          } else {
            labelWidget = widget.label as Widget;
          }
          return Center(
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [backing, labelWidget],
            ),
          );
        },
      ),
    );
  }
}

class NumpadTypeIndicator extends StatelessWidget {
  final bool isAscending;
  final Color? color;
  final double width;

  const NumpadTypeIndicator({
    super.key,
    required this.isAscending,
    this.color,
    this.width = 100.0,
  });

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
          final widg = Text(
            (index + 1).toString(),
            style: TextStyle(
              fontSize: fontSize,
              color: color,
              fontWeight: index == 0 ? FontWeight.w900 : FontWeight.w400,
              fontFamily: 'DongleLatin',
            ),
          );
          // : Icon(Icons.circle, size: 3.0, color: theme.colorScheme.primary);
          final x = index % 3;
          int y = index ~/ 3;
          int py = isAscending ? 2 - y : y;
          return AnimatedPositioned(
            key: ValueKey((x, y)),
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: cellSpan / 2 + x * cellSpan,
            top: cellSpan / 2 + py * cellSpan,
            child: FractionalTranslation(
              translation: Offset(-0.5, -0.5),
              child: Transform.scale(scale: fontScale, child: widg),
            ),
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
  ThemeData theme,
  bool flipBackgroundColors,
) {
  if (flipBackgroundColors) {
    return (
      theme.colorScheme.surfaceContainerLow,
      theme.colorScheme.surfaceContainerLowest,
    );
  } else {
    return (
      theme.colorScheme.surfaceContainerLowest,
      theme.colorScheme.surfaceContainerLow,
    );
  }
}

// Shared style/structure between the settings top title, the settings section
// headings, and the info sub-page (About, How it was made) headers. The label
// sits at the bottom-left of a band of `background`, its left edge aligned with
// the list item titles (matches listItemPadding.left).
const headingBandLeftInset = 16.0;
const headingTitleBottomPadding = 14.0;

TextStyle headingTextStyle(ThemeData theme, {bool fade = false}) => TextStyle(
  color: fade
      ? MakoThemeData.fromTheme(theme).reducedProminenceColor
      // lerpColor(
      //     theme.colorScheme.onSurfaceVariant,
      //     theme.colorScheme.surface,
      //     0.3,
      //   )
      : theme.colorScheme.onSurfaceVariant,
  fontSize: 19,
);

Widget headingBand({
  required ThemeData theme,
  Widget? label,
  required double height,
  required Color background,
  bool fade = false,
}) => Container(
  width: double.infinity,
  height: height,
  color: background,
  alignment: Alignment.bottomLeft,
  padding: const EdgeInsets.only(
    left: headingBandLeftInset,
    bottom: headingTitleBottomPadding,
  ),
  child: label != null
      ? DefaultTextStyle(
          style: headingTextStyle(theme, fade: fade),
          child: label,
        )
      : null,
);

// Geometry of the floating corner back button (and the matching gutter band
// settings leaves for it at the bottom of its list).
const backNavSpan = 67.0;
const backNavGap = 15.0;
const backNavGutterHeight = backNavSpan + backNavGap * 2;
const chevronSpan = 14.0;
const arrowBoxLineThickness = 3.0;

/// Floating back button that sits in the bottom corner closest to the user's
/// dominant hand (bottom-left when right-handed, bottom-right when not), its
/// outer corner matched concentrically to the phone's screen corner. Shared by
/// Settings and the info sub-pages (About, How it was made), which use a
/// [headingBand] header rather than a Flutter app bar and so have no built-in
/// back affordance. Expects to be placed as a child of a [Stack].
class CornerBackButton extends StatelessWidget {
  /// The button's fill — usually the page's heading band colour.
  final Color background;
  const CornerBackButton({super.key, required this.background});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRightHandedMobj = Mobj.getAlreadyLoaded(
      isRightHandedID,
      BoolType(),
    );
    return Positioned.fill(
      child: SafeArea(
        child: Watch((context) {
          final isRightHanded = isRightHandedMobj.value ?? true;
          final corners = getCachedCornerRadius();
          // Match the background's nearest corner to the phone's screen
          // corner so they sit concentrically, shrunk by the gap between
          // the screen edge and the background.
          final screenCorner = isRightHanded
              ? corners.bottomLeft
              : corners.bottomRight;
          final backgroundCornerRadius = screenCorner - backNavGap;
          return AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: isRightHanded
                ? Alignment.bottomLeft
                : Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(backNavGap),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(backgroundCornerRadius),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkButton(
                  backgroundColor: background,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: SizedBox(
                    width: backNavSpan,
                    height: backNavSpan,
                    child: Center(
                      child: ChevronBackIcon(
                        size: Size(chevronSpan, chevronSpan),
                        lineWidth: arrowBoxLineThickness,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Bottom-of-scroll spacer that clears the floating [CornerBackButton] so the
/// last item in a scroll view isn't permanently obscured by it. The band is
/// [backNavGutterHeight] tall (the button's footprint), with room for the
/// bottom safe-area inset below it. Pass [background] to tint the band so it
/// reads as a tray for the button, matching the button's fill.
class BackNavBottomGutter extends StatelessWidget {
  final Color? background;
  const BackNavBottomGutter({super.key, this.background});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: double.infinity,
        height: backNavGutterHeight,
        color: background,
      ),
      SizedBox(height: MediaQuery.of(context).padding.bottom),
    ],
  );
}

/// Translucent gradient behind a transparent OS status bar, fading from the
/// page [background] at the very top down to transparent, so app content keeps
/// contrast against the status-bar clock/icons floating over it. Sized to the
/// top safe-area inset; renders nothing when the system reserves no top inset
/// (e.g. an opaque status bar that already provides its own backdrop). Expects
/// to be placed as a child of a [Stack].
class StatusBarScrim extends StatelessWidget {
  final Color background;
  const StatusBarScrim({super.key, required this.background});

  @override
  Widget build(BuildContext context) {
    double topInset = MediaQuery.of(context).viewPadding.top;
    if (topInset <= 0) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: topInset + 14,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [background, background.withValues(alpha: 0.0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// Heading-band label with a [Hero]'d icon to the left of the [title] text,
/// matching the info tiles in Settings. [heroTag] pairs with the originating
/// list tile so the icon flies between them.
Widget headingBandLabel({
  required ThemeData theme,
  required IconData icon,
  required String heroTag,
  required String title,
  double iconSize = 32,
  CreateRectTween? createRectTween,
}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    SizedBox(
      width: iconSize,
      height: iconSize,
      child: Hero(
        tag: heroTag,
        createRectTween: createRectTween,
        child: ScalingAspectRatio(
          child: Icon(icon, color: theme.colorScheme.onSurface),
        ),
      ),
    ),
    const SizedBox(width: 9),
    Text(title),
  ],
);

/// The faded-in markdown body shared by the About / How-it-was-made pages.
Widget markdownPageSliver(ThemeData theme, String? md) => SliverPadding(
  padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 24.0),
  sliver: SliverToBoxAdapter(
    child: md == null
        ? const SizedBox.shrink()
        : TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            builder: (context, value, child) =>
                Opacity(opacity: value, child: child),
            child: MarkdownBody(
              data: md,
              selectable: true,
              onTapLink: (text, href, title) {
                if (href != null) launchUrl(Uri.parse(href));
              },
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                h1: theme.textTheme.titleLarge,
                h1Padding: const EdgeInsets.only(top: 6.0, bottom: 4.0),
                h2: theme.textTheme.titleMedium,
                h2Padding: const EdgeInsets.only(top: 6.0, bottom: 4.0),
                p: theme.textTheme.bodyMedium,
                pPadding: const EdgeInsets.only(bottom: 12.0),
                a: TextStyle(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
  ),
);

/// Standard chrome for a scrollable info/content page: a scrolling [headingBand]
/// title (instead of a flickery SliverAppBar), a [CornerBackButton], a matching
/// [BackNavBottomGutter] so the last item clears that button, and a
/// [StatusBarScrim]. The page's own content [slivers] sit between the title band
/// and the bottom gutter.
class InfoScaffold extends StatelessWidget {
  final bool flipBackgroundColors;

  /// Heading-band label — usually [headingBandLabel] or a plain [Text].
  final Widget title;
  final List<Widget> slivers;
  const InfoScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.flipBackgroundColors = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Page / heading band / gutter use the section-header colour (so short
    // pages never reveal a mismatched colour below the gutter); the content
    // sits on the contrasting content colour so it stands out against them.
    final (backgroundColorA, backgroundColorB) = maybeFlippedBackgroundColors(
      theme,
      flipBackgroundColors,
    );
    return Scaffold(
      backgroundColor: backgroundColorB,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: headingBand(
                  theme: theme,
                  label: title,
                  height:
                      halfScreenHeight(context) +
                      MediaQuery.of(context).viewPadding.top,
                  background: backgroundColorB,
                ),
              ),
              DecoratedSliver(
                decoration: BoxDecoration(color: backgroundColorA),
                sliver: SliverMainAxisGroup(slivers: slivers),
              ),
              SliverToBoxAdapter(
                child: BackNavBottomGutter(background: backgroundColorB),
              ),
            ],
          ),
          CornerBackButton(background: backgroundColorB),
          StatusBarScrim(background: backgroundColorB),
        ],
      ),
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
    _scrollController = ScrollController(initialScrollOffset: 0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (contentBackground, headingBackground) = maybeFlippedBackgroundColors(
      theme,
      widget.flipBackgroundColors,
    );
    final listItemPadding = const EdgeInsets.symmetric(
      horizontal: 16.0,
      vertical: 8.0,
    );

    Widget trailing(Widget child) =>
        SizedBox(width: 40.0, child: Center(child: child));

    const sectionHeadingHeight = 80.0;

    Widget setupTile = ListTile(
      title: Text('Setup', style: theme.textTheme.bodyLarge),
      subtitle: Text(
        'Resume setup',
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () {
        Navigator.push(
          context,
          CircularRevealRoute(
            builder: (context) => OnboardScreen(),
            iconOriginKey: configButtonKey,
          ),
        );
      },
    );

    return Scaffold(
      // Page background is the section-header colour (so short content / the
      // area below the bottom gutter never reveals a mismatched colour); the
      // tiles carry the contrasting content colour instead — see ListTileTheme.
      backgroundColor: headingBackground,
      resizeToAvoidBottomInset: false,
      body: ListTileTheme(
        data: ListTileThemeData(tileColor: contentBackground),
        child: Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                // Title band. Scrolls away with the content (it is not pinned)
                // and shares its structure with the section headings below.
                SliverToBoxAdapter(
                  child: headingBand(
                    theme: theme,
                    label: Text('Settings'),
                    height:
                        halfScreenHeight(context) +
                        MediaQuery.of(context).viewPadding.top,
                    background: headingBackground,
                    fade: true,
                  ),
                ),
                SliverList(
                  delegate: SliverChildListDelegate([
                    Builder(
                      builder: (context) {
                        final padLandscapeMobj = Mobj.getAlreadyLoaded(
                          padLandscapeID,
                          BoolType(),
                        );
                        final padLandscapeNonNull = computed(
                          () => padLandscapeMobj.value ?? false,
                          autoDispose: true,
                        );
                        return ListTile(
                          title: Text(
                            'Numpad orientation',
                            style: theme.textTheme.bodyLarge,
                          ),
                          subtitle: Watch(
                            (context) => Text(
                              padLandscapeNonNull.value
                                  ? 'landscape'
                                  : 'portrait',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          trailing: trailing(
                            BoolSignalTween(
                              signal: padLandscapeNonNull,
                              duration: Duration(milliseconds: 600),
                              // duration: Duration(milliseconds: 190),
                              builder: (context, progress, _) {
                                final longDimension = 22 / 4 * 3;
                                final shortDimension = 22.0;
                                final hpu = 0.37;
                                final h = lerp(
                                  shortDimension,
                                  longDimension,
                                  Curves.easeInOutCubic.transform(
                                    unlerpUnit(0, hpu, progress),
                                  ),
                                );
                                final w = lerp(
                                  longDimension,
                                  shortDimension,
                                  Curves.easeInOutCubic.transform(
                                    unlerpUnit(1 - hpu, 1, progress),
                                  ),
                                );
                                final movementp = Curves.easeInOutQuad
                                    .transform(1 - progress);
                                final centeredInset =
                                    (longDimension - shortDimension) / 2;
                                return SizedBox(
                                  width: longDimension,
                                  height: longDimension,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        width: w,
                                        height: h,
                                        top: lerp(0, centeredInset, movementp),
                                        right: lerp(
                                          centeredInset,
                                          0,
                                          movementp,
                                        ),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.onSurface,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                // a far simpler, prettier, but slightly less informational or characterful version, should be run in 200ms:
                                // return SizedBox(
                                //   width: lerp(
                                //     longDimension,
                                //     shortDimension,
                                //     Curves.easeIn.transform(progress),
                                //   ),
                                //   height: lerp(
                                //     shortDimension,
                                //     longDimension,
                                //     Curves.easeOut.transform(progress),
                                //   ),
                                //   child: Container(
                                //     decoration: BoxDecoration(
                                //       color: theme.colorScheme.primary,
                                //       borderRadius: BorderRadius.circular(4),
                                //     ),
                                //   ),
                                // );
                              },
                            ),
                          ),
                          onTap: () {
                            padLandscapeMobj.value = !padLandscapeMobj.value!;
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),
                    // Alarm sound setting
                    Builder(
                      builder: (context) {
                        final GlobalKey iconKey = GlobalKey();
                        final hereIconKey = GlobalKey();
                        return ListTile(
                          title: Text(
                            'Alarm sound',
                            style: theme.textTheme.bodyLarge,
                          ),
                          subtitle: Watch((context) {
                            return Text(
                              Mobj.getAlreadyLoaded(
                                selectedAudioID,
                                AudioInfoType(),
                              ).value!.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            );
                          }),
                          trailing: trailing(
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: Hero(
                                tag: 'alarm-sound-icon',
                                child: ScalingAspectRatio(
                                  child: Icon(
                                    Icons.music_note,
                                    key: hereIconKey,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              CircularRevealRoute(
                                builder: (context) => AlarmSoundPickerScreen(
                                  iconKey: iconKey,
                                  flipBackgroundColors:
                                      !widget.flipBackgroundColors,
                                ),
                                buttonCenter: widgetCenter(hereIconKey),
                                iconOriginKey: iconKey,
                              ),
                            );
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),
                    // Persistent alarm mode setting
                    Watch((context) {
                      final persistentAlarmModeMobj = Mobj.getAlreadyLoaded(
                        persistentAlarmModeID,
                        BoolType(),
                      );
                      final persistentAlarmMode =
                          persistentAlarmModeMobj.value ?? false;
                      return RoundedCheckboxListTile(
                        title: Text(
                          'Persistent alarm',
                          style: theme.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          persistentAlarmMode
                              ? 'On. Alarm loops until you open the app'
                              : 'Off. Alarm plays once',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        value: persistentAlarmMode,
                        onChanged: (value) {
                          persistentAlarmModeMobj.value = value;
                        },
                        contentPadding: listItemPadding,
                      );
                    }),
                    Watch((context) {
                      final buttonScaleDialOnOn = Mobj.getAlreadyLoaded(
                        buttonScaleDialOnID,
                        BoolType(),
                      );
                      return ListTile(
                        title: Text(
                          'Button size',
                          style: theme.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          buttonScaleDialOnOn.value!
                              ? "Button scale dial is currently deployed, tap here to turn it off"
                              : 'Introduce a dial by which you can adjust UI scale',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        onTap: () {
                          buttonScaleDialOnOn.value =
                              !buttonScaleDialOnOn.value!;
                          if (buttonScaleDialOnOn.value!) {
                            Navigator.of(context).pop();
                          }
                        },
                      );
                    }),
                    // Right-handed mode setting
                    Watch((context) {
                      final isRightHandedMobj = Mobj.getAlreadyLoaded(
                        isRightHandedID,
                        BoolType(),
                      );
                      final isRightHanded = isRightHandedMobj.value ?? true;
                      return ListTile(
                        title: Text(
                          '${isRightHanded ? 'Right' : 'Left'}-handed mode',
                          style: theme.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          'optimize for ${isRightHanded ? 'right' : 'left'}-handed use',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),

                        // splashColor: Colors.black,

                        // aaargh I can't fix the awful white-grey aspect of the highlight and the splash
                        // focusColor: Colors.red,
                        // selectedColor: Colors.red,
                        // // tileColor: Colors.red,
                        // selectedTileColor: Colors.red,
                        // textColor: Colors.red,
                        // hoverColor: Colors.red,
                        // splashColor: Colors.black,
                        trailing: trailing(
                          TweenAnimationBuilder<double>(
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
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                        onTap: () {
                          isRightHandedMobj.value = !isRightHanded;
                        },
                        contentPadding: listItemPadding,
                      );
                    }),
                    Watch((context) {
                      final padVerticallyAscendingMobj = Mobj.getAlreadyLoaded(
                        padVerticallyAscendingID,
                        BoolType(),
                      );
                      final padVerticallyAscending =
                          padVerticallyAscendingMobj.value ?? false;
                      return ListTile(
                        title: Text(
                          'Numpad type',
                          style: theme.textTheme.bodyLarge,
                        ),
                        subtitle: Text(
                          padVerticallyAscending
                              ? 'calculator/keyboard style'
                              : 'phone style',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: trailing(
                          NumpadTypeIndicator(
                            isAscending: padVerticallyAscending,
                            width: 36,
                          ),
                        ),
                        onTap: () {
                          padVerticallyAscendingMobj.value =
                              !padVerticallyAscending;
                        },
                        contentPadding: listItemPadding,
                      );
                    }),
                    headingBand(
                      theme: theme,
                      label: Text('Info'),
                      height: sectionHeadingHeight,
                      background: headingBackground,
                      fade: true,
                    ),
                    Builder(
                      builder: (context) {
                        // Need a Builder to get the correct context for finding the icon's position
                        final GlobalKey iconKey = GlobalKey();
                        final hereIconKey = GlobalKey();
                        return ListTile(
                          title: Text(
                            'About this app',
                            style: theme.textTheme.bodyLarge,
                          ),
                          trailing: trailing(
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: Hero(
                                tag: 'about-icon',
                                child: ScalingAspectRatio(
                                  child: Icon(
                                    Icons.info_outline,
                                    key: hereIconKey,
                                    size: 10,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              CircularRevealRoute(
                                builder: (context) => AboutScreen(
                                  iconKey: iconKey,
                                  flipBackgroundColors:
                                      !widget.flipBackgroundColors,
                                ),
                                buttonCenter: widgetCenter(hereIconKey),
                                iconOriginKey: iconKey,
                              ),
                            );
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),
                    Builder(
                      builder: (context) {
                        final GlobalKey iconKey = GlobalKey();
                        final hereIconKey = GlobalKey();
                        return ListTile(
                          title: Text(
                            'How it was made',
                            style: theme.textTheme.bodyLarge,
                          ),
                          trailing: trailing(
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: Hero(
                                tag: 'how-made-icon',
                                child: ScalingAspectRatio(
                                  child: Icon(
                                    Icons.handyman_outlined,
                                    key: hereIconKey,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              CircularRevealRoute(
                                builder: (context) => HowMadeScreen(
                                  iconKey: iconKey,
                                  flipBackgroundColors:
                                      !widget.flipBackgroundColors,
                                ),
                                buttonCenter: widgetCenter(hereIconKey),
                                iconOriginKey: iconKey,
                              ),
                            );
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),
                    Builder(
                      builder: (context) {
                        final GlobalKey iconKey = GlobalKey();
                        final hereIconKey = GlobalKey();
                        return ListTile(
                          title: Text(
                            'Thank the author',
                            style: theme.textTheme.bodyLarge,
                          ),
                          trailing: trailing(
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: Hero(
                                tag: 'thank-author-icon',
                                child: ScalingAspectRatio(
                                  child: Icon(
                                    Icons.heart_broken,
                                    key: hereIconKey,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              CircularRevealRoute(
                                builder: (context) => ThankAuthorScreen(
                                  iconKey: iconKey,
                                  flipBackgroundColors:
                                      !widget.flipBackgroundColors,
                                ),
                                buttonCenter: widgetCenter(hereIconKey),
                                iconOriginKey: iconKey,
                              ),
                            );
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),
                    headingBand(
                      theme: theme,
                      label: Text('Extra'),
                      height: sectionHeadingHeight,
                      background: headingBackground,
                      fade: true,
                    ),
                    Builder(
                      builder: (context) {
                        final GlobalKey iconKey = GlobalKey();
                        Offset? tapPosition;
                        return GestureDetector(
                          onTapDown: (details) {
                            tapPosition = details.globalPosition;
                          },
                          child: ListTile(
                            title: Text(
                              'Crank game',
                              style: theme.textTheme.bodyLarge,
                            ),
                            subtitle: Text(
                              "This is a game that came to me in a dream while I was making this timer app. I kind of hate it. It's about time, though, it's about the virtues of clocks.",
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: trailing(
                              SizedBox(
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
                                          color: theme.colorScheme.onSurface,
                                          size: 24,
                                        ),
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          child: Icon(
                                            Icons.sports_esports,
                                            color: theme.colorScheme.onSurface,
                                            size: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                CircularRevealRoute(
                                  builder: (context) => CrankGameScreen(
                                    iconKey: iconKey,
                                    flipBackgroundColors:
                                        !widget.flipBackgroundColors,
                                  ),
                                  buttonCenter: tapPosition ?? Offset.zero,
                                  iconOriginKey: iconKey,
                                ),
                              );
                            },
                            contentPadding: listItemPadding,
                          ),
                        );
                      },
                    ),
                    Builder(
                      builder: (context) {
                        final GlobalKey iconKey = GlobalKey();
                        final hereIconKey = GlobalKey();
                        return ListTile(
                          title: Text(
                            'Trash',
                            style: theme.textTheme.bodyLarge,
                          ),
                          subtitle: Text(
                            'Restore recently deleted timers',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: trailing(
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: Hero(
                                tag: 'trash-bin-icon',
                                child: ScalingAspectRatio(
                                  child: Icon(
                                    Icons.delete_outline,
                                    key: hereIconKey,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              CircularRevealRoute(
                                builder: (context) => BinScreen(
                                  iconKey: iconKey,
                                  flipBackgroundColors:
                                      !widget.flipBackgroundColors,
                                ),
                                buttonCenter: widgetCenter(hereIconKey),
                                iconOriginKey: iconKey,
                              ),
                            );
                          },
                          contentPadding: listItemPadding,
                        );
                      },
                    ),

                    // abandoned on journey_game branch
                    // ListTile(
                    //   title: Text(
                    //     'Journeying game',
                    //     style: theme.textTheme.bodyLarge,
                    //   ),
                    //   subtitle: Text(
                    //     "A world to wander.",
                    //     style: theme.textTheme.bodyMedium?.copyWith(
                    //       color: theme.colorScheme.onSurfaceVariant,
                    //     ),
                    //   ),
                    //   trailing: trailing(
                    //     Icon(
                    //       Icons.explore_rounded,
                    //       color: theme.colorScheme.onSurface,
                    //       size: 24,
                    //     ),
                    //   ),
                    //   onTap: () {
                    //     Navigator.pushReplacement(
                    //       context,
                    //       CircularRevealRoute(
                    //         builder: (context) => const JourneyingGameScreen(),
                    //       ),
                    //     );
                    //   },
                    //   contentPadding: listItemPadding,
                    // ),

                    // if (!completedSetup) ...[
                    if (true) ...[setupTile],
                    BackNavBottomGutter(background: headingBackground),
                  ]),
                ),
              ],
            ),
            CornerBackButton(background: headingBackground),
            StatusBarScrim(background: headingBackground),
          ],
        ),
      ),
    );
  }
}

/// The trash bin: timers the user has deleted, kept around for [binRetention]
/// so they can be restored. Lays them out the same bottom-cornered wrap the
/// TimerScreen uses (inlined here rather than via [TimerTray], which assumes a
/// synchronously-complete widget map and brings drag machinery the bin doesn't
/// want). Tapping a timer here restores it to the timer list rather than
/// playing it, because the timers are inactive (see the tap handler in
/// [TimerBaseState.buildShell] and the restore-vs-play split keyed on
/// [Mobj.isActive]).
class BinScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  final GlobalKey? iconKey;
  const BinScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
  });

  @override
  State<BinScreen> createState() => BinScreenState();
}

class BinScreenState extends State<BinScreen> with SignalsMixin {
  final Map<MobjID<TimerData>, TimerBase> timerWidgetCache = {};
  late final Mobj<List<MobjID<TimerData>>> binListMobj = Mobj.getAlreadyLoaded(
    binListID,
    timerListType,
  );
  late final Mobj<List<MobjID<TimerData>>> timerListMobj = Mobj.getAlreadyLoaded(
    timerListID,
    timerListType,
  );

  /// flips once the (inactive) binned timers have been loaded from disk; the
  /// build reads it so the tray rebuilds once they're available.
  final Signal<bool> _loaded = Signal(false);

  @override
  void initState() {
    super.initState();
    // binned timers are inactive, so on a fresh launch they aren't preloaded;
    // pull them in before we try to render them
    Future.wait(
      binListMobj.peek()!.map(
        (id) => Mobj.fetch(
          id,
          type: TimerDataType(),
        ).then<void>((_) {}).catchError((_) {}),
      ),
    ).then((_) {
      if (mounted) _loaded.value = true;
    });
  }

  @override
  void dispose() {
    _loaded.dispose();
    super.dispose();
  }

  void restoreTimer(MobjID<TimerData> ki) {
    final mobj = Mobj.seekTypedAlreadyLoaded(ki, TimerDataType());
    if (mobj == null || mobj.peek() == null) return;
    timerWidgetCache.remove(ki);
    binListMobj.value = binListMobj.peek()!.toList()..remove(ki);
    mobj.isActive = true;
    // re-root it: a binned timer may have been a child of a composite that's
    // since changed or gone, so it always comes back as a top-level timer.
    mobj.value = mobj.peek()!.withChanges(parentId: timerListMobj.id);
    timerListMobj.value = [...timerListMobj.peek()!, ki];
  }

  /// The binned timers laid out the way the TimerScreen lays out its tray —
  /// bottom-cornered toward the dominant hand, wrapping upward — but built only
  /// from the timers that have actually loaded (the bin list can reference ones
  /// still loading from disk, or that failed to load), so there's no force-
  /// unwrap to trip over.
  Widget _buildTray(ThemeData theme) {
    return Watch((context) {
      _loaded.value; // rebuild once the binned timers finish loading
      final isRightHanded =
          Mobj.getAlreadyLoaded(isRightHandedID, BoolType()).value ?? true;
      final binIds = binListMobj.value!;
      if (binIds.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Deleted timers wait here for a couple of days, in case you want them back.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: MakoThemeData.fromTheme(theme).reducedProminenceColor,
              ),
            ),
          ),
        );
      }
      final children = <Widget>[
        for (final id in binIds)
          if (Mobj.seekTypedAlreadyLoaded(id, TimerDataType())?.peek() != null)
            getOrCreateTimerWidget(timerWidgetCache, id, animateIn: false),
      ];
      return Align(
        alignment: isRightHanded
            ? const FractionalOffset(0.8, 1)
            : const FractionalOffset(0.2, 1),
        child: IWrap(
          textDirection: isRightHanded ? TextDirection.ltr : TextDirection.rtl,
          clipBehavior: Clip.none,
          verticalDirection: VerticalDirection.down,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: children,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (contentBackground, headingBackground) = maybeFlippedBackgroundColors(
      theme,
      widget.flipBackgroundColors,
    );
    return Scaffold(
      backgroundColor: headingBackground,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Column(
            children: [
              headingBand(
                theme: theme,
                label: headingBandLabel(
                  theme: theme,
                  icon: Icons.delete_outline,
                  heroTag: 'trash-bin-icon',
                  title: 'Trash',
                ),
                height:
                    halfScreenHeight(context) +
                    MediaQuery.of(context).viewPadding.top,
                background: headingBackground,
              ),
              Expanded(
                child: Container(
                  color: contentBackground,
                  // AnimoveFrame so the remaining timers slide to fill the gap
                  // when one is restored, the same way the TimerScreen animates
                  // (its timers' Animove wrappers need a frame ancestor).
                  child: AnimoveFrame(child: _buildTray(theme)),
                ),
              ),
              BackNavBottomGutter(background: headingBackground),
            ],
          ),
          CornerBackButton(background: headingBackground),
          StatusBarScrim(background: headingBackground),
        ],
      ),
    );
  }
}

class ThankAuthorScreen extends StatelessWidget {
  final bool flipBackgroundColors;
  const ThankAuthorScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
  });
  final GlobalKey? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InfoScaffold(
      flipBackgroundColors: flipBackgroundColors,
      title: headingBandLabel(
        theme: theme,
        icon: Icons.heart_broken,
        heroTag: 'thank-author-icon',
        title: 'Thank the author',
      ),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            Padding(
              padding: EdgeInsets.all(24.0),
              child: Text(
                'The audience for this app is large. Even a small payment in total would enable the author to go on to create much more ambitious projects.',
                style: theme.textTheme.bodyLarge,
              ),
            ),
            SizedBox(height: 24),
          ]),
        ),
      ],
    );
  }
}

class AboutScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  final GlobalKey? iconKey;
  const AboutScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
  });

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _md;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/about.md').then((md) {
      if (mounted) setState(() => _md = md);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InfoScaffold(
      flipBackgroundColors: widget.flipBackgroundColors,
      title: headingBandLabel(
        theme: theme,
        icon: Icons.info_outline,
        heroTag: 'about-icon',
        title: "About Mako's Timer",
      ),
      slivers: [markdownPageSliver(theme, _md)],
    );
  }
}

class HowMadeScreen extends StatefulWidget {
  final bool flipBackgroundColors;
  final GlobalKey? iconKey;
  const HowMadeScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
  });

  @override
  State<HowMadeScreen> createState() => _HowMadeScreenState();
}

class _HowMadeScreenState extends State<HowMadeScreen> {
  String? _md;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/how_made.md').then((md) {
      if (mounted) setState(() => _md = md);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InfoScaffold(
      flipBackgroundColors: widget.flipBackgroundColors,
      title: headingBandLabel(
        theme: theme,
        icon: Icons.handyman_outlined,
        heroTag: 'how-made-icon',
        title: 'How it was made',
      ),
      slivers: [markdownPageSliver(theme, _md)],
    );
  }
}

class AlarmSoundPickerScreen extends StatefulWidget {
  final bool flipBackgroundColors;

  /// When true, the picker is choosing a per-timer sound override.
  /// It adds a "Default" entry and pops with the selected AudioInfo?
  /// (null = default). When false, it edits the global selectedAudioID Mobj.
  final bool perTimerMode;
  final AudioInfo? initialPerTimerSelection;
  const AlarmSoundPickerScreen({
    super.key,
    this.iconKey,
    this.flipBackgroundColors = false,
    this.perTimerMode = false,
    this.initialPerTimerSelection,
  });
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
  final List<AudioInfo> _pickedFiles = [];
  late Function() listeningAudioEffectChange;
  bool _loading = true;
  late final Signal<AudioInfo?> _localSelection;
  bool _hasInteracted = false;

  @override
  void initState() {
    super.initState();
    _loadSounds();
    if (widget.perTimerMode) {
      _localSelection = Signal(widget.initialPerTimerSelection);
      listeningAudioEffectChange = () {};
    } else {
      _localSelection = Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType());
      listeningAudioEffectChange =
          Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType()).subscribe((
            event,
          ) {
            Mobj.getAlreadyLoaded(hasSelectedAudioID, BoolType()).value = true;
          });
    }
  }

  @override
  void dispose() {
    listeningAudioEffectChange();
    if (widget.perTimerMode) _localSelection.dispose();
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
        final alarmsFuture = PlatformAudio.getPlatformAudio(
          PlatformAudioType.alarm,
        );
        final notificationsFuture = PlatformAudio.getPlatformAudio(
          PlatformAudioType.notification,
        );
        final ringtonesFuture = PlatformAudio.getPlatformAudio(
          PlatformAudioType.ringtone,
        );
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
          _seedPickedFilesFromSelection();
        });
      }
    } catch (e) {
      print('Error loading sounds: $e');
      setState(() {
        _loading = false;
      });
    }
  }

  /// If the persisted selection's URL isn't in any loaded section, it must be
  /// a previously picked custom file — show it in the "From Device" section so
  /// the user sees what's currently selected.
  void _seedPickedFilesFromSelection() {
    final current = _localSelection.value;
    if (current?.url == null) return;
    bool existsIn(List<AudioInfo>? list) =>
        list != null && list.any((a) => a.url == current!.url);
    if (existsIn(_assetSounds) ||
        existsIn(_alarmSounds) ||
        existsIn(_notificationSounds) ||
        existsIn(_ringtoneSounds)) {
      return;
    }
    if (_pickedFiles.any((a) => a.url == current!.url)) return;
    _pickedFiles.add(current!);
  }

  void _popWithResult() {
    Navigator.of(context).pop(_localSelection.value);
  }

  Widget _buildPickFileChip(ThemeData theme, Color backgroundColor) {
    final jukeBox = Provider.of<JukeBox>(context, listen: false);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        jukeBox.pauseAudio();
        final AudioInfo? picked;
        try {
          picked = await PlatformAudio.pickAudioFile();
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Could not pick file: $e')));
          }
          return;
        }
        if (picked == null || !mounted) return;
        final chosen = picked;
        setState(() {
          if (widget.perTimerMode && !_hasInteracted) _hasInteracted = true;
          if (!_pickedFiles.any((a) => a.url == chosen.url)) {
            _pickedFiles.add(chosen);
          }
          _localSelection.value = chosen;
        });
        jukeBox.playAudio(chosen);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.onSurface),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: theme.colorScheme.onSurface),
            SizedBox(width: 4),
            Text('Pick file…', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Page background matches the heading band / section-header colour so short
    // lists don't reveal a mismatched content colour below the bottom gutter;
    // the sound chips use the contrasting content colour so they stand out.
    final (backgroundColorA, backgroundColorB) = maybeFlippedBackgroundColors(
      theme,
      widget.flipBackgroundColors,
    );

    Widget section(
      String title,
      List<AudioInfo?> sounds, {
      Duration? fadeDelay,
      List<Widget> extraChildren = const [],
    }) {
      final animDuration = Duration(milliseconds: 100);
      final totalDuration = fadeDelay != null
          ? fadeDelay + animDuration
          : animDuration;
      final delayFraction = fadeDelay != null
          ? fadeDelay.inMicroseconds / totalDuration.inMicroseconds
          : 0.0;

      final jukeBox = Provider.of<JukeBox>(context, listen: false);

      Widget radioSelector(AudioInfo? audio) {
        bool hasPlayed = false;
        return RadioItem<AudioInfo?>(
          equalityComparison: (AudioInfo? a, AudioInfo? b) => a?.url == b?.url,
          me: audio,
          selection: _localSelection,
          onTap: () {
            if (widget.perTimerMode && !_hasInteracted) {
              setState(() => _hasInteracted = true);
            }
            jukeBox.pauseAudio();
            if (_localSelection.value?.url != audio?.url) {
              hasPlayed = false;
            }
            if (!hasPlayed) {
              final toPlay =
                  audio ??
                  Mobj.getAlreadyLoaded(selectedAudioID, AudioInfoType()).value;
              if (toPlay != null) jukeBox.playAudio(toPlay);
            }
            hasPlayed = !hasPlayed;
          },
          builder: (context, isOn) {
            final textTheme = isOn
                ? theme.textTheme.bodyMedium!.copyWith(
                    color: theme.colorScheme.onPrimary,
                  )
                : theme.textTheme.bodyMedium!;
            // Chips sit inside the backgroundColorA section container, so they
            // take the opposite (B) colour to stand out against it.
            final backgroundColor = isOn
                ? theme.colorScheme.primary
                : backgroundColorB;
            return Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(audio?.name ?? 'Default', style: textTheme),
            );
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
                if (title != null && title.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(0, 0, 0, 7),
                    child: Text(title, style: headingTextStyle(theme)),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...sounds.map((audio) => radioSelector(audio)),
                    ...extraChildren,
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    const bottomBarHeight = 64.0;

    return PopScope(
      canPop: !widget.perTimerMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.perTimerMode) {
          _popWithResult();
        }
      },
      child: Scaffold(
        backgroundColor: backgroundColorB,
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: headingBand(
                    theme: theme,
                    label: widget.perTimerMode
                        ? Text('Pick a sound')
                        : headingBandLabel(
                            theme: theme,
                            icon: Icons.music_note,
                            heroTag: 'alarm-sound-icon',
                            title: 'Alarm sound',
                            createRectTween: (begin, end) => DelayedRectTween(
                              begin: begin,
                              end: end,
                              delay: 0.14,
                            ),
                          ),
                    height:
                        halfScreenHeight(context) +
                        MediaQuery.of(context).viewPadding.top,
                    background: backgroundColorB,
                  ),
                ),
                if (!_loading) ...[
                  // All the sound sections share one backgroundColorA container;
                  // the chips inside flip to B to contrast against it.
                  DecoratedSliver(
                    decoration: BoxDecoration(color: backgroundColorA),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        if (widget.perTimerMode)
                          section('', [
                            null,
                          ], fadeDelay: Duration(milliseconds: 0)),
                        if (_assetSounds.isNotEmpty)
                          section(
                            "Our Sounds",
                            _assetSounds,
                            fadeDelay: Duration(milliseconds: 0),
                          ),
                        if (_notificationSounds != null &&
                            _notificationSounds!.isNotEmpty)
                          section(
                            'Phone Notification Sounds',
                            _notificationSounds!,
                            fadeDelay: Duration(milliseconds: 200),
                          ),
                        if (_alarmSounds != null && _alarmSounds!.isNotEmpty)
                          section(
                            'Device alarm sounds (long duration)',
                            _alarmSounds!,
                            fadeDelay: Duration(milliseconds: 100),
                          ),
                        if (_ringtoneSounds != null &&
                            _ringtoneSounds!.isNotEmpty)
                          section(
                            'Device ringtones',
                            _ringtoneSounds!,
                            fadeDelay: Duration(milliseconds: 300),
                          ),
                        if (Platform.isAndroid)
                          section(
                            'From files',
                            _pickedFiles,
                            fadeDelay: Duration(milliseconds: 400),
                            extraChildren: [
                              _buildPickFileChip(theme, backgroundColorB),
                            ],
                          ),
                        // Bottom breathing room inside the container, matching
                        // the 16px gap above each section.
                        SliverToBoxAdapter(
                          child: Container(
                            height: 16,
                            decoration: BoxDecoration(color: backgroundColorA),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.perTimerMode)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            bottomBarHeight +
                            16 +
                            MediaQuery.of(context).padding.bottom,
                      ),
                    )
                  else
                    SliverToBoxAdapter(
                      child: BackNavBottomGutter(background: backgroundColorB),
                    ),
                ],
              ],
            ),
            if (widget.perTimerMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height:
                      bottomBarHeight + MediaQuery.of(context).padding.bottom,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColorB,
                    border: Border(
                      top: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.3,
                        ),
                      ),
                    ),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: double.infinity,
                      height: bottomBarHeight,
                      child: TextButton(
                        onPressed: _popWithResult,
                        style: TextButton.styleFrom(
                          shape: RoundedRectangleBorder(),
                          backgroundColor: _hasInteracted
                              ? theme.colorScheme.primaryContainer
                              : null,
                          foregroundColor: _hasInteracted
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurface,
                        ),
                        child: Text(
                          _hasInteracted ? 'Done' : 'Cancel',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: _hasInteracted
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // perTimerMode is a modal picker with its own Done/Cancel bar and
            // result-returning pop, so it gets no corner back button.
            if (!widget.perTimerMode)
              CornerBackButton(background: backgroundColorB),
            StatusBarScrim(background: backgroundColorB),
          ],
        ),
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
    skipKey,
  ];
  late Signal<bool?> numpadOrientation = Signal(null);
  late Signal<bool?> ringMode = Signal(null);
  late List<Signal<dynamic>> allChoices = [
    setIsRightHanded,
    numpadOrientation,
    ringMode,
    if (Platform.isAndroid) notifGranted,
    if (Platform.isAndroid) batteryOptimGranted,
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
          newRoute: CircularRevealRoute(builder: (context) => TimerScreen()),
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

    Widget handButton({required bool isRight}) {
      return Expanded(
        child: RadioItem<bool?>(
          selection: setIsRightHanded,
          duration: buttonAnimationDuration,
          me: isRight,
          onTap: () => inputCompleted(handednessKey),
          builder: (context, isOn) {
            final leftHand = Transform.rotate(
              angle: 1 / 8 * tau,
              child: Icon(
                Icons.back_hand_rounded,
                size: 36,
                color: foregroundColorFor(theme, isOn),
              ),
            );
            final rightHand = Transform.scale(scaleX: -1, child: leftHand);
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
                        Text(
                          'right',
                          style: theme.textTheme.titleMedium!.copyWith(
                            color: foregroundColorFor(theme, isOn),
                          ),
                        ),
                        spacer,
                        rightHand,
                      ]
                    : [
                        leftHand,
                        spacer,
                        Text(
                          'left',
                          style: theme.textTheme.titleMedium!.copyWith(
                            color: foregroundColorFor(theme, isOn),
                          ),
                        ),
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
            child: NumpadTypeIndicator(
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
      body: Stack(
        children: [
          CustomScrollView(
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
                        child: Text("Setup", style: theme.textTheme.titleLarge),
                      ),
                      Container(
                        padding: EdgeInsets.all(standardSpacing),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Are you left or right-handed?',
                              style: theme.textTheme.bodyMedium!,
                            ),
                            SizedBox(height: standardSpacing),
                            Row(
                              children: [
                                handButton(isRight: false),
                                spacer,
                                handButton(isRight: true),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                key: padKey,
                child: Container(
                  padding: EdgeInsets.all(standardSpacing),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        "Which kind of numpad is more familiar to you?",
                        style: theme.textTheme.bodyMedium!,
                      ),
                      spacer,
                      Watch((context) {
                        return AnimatedAlign(
                          duration: Duration(milliseconds: 340),
                          curve: Curves.easeInOutCubic,
                          alignment: isRightHanded.value == true
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                children: [
                                  Text(
                                    "phone style",
                                    style: theme.textTheme.bodyMedium!,
                                  ),
                                  spacer,
                                  numpadForSetup(false),
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
                                  numpadForSetup(true),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                key: ringModeKey,
                child: Padding(
                  padding: EdgeInsets.all(standardSpacing),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        """Are you generally attentive and responsive to your phone notifications? If so, set this to "ring once," which is far more convenient, as it doesn't require you to interact with your phone every time an alarm goes off. Otherwise, you may need a more insistent notification to make absolutely sure that you're aware of timer completions, select "require acknowledgement." """,
                        style: theme.textTheme.bodyMedium!,
                      ),
                      SizedBox(height: standardSpacing),
                      Row(
                        children: [
                          Flexible(flex: 20, child: Container()),
                          Flexible(
                            flex: 50,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                RadioItem<bool?>(
                                  selection: ringMode,
                                  duration: buttonAnimationDuration,
                                  me: true,
                                  onTap: () => inputCompleted(ringModeKey),
                                  builder: (context, isOn) => Container(
                                    height: standardButtonHeight,
                                    decoration: BoxDecoration(
                                      color: backgroundColorFor(theme, isOn),
                                      borderRadius: BorderRadius.circular(
                                        buttonCornerRadius,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 22.0,
                                      ),
                                      child: Center(
                                        child: Text(
                                          textAlign: TextAlign.center,
                                          'require acknowledgement',
                                          style: theme.textTheme.titleMedium!
                                              .copyWith(
                                                color: foregroundColorFor(
                                                  theme,
                                                  isOn,
                                                ),
                                              ),
                                        ),
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
                                      color: backgroundColorFor(theme, isOn),
                                      borderRadius: BorderRadius.circular(
                                        buttonCornerRadius,
                                      ),
                                    ),
                                    child: Center(
                                      child: Text(
                                        'ring once',
                                        style: theme.textTheme.titleMedium!
                                            .copyWith(
                                              color: foregroundColorFor(
                                                theme,
                                                isOn,
                                              ),
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (Platform.isAndroid)
                SliverToBoxAdapter(
                  key: notifKey,
                  child: Padding(
                    padding: EdgeInsets.all(standardSpacing),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: reverseIfNot(isRightHanded.value ?? true, [
                        Flexible(
                          child: Text(
                            'Enable notifications permission',
                            style: theme.textTheme.bodyMedium!,
                          ),
                        ),
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
                              backgroundColor: backgroundColorFor(theme, isOn),
                              onTap: granted == true
                                  ? null
                                  : _requestNotificationPermission,
                              borderRadius: BorderRadius.circular(
                                buttonCornerRadius,
                              ),
                              child: SizedBox(
                                height: standardButtonHeight,
                                child: Center(
                                  child: Text(
                                    label,
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(
                                          color: foregroundColorFor(
                                            theme,
                                            isOn,
                                          ),
                                        ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ]),
                    ),
                  ),
                ),
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
                            style: theme.textTheme.bodyMedium!,
                          ),
                        ),
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
                              backgroundColor: backgroundColorFor(theme, isOn),
                              onTap: granted == true
                                  ? null
                                  : _requestBatteryOptimization,
                              borderRadius: BorderRadius.circular(
                                buttonCornerRadius,
                              ),
                              child: SizedBox(
                                height: standardButtonHeight,
                                child: Center(
                                  child: Text(
                                    label,
                                    style: theme.textTheme.titleMedium!
                                        .copyWith(
                                          color: foregroundColorFor(
                                            theme,
                                            isOn,
                                          ),
                                        ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ]),
                    ),
                  ),
                ),
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
                          borderRadius: BorderRadius.circular(
                            buttonCornerRadius,
                          ),
                          builder: (context, isOn) => Container(
                            color: backgroundColorFor(Theme.of(context), isOn),
                            child: SizedBox(
                              height: standardButtonHeight,
                              child: Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Watch(
                                      (context) => Text(
                                        allChoicesCompleted.value
                                            ? 'setup complete, click to continue'
                                            : 'skip setup',
                                        style: theme.textTheme.titleMedium!
                                            .copyWith(
                                              color: foregroundColorFor(
                                                Theme.of(context),
                                                isOn,
                                              ),
                                            ),
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
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(height: MediaQuery.of(context).padding.bottom),
              ),
            ],
          ),
          StatusBarScrim(background: theme.colorScheme.surfaceContainerHigh),
        ],
      ),
    );
  }
}
