import 'dart:math' as math;
import 'dart:typed_data';

enum ObstacleShape { circle, box, triangle }

/// An obstacle in normalized coordinates (x, y in 0..1 of the canvas).
/// [size] is the half-extent / radius as a fraction of canvas height.
class Obstacle {
  Obstacle({required this.shape, required this.x, required this.y, this.size = 0.07});

  final ObstacleShape shape;
  double x;
  double y;
  double size;

  /// Velocity in cells/sec, non-zero only while being dragged.
  double velX = 0;
  double velY = 0;

  /// Hit test in "height units": px = xNorm * aspect, py = yNorm.
  bool contains(double px, double py, double aspect) {
    final dx = px - x * aspect;
    final dy = py - y;
    switch (shape) {
      case ObstacleShape.circle:
        return dx * dx + dy * dy < size * size;
      case ObstacleShape.box:
        return dx.abs() < size && dy.abs() < size;
      case ObstacleShape.triangle:
        return _inTriangle(dx, dy, size);
    }
  }

  static bool _inTriangle(double dx, double dy, double r) {
    // Equilateral triangle pointing up, circumradius r, centered at origin.
    const c30 = 0.8660254037844387; // cos(30°)
    final ax = 0.0, ay = -r; // top
    final bx = -r * c30, by = r * 0.5; // bottom-left
    final cx = r * c30, cy = r * 0.5; // bottom-right
    final d1 = _cross(dx - ax, dy - ay, bx - ax, by - ay);
    final d2 = _cross(dx - bx, dy - by, cx - bx, cy - by);
    final d3 = _cross(dx - cx, dy - cy, ax - cx, ay - cy);
    final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }

  static double _cross(double ax, double ay, double bx, double by) =>
      ax * by - ay * bx;
}

/// Real-time Eulerian fluid solver (Jos Stam "Stable Fluids" variant):
/// semi-Lagrangian advection, Gauss-Seidel pressure projection with
/// solid-cell (Neumann) boundaries, and vorticity confinement.
/// All fields are flat Float32Lists of (w+2)*(h+2) with a 1-cell solid border.
class FluidSolver {
  FluidSolver({required this.w, required this.h, required this.aspect})
      : stride = w + 2,
        cells = (w + 2) * (h + 2) {
    u = Float32List(cells);
    v = Float32List(cells);
    _u0 = Float32List(cells);
    _v0 = Float32List(cells);
    r = Float32List(cells);
    g = Float32List(cells);
    b = Float32List(cells);
    _r0 = Float32List(cells);
    _g0 = Float32List(cells);
    _b0 = Float32List(cells);
    _p = Float32List(cells);
    _div = Float32List(cells);
    _curl = Float32List(cells);
    solid = Uint8List(cells);
    _uSolid = Float32List(cells);
    _vSolid = Float32List(cells);
    rebuildSolids(const []);
  }

  final int w; // interior width in cells
  final int h; // interior height in cells
  final double aspect; // canvas width / height
  final int stride;
  final int cells;

  late Float32List u, v, r, g, b;
  late Float32List _u0, _v0, _r0, _g0, _b0, _p, _div, _curl;
  late Uint8List solid;
  late Float32List _uSolid, _vSolid;

  double vorticity = 1.4;
  double velocityDissipation = 0.999;
  double dyeDissipation = 0.9975;
  int pressureIterations = 18;

  int _idx(int i, int j) => i + j * stride;

  /// Re-rasterizes the solid mask from [obstacles] plus the domain border.
  void rebuildSolids(List<Obstacle> obstacles) {
    solid.fillRange(0, cells, 0);
    _uSolid.fillRange(0, cells, 0);
    _vSolid.fillRange(0, cells, 0);
    for (int i = 0; i < stride; i++) {
      solid[_idx(i, 0)] = 1;
      solid[_idx(i, h + 1)] = 1;
    }
    for (int j = 0; j < h + 2; j++) {
      solid[_idx(0, j)] = 1;
      solid[_idx(w + 1, j)] = 1;
    }
    for (final o in obstacles) {
      for (int j = 1; j <= h; j++) {
        final py = (j - 0.5) / h;
        final row = j * stride;
        for (int i = 1; i <= w; i++) {
          final px = (i - 0.5) / w * aspect;
          if (o.contains(px, py, aspect)) {
            final k = row + i;
            solid[k] = 1;
            _uSolid[k] = o.velX;
            _vSolid[k] = o.velY;
          }
        }
      }
    }
  }

  /// Adds dye and momentum in a gaussian blob. [cx],[cy] in cell coords,
  /// [radius] in cells, velocity in cells/sec.
  void splat({
    required double cx,
    required double cy,
    required double radius,
    double velX = 0,
    double velY = 0,
    double dyeR = 0,
    double dyeG = 0,
    double dyeB = 0,
  }) {
    final r2 = radius * radius;
    final x0 = math.max(1, (cx - radius).floor());
    final x1 = math.min(w, (cx + radius).ceil());
    final y0 = math.max(1, (cy - radius).floor());
    final y1 = math.min(h, (cy + radius).ceil());
    for (int j = y0; j <= y1; j++) {
      for (int i = x0; i <= x1; i++) {
        final dx = i - cx, dy = j - cy;
        final d2 = dx * dx + dy * dy;
        if (d2 > r2) continue;
        final k = _idx(i, j);
        if (solid[k] != 0) continue;
        final fall = math.exp(-d2 / (r2 * 0.5));
        u[k] += velX * fall;
        v[k] += velY * fall;
        r[k] += dyeR * fall;
        g[k] += dyeG * fall;
        b[k] += dyeB * fall;
      }
    }
  }

  void step(double dt) {
    _enforceSolids();
    _confineVorticity(dt);
    _swapVelocity();
    _advect(u, _u0, _u0, _v0, dt, velocityDissipation);
    _advect(v, _v0, _u0, _v0, dt, velocityDissipation);
    _project();
    _swapDye();
    _advect(r, _r0, u, v, dt, dyeDissipation);
    _advect(g, _g0, u, v, dt, dyeDissipation);
    _advect(b, _b0, u, v, dt, dyeDissipation);
  }

  void _enforceSolids() {
    for (int k = 0; k < cells; k++) {
      if (solid[k] != 0) {
        u[k] = _uSolid[k];
        v[k] = _vSolid[k];
        r[k] = 0;
        g[k] = 0;
        b[k] = 0;
      }
    }
  }

  void _swapVelocity() {
    var t = _u0;
    _u0 = u;
    u = t;
    t = _v0;
    _v0 = v;
    v = t;
  }

  void _swapDye() {
    var t = _r0;
    _r0 = r;
    r = t;
    t = _g0;
    _g0 = g;
    g = t;
    t = _b0;
    _b0 = b;
    b = t;
  }

  void _advect(Float32List d, Float32List d0, Float32List uu, Float32List vv,
      double dt, double dissipation) {
    final wMax = w + 0.5, hMax = h + 0.5;
    for (int j = 1; j <= h; j++) {
      final row = j * stride;
      for (int i = 1; i <= w; i++) {
        final k = row + i;
        if (solid[k] != 0) continue;
        double x = i - dt * uu[k];
        double y = j - dt * vv[k];
        if (x < 0.5) x = 0.5;
        if (x > wMax) x = wMax;
        if (y < 0.5) y = 0.5;
        if (y > hMax) y = hMax;
        final i0 = x.floor();
        final j0 = y.floor();
        final s1 = x - i0, s0 = 1 - s1;
        final t1 = y - j0, t0 = 1 - t1;
        final k00 = i0 + j0 * stride;
        d[k] = dissipation *
            (s0 * (t0 * d0[k00] + t1 * d0[k00 + stride]) +
                s1 * (t0 * d0[k00 + 1] + t1 * d0[k00 + stride + 1]));
      }
    }
  }

  void _project() {
    final p = _p, div = _div;
    for (int j = 1; j <= h; j++) {
      final row = j * stride;
      for (int i = 1; i <= w; i++) {
        final k = row + i;
        if (solid[k] != 0) {
          div[k] = 0;
          p[k] = 0;
          continue;
        }
        div[k] = -0.5 * (u[k + 1] - u[k - 1] + v[k + stride] - v[k - stride]);
        p[k] = 0;
      }
    }
    for (int iter = 0; iter < pressureIterations; iter++) {
      for (int j = 1; j <= h; j++) {
        final row = j * stride;
        for (int i = 1; i <= w; i++) {
          final k = row + i;
          if (solid[k] != 0) continue;
          final pc = p[k];
          final pl = solid[k - 1] != 0 ? pc : p[k - 1];
          final pr = solid[k + 1] != 0 ? pc : p[k + 1];
          final pt = solid[k - stride] != 0 ? pc : p[k - stride];
          final pb = solid[k + stride] != 0 ? pc : p[k + stride];
          p[k] = (div[k] + pl + pr + pt + pb) * 0.25;
        }
      }
    }
    for (int j = 1; j <= h; j++) {
      final row = j * stride;
      for (int i = 1; i <= w; i++) {
        final k = row + i;
        if (solid[k] != 0) continue;
        final pc = p[k];
        final pl = solid[k - 1] != 0 ? pc : p[k - 1];
        final pr = solid[k + 1] != 0 ? pc : p[k + 1];
        final pt = solid[k - stride] != 0 ? pc : p[k - stride];
        final pb = solid[k + stride] != 0 ? pc : p[k + stride];
        u[k] -= 0.5 * (pr - pl);
        v[k] -= 0.5 * (pb - pt);
      }
    }
  }

  void _confineVorticity(double dt) {
    if (vorticity <= 0) return;
    final curl = _curl;
    for (int j = 1; j <= h; j++) {
      final row = j * stride;
      for (int i = 1; i <= w; i++) {
        final k = row + i;
        curl[k] = 0.5 *
            ((v[k + 1] - v[k - 1]) - (u[k + stride] - u[k - stride]));
      }
    }
    for (int j = 2; j < h; j++) {
      final row = j * stride;
      for (int i = 2; i < w; i++) {
        final k = row + i;
        if (solid[k] != 0) continue;
        double gx = 0.5 * (curl[k + 1].abs() - curl[k - 1].abs());
        double gy = 0.5 * (curl[k + stride].abs() - curl[k - stride].abs());
        final len = math.sqrt(gx * gx + gy * gy) + 1e-5;
        gx /= len;
        gy /= len;
        final c = curl[k] * vorticity;
        u[k] += gy * c * dt;
        v[k] -= gx * c * dt;
      }
    }
  }

  /// Writes the dye field as RGBA into [out] (must be w * h * 4 bytes).
  void writePixels(Uint8List out) {
    int o = 0;
    for (int j = 1; j <= h; j++) {
      final row = j * stride;
      for (int i = 1; i <= w; i++) {
        final k = row + i;
        double cr = r[k], cg = g[k], cb = b[k];
        if (cr > 1) cr = 1;
        if (cg > 1) cg = 1;
        if (cb > 1) cb = 1;
        // sqrt tone map: lifts faint dye into the visible range.
        out[o] = (math.sqrt(cr) * 255).toInt();
        out[o + 1] = (math.sqrt(cg) * 255).toInt();
        out[o + 2] = (math.sqrt(cb) * 255).toInt();
        out[o + 3] = 255;
        o += 4;
      }
    }
  }
}
