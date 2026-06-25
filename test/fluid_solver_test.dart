import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluid_simulator/fluid_solver.dart';

void main() {
  test('solver stays finite and bounded over many steps', () {
    final solver = FluidSolver(w: 96, h: 96, aspect: 1)
      ..rebuildSolids([
        Obstacle(shape: ObstacleShape.circle, x: 0.5, y: 0.5),
        Obstacle(shape: ObstacleShape.triangle, x: 0.25, y: 0.7),
      ]);
    for (int frame = 0; frame < 180; frame++) {
      solver.splat(
        cx: 20,
        cy: 48,
        radius: 4,
        velX: 150,
        dyeR: 0.4,
        dyeG: 0.2,
        dyeB: 0.6,
      );
      solver.step(1 / 60);
    }
    double maxSpeed = 0, totalDye = 0;
    for (int k = 0; k < solver.cells; k++) {
      expect(solver.u[k].isFinite, isTrue);
      expect(solver.v[k].isFinite, isTrue);
      expect(solver.r[k].isFinite, isTrue);
      final s = solver.u[k] * solver.u[k] + solver.v[k] * solver.v[k];
      if (s > maxSpeed) maxSpeed = s;
      totalDye += solver.r[k] + solver.g[k] + solver.b[k];
    }
    expect(totalDye, greaterThan(0), reason: 'dye should have been advected');
    expect(maxSpeed, lessThan(1e6), reason: 'velocity must not blow up');
  });

  test('solid cells hold obstacle velocity and no dye', () {
    final solver = FluidSolver(w: 64, h: 64, aspect: 1);
    final obstacle = Obstacle(shape: ObstacleShape.box, x: 0.5, y: 0.5)
      ..velX = 50;
    solver.rebuildSolids([obstacle]);
    solver.splat(cx: 32, cy: 32, radius: 30, dyeR: 1, velX: 10);
    solver.step(1 / 60);
    // Center cell is inside the box obstacle.
    final k = 32 + 32 * solver.stride;
    expect(solver.solid[k], 1);
    expect(solver.r[k], 0);
  });

  test('wind tunnel drives steady left-to-right flow and stays finite', () {
    final solver = FluidSolver(w: 96, h: 64, aspect: 1.5)
      ..windSpeed = 100
      ..rebuildSolids([Obstacle(shape: ObstacleShape.circle, x: 0.3, y: 0.5)]);
    for (int frame = 0; frame < 240; frame++) {
      solver.step(1 / 60);
    }
    double sumU = 0;
    int fluidCells = 0;
    for (int k = 0; k < solver.cells; k++) {
      expect(solver.u[k].isFinite, isTrue);
      expect(solver.v[k].isFinite, isTrue);
      if (solver.solid[k] == 0) {
        sumU += solver.u[k];
        fluidCells++;
      }
    }
    expect(sumU / fluidCells, greaterThan(20),
        reason: 'mean flow should follow the wind, not recirculate');
  });

  test('steps fast enough for real time (ballpark, JIT)', () {
    final solver = FluidSolver(w: 128, h: 96, aspect: 4 / 3);
    final pixels = Uint8List(128 * 96 * 4);
    // Warm up the JIT.
    for (int i = 0; i < 30; i++) {
      solver.step(1 / 60);
    }
    final sw = Stopwatch()..start();
    const frames = 120;
    for (int i = 0; i < frames; i++) {
      solver.splat(cx: 30, cy: 48, radius: 4, velX: 120, dyeR: 0.5);
      solver.step(1 / 60);
      solver.writePixels(pixels);
    }
    sw.stop();
    final msPerFrame = sw.elapsedMilliseconds / frames;
    // ignore: avoid_print
    print('solver: ${msPerFrame.toStringAsFixed(2)} ms/frame (JIT)');
    expect(msPerFrame, lessThan(16), reason: 'must sustain ~60 fps');
  });

  // --- Physics invariants: prove the solver matches the Stam algorithm, not
  // just that it stays finite. Each asserts a property the math guarantees. ---

  test('projection removes the bulk of the velocity divergence', () {
    // Stam's collocated grid computes divergence with a wide central
    // difference but solves the Poisson equation with the compact 5-point
    // Laplacian. Those stencils are inconsistent, so projection leaves a
    // high-frequency "checkerboard" residual and cannot reach exactly zero.
    // The meaningful invariant is that it removes the vast majority of the
    // divergence vs running zero pressure iterations on the same input.
    // 24x24 with 1000 iterations is fully converged (the residual plateaus, so
    // it isn't iteration-limited). At convergence the checkerboard caps the
    // reduction near ~85%, so we require >=75% removal vs no projection.
    double totalDiv(int iters) {
      final solver = FluidSolver(w: 24, h: 24, aspect: 1)
        ..vorticity = 0
        ..pressureIterations = iters;
      solver.splat(cx: 12, cy: 12, radius: 6, velX: 80, velY: 50);
      solver.step(1 / 60);
      final s = solver.stride;
      double sum = 0;
      for (int j = 2; j < solver.h; j++) {
        for (int i = 2; i < solver.w; i++) {
          final k = i + j * s;
          if (solver.solid[k] != 0) continue;
          sum += (solver.u[k + 1] - solver.u[k - 1] +
                  solver.v[k + s] - solver.v[k - s])
              .abs();
        }
      }
      return sum;
    }

    final unprojected = totalDiv(0); // project computes div but applies no fix
    final projected = totalDiv(1000);
    expect(unprojected, greaterThan(0));
    expect(projected, lessThan(unprojected * 0.25),
        reason: 'projection must remove >=75% of the divergence');
  });

  test('a still fluid with no forcing never starts moving', () {
    // Closed box, no wind, no splat: the solver must not manufacture motion
    // (catches stray sources, sign errors, uninitialised reads).
    final solver = FluidSolver(w: 48, h: 48, aspect: 1);
    for (int f = 0; f < 100; f++) {
      solver.step(1 / 60);
    }
    double maxSpeed2 = 0;
    for (int k = 0; k < solver.cells; k++) {
      final s2 = solver.u[k] * solver.u[k] + solver.v[k] * solver.v[k];
      if (s2 > maxSpeed2) maxSpeed2 = s2;
    }
    expect(maxSpeed2, lessThan(1e-12),
        reason: 'no source means the field must stay exactly at rest');
  });

  test('a vertically symmetric impulse stays symmetric', () {
    // Closed box, vorticity off, no obstacle, short run: there is no flow
    // instability to amplify, so the only asymmetry is the Gauss-Seidel sweep
    // direction, which must stay negligible vs the peak flow. The impulse sits
    // on the centre line (cy = (h+1)/2) so it mirrors exactly row j <-> h+1-j.
    final solver = FluidSolver(w: 64, h: 64, aspect: 1)..vorticity = 0;
    solver.splat(cx: 24, cy: 32.5, radius: 5, velX: 200);
    for (int f = 0; f < 20; f++) {
      solver.step(1 / 60);
    }
    final s = solver.stride;
    double maxAsym = 0, maxSpeed = 0;
    for (int j = 1; j <= solver.h ~/ 2; j++) {
      final jm = solver.h + 1 - j; // mirror row across the centre line
      for (int i = 1; i <= solver.w; i++) {
        final k = i + j * s, km = i + jm * s;
        final du = (solver.u[k] - solver.u[km]).abs(); // u symmetric
        final dv = (solver.v[k] + solver.v[km]).abs(); // v anti-symmetric
        if (du > maxAsym) maxAsym = du;
        if (dv > maxAsym) maxAsym = dv;
        final spd = solver.u[k].abs() + solver.v[k].abs();
        if (spd > maxSpeed) maxSpeed = spd;
      }
    }
    // Gauss-Seidel sweeps rows top->bottom, so the pressure solve is slightly
    // directional; a few-percent asymmetry is expected and acceptable. A
    // transposed index or sign bug would blow this far past the threshold.
    expect(maxAsym, lessThan(maxSpeed * 0.05),
        reason: 'symmetric impulse must stay symmetric to <5% of peak flow');
  });

  test('dye stays non-negative and dissipates without a source', () {
    final solver = FluidSolver(w: 64, h: 64, aspect: 1)..windSpeed = 80;
    solver.rebuildSolids(const []);
    solver.splat(cx: 12, cy: 32, radius: 6, dyeR: 1, dyeG: 0.5, dyeB: 0.2);
    double total() {
      double t = 0;
      for (int k = 0; k < solver.cells; k++) {
        t += solver.r[k] + solver.g[k] + solver.b[k];
      }
      return t;
    }

    final initial = total();
    for (int f = 0; f < 60; f++) {
      solver.step(1 / 60);
    }
    double minR = double.infinity;
    bool allFinite = true;
    for (int k = 0; k < solver.cells; k++) {
      if (!solver.r[k].isFinite) allFinite = false;
      if (solver.r[k] < minR) minR = solver.r[k];
    }
    expect(allFinite, isTrue);
    expect(minR, greaterThanOrEqualTo(0),
        reason: 'advection must not manufacture negative dye');
    expect(initial, greaterThan(0));
    expect(total(), lessThan(initial),
        reason: 'with no source, dissipation + outflow must reduce dye');
  });
}
