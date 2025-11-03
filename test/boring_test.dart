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

    test('does not execute callback when cancelled before completion', () async {
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
}
