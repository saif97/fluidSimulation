import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'fluid_solver.dart';
import 'shapes.dart';

void main() => runApp(const FluidApp());

class FluidApp extends StatelessWidget {
  const FluidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fluid Simulator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyan,
        useMaterial3: true,
      ),
      home: const SimulationPage(),
    );
  }
}

enum Tool { stir, circle, box, triangle, cow, eraser }

enum RenderMode { ink, particles, heat }

/// Jet-style colormap (blue → cyan → green → yellow → red), t in 0..1.
int _jetArgb(double t) {
  int ch(double v) => (v.clamp(0.0, 1.0) * 255).round();
  return 0xFF000000 |
      (ch(1.5 - (4 * t - 3).abs()) << 16) |
      (ch(1.5 - (4 * t - 2).abs()) << 8) |
      ch(1.5 - (4 * t - 1).abs());
}

class SimulationPage extends StatefulWidget {
  const SimulationPage({super.key});

  @override
  State<SimulationPage> createState() => _SimulationPageState();
}

class _SimulationPageState extends State<SimulationPage>
    with SingleTickerProviderStateMixin {
  static const double _maxInjectSpeed = 400; // cells/sec

  // ---- User-tunable settings (settings shelf) ----
  /// Long-side cell count; higher = sharper dye but more CPU per frame.
  int _gridSide = 192;
  double _vorticity = 1.4;
  double _dyeFade = 0.9975;
  double _splatRadius = 4.5;
  double _wind = 70; // cells/sec left-to-right inflow; 0 = closed box
  bool _settingsOpen = false;
  bool _showIntro = true;
  bool _running = true; // false = simulation paused (ticker keeps idling)
  RenderMode _mode = RenderMode.ink;
  int _warmup = 0; // frames to pre-simulate at startup (?warmup=N)

  // Tracer particles (particles render mode), advected through the velocity
  // field and bucketed by speed into one draw call per colormap stop.
  static const int _particleCount = 12000;
  static const double _speedScale = 150; // cells/sec at colormap top end
  final math.Random _rng = math.Random(7);
  Float32List _partX = Float32List(0);
  Float32List _partY = Float32List(0);
  final List<Float32List> _bucketBuf = List.generate(
      _FluidPainter.bucketColors.length,
      (_) => Float32List(_particleCount * 2));
  final Int32List _bucketLen = Int32List(_FluidPainter.bucketColors.length);
  final ValueNotifier<int> _frame = ValueNotifier(0);

  late final Ticker _ticker;
  FluidSolver? _solver;
  Size _canvasSize = Size.zero;

  // Dye is rendered as a triangle mesh with per-vertex colors
  // (Canvas.drawVertices) — no image codecs involved.
  Float32List _positions = Float32List(0);
  Uint16List _meshIndices = Uint16List(0);
  Int32List _colors = Int32List(0);
  final ValueNotifier<ui.Vertices?> _mesh = ValueNotifier(null);

  final List<Obstacle> _obstacles = [
    // Default obstacle: a cow facing into the wind, shedding vortices from
    // frame one (and a nod to the app icon).
    Obstacle(shape: ObstacleShape.cow, x: 0.32, y: 0.52, size: 0.17),
  ];
  Obstacle? _dragged;
  Tool _tool = Tool.stir;

  Duration _lastTick = Duration.zero;
  double _hue = 200;
  double _fpsEma = 60;

  @override
  void initState() {
    super.initState();
    // Deep links: ?mode=ink|particles|heat&intro=0&warmup=<frames>
    final qp = Uri.base.queryParameters;
    if (qp['intro'] == '0') _showIntro = false;
    _warmup = int.tryParse(qp['warmup'] ?? '') ?? 0;
    _mode = switch (qp['mode']) {
      'particles' => RenderMode.particles,
      'heat' => RenderMode.heat,
      _ => RenderMode.ink,
    };
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _mesh.value?.dispose();
    _mesh.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _ensureSolver(Size size) {
    if (_solver != null && size == _canvasSize) return;
    _canvasSize = size;
    final aspect = size.width / size.height;
    int gw, gh;
    if (aspect >= 1) {
      gw = _gridSide;
      gh = (_gridSide / aspect).round().clamp(48, _gridSide);
    } else {
      gh = _gridSide;
      gw = (_gridSide * aspect).round().clamp(48, _gridSide);
    }
    // Mesh indices are Uint16, so the vertex count must stay under 65536.
    while ((gw + 2) * (gh + 2) > 65535) {
      gw = (gw * 0.97).floor();
      gh = (gh * 0.97).floor();
    }
    _solver = FluidSolver(w: gw, h: gh, aspect: aspect)
      ..vorticity = _vorticity
      ..dyeDissipation = _dyeFade
      ..windSpeed = _wind
      ..rebuildSolids(_obstacles);
    _buildMesh(_solver!, size);
    _initParticles(_solver!);
    if (_warmup > 0) {
      final s = _solver!;
      for (int i = 0; i < _warmup; i++) {
        if (_wind > 0 && _mode == RenderMode.ink) _seedStreaks(s);
        s.step(1 / 60);
        if (_mode == RenderMode.particles) _stepParticles(s, 1 / 60);
      }
      _warmup = 0;
    }
  }

  /// Quality change: rebuild the solver at the new resolution. Obstacles are
  /// normalized so they survive; dye/velocity restart from rest.
  void _setGridSide(int side) {
    if (side == _gridSide) return;
    setState(() {
      _gridSide = side;
      _solver = null;
      final size = _canvasSize;
      _canvasSize = Size.zero;
      if (size != Size.zero) _ensureSolver(size);
    });
  }

  /// One vertex per grid cell (including the border ring, clamped to the
  /// canvas edge); two triangles per quad between neighboring cell centers.
  void _buildMesh(FluidSolver s, Size size) {
    final vw = s.w + 2, vh = s.h + 2;
    _positions = Float32List(vw * vh * 2);
    _colors = Int32List(vw * vh);
    int p = 0;
    for (int j = 0; j < vh; j++) {
      final y = ((j - 0.5) / s.h).clamp(0.0, 1.0) * size.height;
      for (int i = 0; i < vw; i++) {
        _positions[p++] = ((i - 0.5) / s.w).clamp(0.0, 1.0) * size.width;
        _positions[p++] = y;
      }
    }
    _meshIndices = Uint16List((vw - 1) * (vh - 1) * 6);
    int q = 0;
    for (int j = 0; j < vh - 1; j++) {
      for (int i = 0; i < vw - 1; i++) {
        final tl = j * vw + i;
        _meshIndices[q++] = tl;
        _meshIndices[q++] = tl + 1;
        _meshIndices[q++] = tl + vw;
        _meshIndices[q++] = tl + 1;
        _meshIndices[q++] = tl + vw + 1;
        _meshIndices[q++] = tl + vw;
      }
    }
  }

  void _updateMesh(FluidSolver s) {
    final n = _colors.length;
    for (int k = 0; k < n; k++) {
      double cr = s.r[k], cg = s.g[k], cb = s.b[k];
      if (cr > 1) cr = 1;
      if (cg > 1) cg = 1;
      if (cb > 1) cb = 1;
      // sqrt tone map lifts faint dye into the visible range.
      _colors[k] = 0xFF000000 |
          ((math.sqrt(cr) * 255).toInt() << 16) |
          ((math.sqrt(cg) * 255).toInt() << 8) |
          (math.sqrt(cb) * 255).toInt();
    }
    // Solid cells hold zero dye, which gouraud-interpolates to a black
    // staircase around obstacles. Give them the average of their fluid
    // neighbors so the dye continues smoothly under the drawn shape.
    final solid = s.solid;
    final stride = s.stride;
    for (int k = 0; k < n; k++) {
      if (solid[k] == 0) continue;
      final i = k % stride;
      double cr = 0, cg = 0, cb = 0;
      int cnt = 0;
      if (i > 0 && solid[k - 1] == 0) {
        cr += s.r[k - 1];
        cg += s.g[k - 1];
        cb += s.b[k - 1];
        cnt++;
      }
      if (i < stride - 1 && solid[k + 1] == 0) {
        cr += s.r[k + 1];
        cg += s.g[k + 1];
        cb += s.b[k + 1];
        cnt++;
      }
      if (k >= stride && solid[k - stride] == 0) {
        cr += s.r[k - stride];
        cg += s.g[k - stride];
        cb += s.b[k - stride];
        cnt++;
      }
      if (k + stride < n && solid[k + stride] == 0) {
        cr += s.r[k + stride];
        cg += s.g[k + stride];
        cb += s.b[k + stride];
        cnt++;
      }
      if (cnt == 0) continue;
      cr = (cr / cnt).clamp(0.0, 1.0);
      cg = (cg / cnt).clamp(0.0, 1.0);
      cb = (cb / cnt).clamp(0.0, 1.0);
      _colors[k] = 0xFF000000 |
          ((math.sqrt(cr) * 255).toInt() << 16) |
          ((math.sqrt(cg) * 255).toInt() << 8) |
          (math.sqrt(cb) * 255).toInt();
    }
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      colors: _colors,
      indices: _meshIndices,
    );
    _mesh.value?.dispose();
    _mesh.value = verts;
  }

  void _onTick(Duration elapsed) {
    final solver = _solver;
    if (solver == null) {
      _lastTick = elapsed;
      return;
    }
    // Paused: keep the ticker idling (so resume gets a sane dt) but freeze the
    // sim — no stepping, no repaint.
    if (!_running) {
      _lastTick = elapsed;
      return;
    }
    double dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 1 / 20) dt = 1 / 60;
    _fpsEma = _fpsEma * 0.95 + (1 / dt) * 0.05;
    _hue = (_hue + dt * 40) % 360;

    if (_wind > 0 && _mode == RenderMode.ink) _seedStreaks(solver);
    solver.step(dt);
    switch (_mode) {
      case RenderMode.ink:
        _updateMesh(solver);
      case RenderMode.heat:
        _updateHeatMesh(solver);
      case RenderMode.particles:
        _stepParticles(solver, dt);
    }
    _frame.value++;
  }

  /// Colors every mesh vertex by local speed through the jet colormap.
  void _updateHeatMesh(FluidSolver s) {
    final n = _colors.length;
    for (int k = 0; k < n; k++) {
      final spd = math.sqrt(s.u[k] * s.u[k] + s.v[k] * s.v[k]);
      _colors[k] = _jetArgb(math.sqrt((spd / _speedScale).clamp(0.0, 1.0)));
    }
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      colors: _colors,
      indices: _meshIndices,
    );
    _mesh.value?.dispose();
    _mesh.value = verts;
  }

  /// Rainbow dye streaklines emitted at the inlet (wind tunnel, ink mode).
  void _seedStreaks(FluidSolver s) {
    const streams = 9;
    for (int i = 0; i < streams; i++) {
      final color =
          HSVColor.fromAHSV(1, 360 * i / streams, 0.75, 1).toColor();
      s.splat(
        cx: 2.5,
        cy: (i + 0.5) / streams * s.h + 0.5,
        radius: 1.6,
        dyeR: color.r * 0.4,
        dyeG: color.g * 0.4,
        dyeB: color.b * 0.4,
      );
    }
  }

  void _initParticles(FluidSolver s) {
    _partX = Float32List(_particleCount);
    _partY = Float32List(_particleCount);
    // Uniform initial fill (even with wind on); ones inside solids respawn.
    for (int n = 0; n < _particleCount; n++) {
      _partX[n] = 0.5 + _rng.nextDouble() * s.w;
      _partY[n] = 0.5 + _rng.nextDouble() * s.h;
    }
  }

  void _respawnParticle(FluidSolver s, int n) {
    // With wind on, recycle particles at the inlet for streamline trails.
    final spanX = _wind > 0 ? 2.0 : s.w.toDouble();
    for (int tries = 0; tries < 8; tries++) {
      final x = 0.5 + _rng.nextDouble() * spanX;
      final y = 0.5 + _rng.nextDouble() * s.h;
      final k =
          x.round().clamp(1, s.w) + y.round().clamp(1, s.h) * s.stride;
      if (s.solid[k] == 0) {
        _partX[n] = x;
        _partY[n] = y;
        return;
      }
    }
    _partX[n] = 0.5 + _rng.nextDouble() * s.w;
    _partY[n] = 0.5 + _rng.nextDouble() * s.h;
  }

  /// Advects tracers through the velocity field and fills the per-speed
  /// bucket point buffers (canvas pixels) for rendering.
  void _stepParticles(FluidSolver s, double dt) {
    _bucketLen.fillRange(0, _bucketLen.length, 0);
    final pw = _canvasSize.width, ph = _canvasSize.height;
    final wMax = s.w + 0.5, hMax = s.h + 0.5;
    final buckets = _bucketBuf.length;
    final stride = s.stride;
    for (int n = 0; n < _particleCount; n++) {
      double x = _partX[n], y = _partY[n];
      // Bilinear velocity sample in the solver's cell-center space.
      final sx = x.clamp(0.5, wMax), sy = y.clamp(0.5, hMax);
      final i0 = sx.floor(), j0 = sy.floor();
      final s1 = sx - i0, s0 = 1 - s1, t1 = sy - j0, t0 = 1 - t1;
      final k00 = i0 + j0 * stride;
      final vx = s0 * (t0 * s.u[k00] + t1 * s.u[k00 + stride]) +
          s1 * (t0 * s.u[k00 + 1] + t1 * s.u[k00 + stride + 1]);
      final vy = s0 * (t0 * s.v[k00] + t1 * s.v[k00 + stride]) +
          s1 * (t0 * s.v[k00 + 1] + t1 * s.v[k00 + stride + 1]);
      x += vx * dt;
      y += vy * dt;
      bool dead = x < 0.5 || x > wMax || y < 0.5 || y > hMax;
      if (!dead) {
        final k =
            x.round().clamp(1, s.w) + y.round().clamp(1, s.h) * stride;
        dead = s.solid[k] != 0;
      }
      // Small random respawn keeps stagnant pools from going stale.
      if (dead || _rng.nextDouble() < 0.002) {
        _respawnParticle(s, n);
        continue;
      }
      _partX[n] = x;
      _partY[n] = y;
      final spd = math.sqrt(vx * vx + vy * vy);
      final t = math.sqrt((spd / _speedScale).clamp(0.0, 1.0));
      int b = (t * buckets).floor();
      if (b >= buckets) b = buckets - 1;
      final len = _bucketLen[b];
      final buf = _bucketBuf[b];
      buf[len] = (x - 0.5) / s.w * pw;
      buf[len + 1] = (y - 0.5) / s.h * ph;
      _bucketLen[b] = len + 2;
    }
  }

  // ---- Input ----------------------------------------------------------

  Offset _toNorm(Offset local) => Offset(
        (local.dx / _canvasSize.width).clamp(0.0, 1.0),
        (local.dy / _canvasSize.height).clamp(0.0, 1.0),
      );

  Obstacle? _hitObstacle(Offset norm) {
    final solver = _solver;
    if (solver == null) return null;
    final px = norm.dx * solver.aspect, py = norm.dy;
    for (final o in _obstacles.reversed) {
      if (o.contains(px, py, solver.aspect)) return o;
    }
    return null;
  }

  void _onPanStart(DragStartDetails d) {
    final solver = _solver;
    if (solver == null) return;
    final n = _toNorm(d.localPosition);
    switch (_tool) {
      case Tool.stir:
        _stir(n, Offset.zero);
      case Tool.eraser:
        _erase(n);
      case Tool.circle:
      case Tool.box:
      case Tool.triangle:
      case Tool.cow:
        final hit = _hitObstacle(n);
        if (hit != null) {
          _dragged = hit;
        } else {
          final shape = switch (_tool) {
            Tool.circle => ObstacleShape.circle,
            Tool.box => ObstacleShape.box,
            Tool.cow => ObstacleShape.cow,
            _ => ObstacleShape.triangle,
          };
          _dragged = Obstacle(
            shape: shape,
            x: n.dx,
            y: n.dy,
            size: shape == ObstacleShape.cow ? 0.17 : 0.07,
          );
          _obstacles.add(_dragged!);
        }
        solver.rebuildSolids(_obstacles);
        setState(() {});
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final solver = _solver;
    if (solver == null) return;
    final n = _toNorm(d.localPosition);
    final deltaN = Offset(
      d.delta.dx / _canvasSize.width,
      d.delta.dy / _canvasSize.height,
    );
    switch (_tool) {
      case Tool.stir:
        _stir(n, deltaN);
      case Tool.eraser:
        _erase(n);
      case Tool.circle:
      case Tool.box:
      case Tool.triangle:
      case Tool.cow:
        final o = _dragged;
        if (o == null) return;
        o.x = n.dx;
        o.y = n.dy;
        // Impart the drag motion to the fluid (cells per second).
        o.velX =
            (deltaN.dx * solver.w * 60).clamp(-_maxInjectSpeed, _maxInjectSpeed);
        o.velY =
            (deltaN.dy * solver.h * 60).clamp(-_maxInjectSpeed, _maxInjectSpeed);
        solver.rebuildSolids(_obstacles);
        setState(() {});
    }
  }

  void _onPanEnd() {
    final o = _dragged;
    _dragged = null;
    if (o != null) {
      o.velX = 0;
      o.velY = 0;
      _solver?.rebuildSolids(_obstacles);
    }
  }

  void _stir(Offset norm, Offset deltaN) {
    final solver = _solver!;
    final color = HSVColor.fromAHSV(1, _hue, 0.85, 1).toColor();
    solver.splat(
      cx: norm.dx * solver.w + 0.5,
      cy: norm.dy * solver.h + 0.5,
      radius: _splatRadius,
      // ~drag speed in cells/sec assuming 60 fps event cadence.
      velX: (deltaN.dx * solver.w * 60).clamp(-_maxInjectSpeed, _maxInjectSpeed),
      velY: (deltaN.dy * solver.h * 60).clamp(-_maxInjectSpeed, _maxInjectSpeed),
      dyeR: color.r * 0.9,
      dyeG: color.g * 0.9,
      dyeB: color.b * 0.9,
    );
  }

  void _erase(Offset norm) {
    final hit = _hitObstacle(norm);
    if (hit != null) {
      _obstacles.remove(hit);
      _solver?.rebuildSolids(_obstacles);
      setState(() {});
    }
  }

  void _clearAll() {
    _obstacles.clear();
    final solver = _solver;
    if (solver != null) {
      solver.rebuildSolids(_obstacles);
      solver.u.fillRange(0, solver.cells, 0);
      solver.v.fillRange(0, solver.cells, 0);
      solver.r.fillRange(0, solver.cells, 0);
      solver.g.fillRange(0, solver.cells, 0);
      solver.b.fillRange(0, solver.cells, 0);
    }
    setState(() {});
  }

  // ---- UI -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _ensureSolver(constraints.biggest);
                return GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: (_) => _onPanEnd(),
                  onPanCancel: _onPanEnd,
                  child: CustomPaint(
                    painter: _FluidPainter(
                      mesh: _mesh,
                      obstacles: _obstacles,
                      mode: _mode,
                      bucketBuf: _bucketBuf,
                      bucketLen: _bucketLen,
                      repaint: _frame,
                      cellPad: _solver == null
                          ? 0
                          : constraints.biggest.height / _solver!.h * 0.75,
                    ),
                    size: constraints.biggest,
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 8,
            right: 12,
            child: ValueListenableBuilder(
              valueListenable: _mesh,
              builder: (_, mesh, child) => Text(
                '${_fpsEma.round()} fps',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_settingsOpen) _buildSettings(),
                  _buildToolbar(),
                ],
              ),
            ),
          ),
          if (_showIntro) _buildIntro(),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolButton(Tool.stir, Icons.gesture, 'Stir fluid'),
          _toolButton(Tool.circle, Icons.circle_outlined, 'Place circle'),
          _toolButton(Tool.box, Icons.crop_square, 'Place box'),
          _toolButton(Tool.triangle, Icons.change_history, 'Place triangle'),
          _toolButton(Tool.cow, Icons.pets, 'Place cow'),
          _toolButton(Tool.eraser, Icons.auto_fix_high, 'Erase object'),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.white24,
          ),
          IconButton(
            tooltip: _running ? 'Pause simulation' : 'Resume simulation',
            icon: Icon(_running ? Icons.pause : Icons.play_arrow),
            color: _running ? Colors.white70 : Colors.cyanAccent,
            onPressed: () => setState(() => _running = !_running),
          ),
          IconButton(
            tooltip: 'Render mode: ${_mode.name} (tap to cycle)',
            icon: Icon(switch (_mode) {
              RenderMode.ink => Icons.water_drop_outlined,
              RenderMode.particles => Icons.grain,
              RenderMode.heat => Icons.thermostat,
            }),
            color: Colors.white70,
            onPressed: () => setState(() {
              _mode = RenderMode
                  .values[(_mode.index + 1) % RenderMode.values.length];
            }),
          ),
          IconButton(
            tooltip: 'Clear everything',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearAll,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            color: _settingsOpen ? Colors.cyanAccent : Colors.white70,
            onPressed: () => setState(() => _settingsOpen = !_settingsOpen),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      constraints: const BoxConstraints(maxWidth: 400),
      decoration: BoxDecoration(
        color: const Color(0xF21A2027),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Simulation quality',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 96, label: Text('Low')),
              ButtonSegment(value: 128, label: Text('Med')),
              ButtonSegment(value: 192, label: Text('High')),
              ButtonSegment(value: 256, label: Text('Ultra')),
            ],
            selected: {_gridSide},
            onSelectionChanged: (s) => _setGridSide(s.first),
          ),
          const SizedBox(height: 6),
          _settingSlider('Wind', _wind, 0, 200, (v) {
            _wind = v;
            final s = _solver;
            if (s != null) {
              s.windSpeed = v;
              s.rebuildSolids(_obstacles);
            }
          }),
          _settingSlider('Swirl', _vorticity, 0, 4, (v) {
            _vorticity = v;
            _solver?.vorticity = v;
          }),
          _settingSlider('Ink lifetime', _dyeFade, 0.985, 1, (v) {
            _dyeFade = v;
            _solver?.dyeDissipation = v;
          }),
          _settingSlider('Brush size', _splatRadius, 2, 10, (v) {
            _splatRadius = v;
          }),
        ],
      ),
    );
  }

  Widget _settingSlider(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: (v) => setState(() => onChanged(v)),
          ),
        ),
      ],
    );
  }

  Widget _buildIntro() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showIntro = false),
        child: Container(
          color: Colors.black.withValues(alpha: 0.74),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Fluid Simulator',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 28),
              _introRow(Icons.gesture, 'Drag anywhere to stir in colorful ink'),
              _introRow(Icons.circle_outlined,
                  'Pick a shape, then tap the canvas to drop obstacles'),
              _introRow(
                  Icons.open_with, 'Drag obstacles around to push the fluid'),
              _introRow(Icons.grain,
                  'Cycle render modes: ink, particles, heat map'),
              _introRow(Icons.tune, 'Tune quality, swirl and brush in settings'),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => setState(() => _showIntro = false),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text('Start playing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _introRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.cyanAccent, size: 20),
          const SizedBox(width: 12),
          Flexible(
            child: Text(text, style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _toolButton(Tool tool, IconData icon, String tooltip) {
    final selected = _tool == tool;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      isSelected: selected,
      color: selected ? Colors.cyanAccent : Colors.white70,
      onPressed: () => setState(() => _tool = tool),
    );
  }
}

class _FluidPainter extends CustomPainter {
  _FluidPainter({
    required this.mesh,
    required this.obstacles,
    required this.mode,
    required this.bucketBuf,
    required this.bucketLen,
    required this.cellPad,
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// One color stop per particle speed bucket, from the jet colormap.
  static final List<Color> bucketColors =
      List.generate(6, (i) => Color(_jetArgb((i + 0.5) / 6)));

  final ValueNotifier<ui.Vertices?> mesh;
  final List<Obstacle> obstacles;
  final RenderMode mode;
  final List<Float32List> bucketBuf;
  final Int32List bucketLen;

  /// Outward padding (px) so the smooth vector shape covers the obstacle's
  /// blocky rasterized footprint on the sim grid.
  final double cellPad;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    if (mode == RenderMode.particles) {
      final p = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3;
      for (int b = 0; b < bucketColors.length; b++) {
        final len = bucketLen[b];
        if (len == 0) continue;
        p.color = bucketColors[b];
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.view(bucketBuf[b].buffer, 0, len),
          p,
        );
      }
    } else {
      final vertices = mesh.value;
      if (vertices != null) {
        // BlendMode.dst keeps the per-vertex colors as-is.
        canvas.drawVertices(vertices, BlendMode.dst, Paint());
      }
    }
    final fill = Paint()..color = const Color(0xFF2B3440);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white38;
    for (final o in obstacles) {
      final c = Offset(o.x * size.width, o.y * size.height);
      // Inflate so the vector shape hides the rasterized cells; an offset
      // of d grows an equilateral triangle's circumradius by 2d.
      final r = o.size * size.height +
          (o.shape == ObstacleShape.triangle ? cellPad * 2 : cellPad);
      final path = _shapePath(o.shape, c, r);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, outline);
    }
  }

  static Path _shapePath(ObstacleShape shape, Offset c, double r) {
    switch (shape) {
      case ObstacleShape.circle:
        return Path()..addOval(Rect.fromCircle(center: c, radius: r));
      case ObstacleShape.box:
        return Path()
          ..addRect(Rect.fromCenter(center: c, width: r * 2, height: r * 2));
      case ObstacleShape.triangle:
        const c30 = 0.8660254037844387;
        return Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx - r * c30, c.dy + r * 0.5)
          ..lineTo(c.dx + r * c30, c.dy + r * 0.5)
          ..close();
      case ObstacleShape.cow:
        // Scale the unit-normalized cow path by r and translate to center c —
        // same path the solver hit-tests against, so mask and art align.
        return SvgShapes.cow.path.transform(Float64List.fromList([
          r, 0, 0, 0, //
          0, r, 0, 0, //
          0, 0, 1, 0, //
          c.dx, c.dy, 0, 1,
        ]));
    }
  }

  @override
  bool shouldRepaint(_FluidPainter oldDelegate) => true;
}
