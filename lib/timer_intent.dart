import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// One of android's timer intents, as caught by TimerIntentActivity and routed
/// to whichever isolate owns the mobj registry (see TimerIntentPlugin).
class TimerIntentRequest {
  /// 'setTimer', 'showTimers' or 'dismissTimer'.
  final String action;

  /// Null for a setTimer that carried no length, which per android's contract
  /// means "show the timer UI and let the user enter one".
  final Duration? duration;

  /// The label the requester wants on the timer, if any.
  final String? message;

  const TimerIntentRequest({required this.action, this.duration, this.message});

  static TimerIntentRequest? fromMessage(Object? message) {
    if (message is! Map) return null;
    final action = message['action'];
    if (action is! String) return null;
    final seconds = message['seconds'];
    final label = message['message'];
    return TimerIntentRequest(
      action: action,
      duration: seconds is int && seconds > 0
          ? Duration(seconds: seconds)
          : null,
      message: label is String && label.isNotEmpty ? label : null,
    );
  }
}

class TimerIntents {
  static const MethodChannel _channel = MethodChannel(
    'makos_timer/timer_intent',
  );

  /// Registers [onRequest] for this isolate and takes delivery of anything that
  /// arrived before it was listening — the usual case, since an intent is
  /// typically what started the process. Call once per isolate.
  static Future<void> listen(void Function(TimerIntentRequest) onRequest) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'timerIntent') {
        final request = TimerIntentRequest.fromMessage(call.arguments);
        if (request != null) onRequest(request);
      }
      return null;
    });
    try {
      // Doubles as this isolate's "handler installed" signal: the native side
      // holds payloads back until it sees this.
      final pending = await _channel.invokeListMethod<Object?>('consumePending');
      for (final p in pending ?? const <Object?>[]) {
        final request = TimerIntentRequest.fromMessage(p);
        if (request != null) onRequest(request);
      }
    } on PlatformException catch (e) {
      debugPrint('consumePending failed: ${e.message}');
    } on MissingPluginException {
      // non-Android — there are no intents to take
    }
  }
}
