import 'dart:math' as math;
import 'dart:ui' show Offset;

int _u32(int x) => x & 0xFFFFFFFF;

int _fmix32(int k) {
  k = _u32(k);
  k ^= k >> 16;
  k = _u32(k * 0x85ebca6b);
  k ^= k >> 13;
  k = _u32(k * 0xc2b2ae35);
  k ^= k >> 16;
  return k;
}

int hashCorner(int x, int y, int seed) {
  var h = _fmix32(seed ^ 0x185FA56D);
  h = _fmix32(h ^ _u32(x * 0xCC9E2D51));
  h = _fmix32(h ^ _u32(y * 0x1B873593));
  return _fmix32(h);
}

double _to01(double n) => (n * 0.5 + 0.5).clamp(0.0, 1.0);

double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Hermite edge curve: 0 at [edge0], 1 at [edge1], zero derivative at both ends;
/// [x] is clamped into the interval. Matches GLSL `smoothstep` when [edge0] < [edge1].
double smoothstep(double edge0, double edge1, double x) {
  if (edge0 == edge1) {
    return x < edge0 ? 0.0 : 1.0;
  }
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// Smoothstep with adjustable transition strength.
///
/// [strength] controls the curve intensity:
/// - `1.0`: identical to [smoothstep]
/// - `> 1.0`: steeper transition near the middle
/// - `< 1.0`: softer transition near the middle
///
/// Parameter order intentionally keeps [strength] before [x].
double smoothstepStrength(
    double edge0, double edge1, double strength, double x) {
  final s = smoothstep(edge0, edge1, x);
  if (strength == 1.0) return s;
  if (s < 0.5) return 0.5 * math.pow(2.0 * s, strength).toDouble();
  return 1.0 - 0.5 * math.pow(2.0 * (1.0 - s), strength).toDouble();
}

double scalarFromHashInt(int hash) {
  return (hash & 0xFFFFFF) / 16777216.0;
}

double weightedAverage(List<(double, double)> values) {
  double totalWeight = 0;
  double totalValue = 0;
  for (final (weight, value) in values) {
    totalWeight += weight;
    totalValue += value * weight;
  }
  return totalValue / totalWeight;
}

void _unitGrad2(int h, List<double> sink) {
  final t = scalarFromHashInt(h) * (2 * math.pi);
  sink[0] = math.cos(t);
  sink[1] = math.sin(t);
}

/// Square-grid Perlin (quintic fade, hash-based gradients). No fixed 256 period.
///
/// Scale [o] before calling if you want a different feature size. [seed] selects an
/// independent field (e.g. per layer).
///
/// If both components of [o] are integers, the value is always 0.5 (the raw noise is
/// 0 on the lattice). For a discrete grid of cells, sample with a fractional bias in
/// noise space (e.g. `x * scale + 0.5`).
double perlin(Offset o, int seed) {
  final x = o.dx;
  final y = o.dy;
  final xi = x.floor();
  final yi = y.floor();
  final xf = x - xi;
  final yf = y - yi;
  final u = _fade(xf);
  final v = _fade(yf);

  final g = List<double>.filled(2, 0);
  _unitGrad2(hashCorner(xi, yi, seed), g);
  final gx00 = g[0], gy00 = g[1];
  _unitGrad2(hashCorner(xi + 1, yi, seed), g);
  final gx10 = g[0], gy10 = g[1];
  _unitGrad2(hashCorner(xi, yi + 1, seed), g);
  final gx01 = g[0], gy01 = g[1];
  _unitGrad2(hashCorner(xi + 1, yi + 1, seed), g);
  final gx11 = g[0], gy11 = g[1];

  final n00 = gx00 * xf + gy00 * yf;
  final n10 = gx10 * (xf - 1) + gy10 * yf;
  final n01 = gx01 * xf + gy01 * (yf - 1);
  final n11 = gx11 * (xf - 1) + gy11 * (yf - 1);

  final nx0 = _lerp(n00, n10, u);
  final nx1 = _lerp(n01, n11, u);
  return _to01(_lerp(nx0, nx1, v));
}

double _simplexGrad7(int hash, double x, double y) {
  final h = hash & 7;
  final u = h < 4 ? x : y;
  final v = h < 4 ? y : x;
  return ((h & 1) != 0 ? -u : u) + ((h & 2) != 0 ? -2.0 * v : 2.0 * v);
}

double _simplexCorner(double x, double y, int h) {
  var t = 0.5 - x * x - y * y;
  if (t <= 0) return 0;
  t *= t;
  return t * t * _simplexGrad7(h, x, y);
}

/// 2D simplex **gradient** noise (triangular lattice, polynomial kernel). Different
/// character than [perlin] (typically less axis-aligned streaking).
///
/// Scale [o] before calling if you want a different feature size. [seed] selects an
/// independent field (e.g. per layer).
double gradientNoise(Offset o, int seed) {
  final x = o.dx;
  final y = o.dy;

  const f2 = 0.36602540378443865; // (sqrt(3) - 1) / 2
  const g2 = 0.21132486540518713; // (3 - sqrt(3)) / 6

  final s = (x + y) * f2;
  final i = (x + s).floor();
  final j = (y + s).floor();

  final t = (i + j) * g2;
  final x0 = x - (i - t);
  final y0 = y - (j - t);

  final late = x0 > y0;
  final i1 = late ? 1 : 0;
  final j1 = late ? 0 : 1;

  final x1 = x0 - i1 + g2;
  final y1 = y0 - j1 + g2;
  final x2 = x0 - 1.0 + 2.0 * g2;
  final y2 = y0 - 1.0 + 2.0 * g2;

  final h0 = hashCorner(i, j, seed);
  final h1 = hashCorner(i + i1, j + j1, seed);
  final h2 = hashCorner(i + 1, j + 1, seed);

  final n = 70.0 *
      (_simplexCorner(x0, y0, h0) +
          _simplexCorner(x1, y1, h1) +
          _simplexCorner(x2, y2, h2));
  return _to01(n);
}
