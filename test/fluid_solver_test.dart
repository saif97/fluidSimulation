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
}
