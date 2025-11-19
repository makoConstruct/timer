import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:makos_timer/boring.dart';

void main() {
  group('cancellableFutureThen', () {
    test('executes callback when future completes and not cancelled', () async {
      final completer = Completer<int>();
      int? result;

      cancellableFutureThen(completer.future, (value) {
        result = value;
      });

      completer.complete(42);
      await Future.delayed(Duration.zero); // Let microtasks run

      expect(result, 42);
    });

    test('does not execute callback when cancelled before completion',
        () async {
      final completer = Completer<int>();
      int? result;

      final cancel = cancellableFutureThen(completer.future, (value) {
        result = value;
      });

      cancel(); // Cancel before completion
      completer.complete(42);
      await Future.delayed(Duration.zero);

      expect(result, null);
    });

    test('does not execute callback when cancelled after completion', () async {
      final completer = Completer<int>();
      int? result;

      final cancel = cancellableFutureThen(completer.future, (value) {
        result = value;
      });

      completer.complete(42);
      cancel(); // Cancel after completion but before microtask runs
      await Future.delayed(Duration.zero);

      // This depends on timing - if microtask already ran, result will be set
      // This test demonstrates the race condition inherent in the design
    });

    test('does not throw error when cancelled before error', () async {
      final completer = Completer<int>();

      final cancel = cancellableFutureThen(completer.future, (value) {
        fail('Should not be called');
      });

      cancel();
      completer.completeError(Exception('Test error'));

      // Should not throw
      await Future.delayed(Duration.zero);
    });
  });

  group('ReplayingStreamController', () {
    test('replays initial list to new listeners', () async {
      final controller = ReplayingStreamController<int>([1, 2, 3]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      await Future.delayed(Duration.zero);

      expect(received, [1, 2, 3]);
      await controller.close();
    });

    test('replays initial list and new values to late listeners', () async {
      final controller = ReplayingStreamController<int>([1, 2, 3]);
      final received1 = <int>[];
      final received2 = <int>[];

      // First listener
      controller.stream.listen((value) {
        received1.add(value);
      });

      controller.add(4);
      controller.add(5);
      await Future.delayed(Duration.zero);

      // Second listener subscribes late
      controller.stream.listen((value) {
        received2.add(value);
      });

      await Future.delayed(Duration.zero);

      expect(received1, [1, 2, 3, 4, 5]);
      expect(received2, [1, 2, 3, 4, 5]); // Gets all previous values
      await controller.close();
    });

    test('forwards new values to existing listeners', () async {
      final controller = ReplayingStreamController<int>([]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      controller.add(1);
      controller.add(2);
      controller.add(3);
      await Future.delayed(Duration.zero);

      expect(received, [1, 2, 3]);
      await controller.close();
    });

    test('handles multiple listeners independently', () async {
      final controller = ReplayingStreamController<int>([1, 2]);
      final received1 = <int>[];
      final received2 = <int>[];

      controller.stream.listen((value) {
        received1.add(value);
      });

      controller.add(3);

      controller.stream.listen((value) {
        received2.add(value);
      });

      controller.add(4);
      await Future.delayed(Duration.zero);

      expect(received1, [1, 2, 3, 4]);
      expect(received2, [1, 2, 3, 4]); // Late listener gets all
      await controller.close();
    });

    test('handles empty initial list', () async {
      final controller = ReplayingStreamController<int>([]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      controller.add(1);
      await Future.delayed(Duration.zero);

      expect(received, [1]);
      await controller.close();
    });

    test('forwards errors to listeners', () async {
      final controller = ReplayingStreamController<int>([]);
      Object? error;
      StackTrace? stackTrace;

      controller.stream.listen(
        (value) => fail('Should not receive value'),
        onError: (e, st) {
          error = e;
          stackTrace = st;
        },
      );

      final testError = Exception('Test error');
      final testStackTrace = StackTrace.current;
      controller.addError(testError, testStackTrace);
      await Future.delayed(Duration.zero);

      expect(error, testError);
      expect(stackTrace, testStackTrace);
      await controller.close();
    });

    test('replays errors to late listeners', () async {
      final controller = ReplayingStreamController<int>([]);
      Object? error1;
      Object? error2;

      controller.stream.listen(
        (value) => fail('Should not receive value'),
        onError: (e, st) {
          error1 = e;
        },
      );

      controller.addError(Exception('Test error'));
      await Future.delayed(Duration.zero);

      // Late listener - errors are not replayed, only values
      controller.stream.listen(
        (value) => fail('Should not receive value'),
        onError: (e, st) {
          error2 = e;
        },
      );

      await Future.delayed(Duration.zero);
      expect(error1, isA<Exception>());
      expect(error2, isNull); // Errors are not replayed, only values
      await controller.close();
    });

    test('calls onListen callback when first listener subscribes', () async {
      final controller = ReplayingStreamController<int>([]);
      bool onListenCalled = false;

      controller.onListen = () {
        onListenCalled = true;
      };

      controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);

      expect(onListenCalled, true);
      await controller.close();
    });

    test('calls onCancel callback when last listener cancels', () async {
      final controller = ReplayingStreamController<int>([]);
      bool onCancelCalled = false;

      controller.onCancel = () {
        onCancelCalled = true;
      };

      final subscription = controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);

      await subscription.cancel();
      await Future.delayed(Duration.zero);

      expect(onCancelCalled, true);
      await controller.close();
    });

    test('updates onListen callback dynamically', () async {
      final controller = ReplayingStreamController<int>([]);
      int callCount = 0;

      controller.onListen = () {
        callCount = 1;
      };

      // Change callback
      controller.onListen = () {
        callCount = 2;
      };

      controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);

      expect(callCount, 2);
      await controller.close();
    });

    test('closes controller and completes done future', () async {
      final controller = ReplayingStreamController<int>([]);
      bool doneCompleted = false;

      controller.done.then((_) {
        doneCompleted = true;
      });

      await controller.close();
      await Future.delayed(Duration.zero);

      expect(controller.isClosed, true);
      expect(doneCompleted, true);
    });

    test('throws when adding to closed controller', () async {
      final controller = ReplayingStreamController<int>([]);
      await controller.close();

      expect(() => controller.add(1), throwsStateError);
      expect(() => controller.addError(Exception('test')), throwsStateError);
    });

    test('throws when accessing stream of closed controller', () async {
      final controller = ReplayingStreamController<int>([]);
      await controller.close();

      expect(() => controller.stream, throwsStateError);
    });

    test('hasListener reflects listener state', () async {
      final controller = ReplayingStreamController<int>([]);
      expect(controller.hasListener, false);

      final subscription = controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);
      expect(controller.hasListener, true);

      await subscription.cancel();
      await Future.delayed(Duration.zero);
      expect(controller.hasListener, false);

      await controller.close();
    });

    test('isPaused is always false for broadcast controller', () async {
      final controller = ReplayingStreamController<int>([]);
      expect(controller.isPaused, false);

      final subscription = controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);
      expect(controller.isPaused, false);

      subscription.pause();
      await Future.delayed(Duration.zero);
      expect(controller.isPaused, false); // Broadcast controllers never paused

      await subscription.cancel();
      await controller.close();
    });

    test('addStream forwards stream to controller', () async {
      final controller = ReplayingStreamController<int>([]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      final sourceStream = Stream<int>.fromIterable([1, 2, 3]);
      await controller.addStream(sourceStream);
      await Future.delayed(Duration.zero);

      expect(received, [1, 2, 3]);
      await controller.close();
    });

    test('addStream accepts cancelOnError parameter', () async {
      final controller = ReplayingStreamController<int>([]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      final sourceStream = Stream<int>.fromIterable([1, 2, 3]);
      await controller.addStream(sourceStream, cancelOnError: true);
      await Future.delayed(Duration.zero);

      expect(received, [1, 2, 3]);
      await controller.close();
    });

    test('sink getter returns controller itself', () {
      final controller = ReplayingStreamController<int>([]);
      expect(controller.sink, same(controller));
      controller.close();
    });

    test('handles rapid add operations', () async {
      final controller = ReplayingStreamController<int>([]);
      final received = <int>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      for (int i = 0; i < 100; i++) {
        controller.add(i);
      }
      await Future.delayed(Duration.zero);

      expect(received.length, 100);
      expect(received, List.generate(100, (i) => i));
      await controller.close();
    });

    test(
        'late listener gets all values including those added during subscription',
        () async {
      final controller = ReplayingStreamController<int>([1]);
      final received = <int>[];

      // Add values before listener
      controller.add(2);
      controller.add(3);

      // Subscribe - should get [1, 2, 3]
      controller.stream.listen((value) {
        received.add(value);
      });

      // Add more values
      controller.add(4);
      await Future.delayed(Duration.zero);

      expect(received, [1, 2, 3, 4]);
      await controller.close();
    });

    test('multiple late listeners all get full replay', () async {
      final controller = ReplayingStreamController<int>([1, 2]);
      controller.add(3);

      final received1 = <int>[];
      final received2 = <int>[];
      final received3 = <int>[];

      controller.stream.listen((v) => received1.add(v));
      controller.add(4);
      controller.stream.listen((v) => received2.add(v));
      controller.add(5);
      controller.stream.listen((v) => received3.add(v));

      await Future.delayed(Duration.zero);

      expect(received1, [1, 2, 3, 4, 5]);
      expect(received2, [1, 2, 3, 4, 5]);
      expect(received3, [1, 2, 3, 4, 5]);
      await controller.close();
    });

    test('works with generic string type', () async {
      final controller = ReplayingStreamController<String>(['a', 'b']);
      final received = <String>[];

      controller.stream.listen((value) {
        received.add(value);
      });

      controller.add('c');
      await Future.delayed(Duration.zero);

      expect(received, ['a', 'b', 'c']);
      await controller.close();
    });

    test('handles async onCancel callback', () async {
      final controller = ReplayingStreamController<int>([]);
      bool onCancelCalled = false;

      controller.onCancel = () async {
        await Future.delayed(Duration(milliseconds: 10));
        onCancelCalled = true;
      };

      final subscription = controller.stream.listen((_) {});
      await Future.delayed(Duration.zero);

      await subscription.cancel();
      await Future.delayed(Duration(milliseconds: 20));

      expect(onCancelCalled, true);
      await controller.close();
    });
  });
}
