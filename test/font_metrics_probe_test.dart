// prints the line-box metrics Flutter actually uses for Dongle, to validate the constants in boring.dart's BandCenteredText.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFont(String family, List<String> assets) async {
  final loader = FontLoader(family);
  for (final a in assets) {
    loader.addFont(rootBundle.load(a));
  }
  await loader.load();
}

void probe(String label, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: '0123 abc XYZ', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final m = tp.computeLineMetrics().single;
  final fs = style.fontSize!;
  final boxCenterAboveBaselineEm = (m.baseline - m.height / 2) / fs;
  debugPrint(
      '$label: ascent ${m.ascent / fs} em, descent ${m.descent / fs} em, '
      'height ${m.height / fs} em, baseline ${m.baseline / fs} em, '
      'boxCenterAboveBaseline ${boxCenterAboveBaselineEm.toStringAsFixed(4)} em');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dongle line box metrics', (tester) async {
    await loadFont('Dongle', [
      'assets/fonts/Dongle-Regular.ttf',
      'assets/fonts/Dongle-Bold.ttf',
    ]);

    for (final (name, weight) in [
      ('Regular', FontWeight.w400),
      ('Bold', FontWeight.w700),
    ]) {
      final base = TextStyle(
        fontFamily: 'Dongle',
        fontSize: 100,
        fontWeight: weight,
      );
      probe('$name natural', base);
      probe(
        '$name h=1.32 even',
        base.copyWith(
          height: 1.32,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      );
      probe(
        '$name h=1.0 even',
        base.copyWith(
          height: 1.0,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      );
      probe(
        '$name h=0.71 even',
        base.copyWith(
          height: 0.71,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      );
      probe('$name h=1.0 proportional (default)', base.copyWith(height: 1.0));
    }
  });
}
