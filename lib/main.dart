import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'fluid_solver.dart';

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

enum Tool { stir, circle, box, triangle, eraser }

class SimulationPage extends StatefulWidget {
  const SimulationPage({super.key});

  @override
  State<SimulationPage> createState() => _SimulationPageState();
}

class _SimulationPageState extends State<SimulationPage>
    with SingleTickerProviderStateMixin {
  /// Long-side cell count. Kept modest so dart2js hits 60 fps.
  static const int _maxGridSide = 128;
  static const double _splatRadiusCells = 4.5;
  static const double _maxInjectSpeed = 400; // cells/sec

  late final Ticker _ticker;
  FluidSolver? _solver;
  Size _canvasSize = Size.zero;

  // Dye is rendered as a triangle mesh with per-vertex colors
  // (Canvas.drawVertices) — no image codecs involved.
  Float32List _positions = Float32List(0);
  Uint16List _meshIndices = Uint16List(0);
  Int32List _colors = Int32List(0);
  final ValueNotifier<ui.Vertices?> _mesh = ValueNotifier(null);

  final List<Obstacle> _obstacles = [];
  Obstacle? _dragged;
  Tool _tool = Tool.stir;

  Duration _lastTick = Duration.zero;
  double _hue = 200;
  double _fpsEma = 60;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _mesh.value?.dispose();
    _mesh.dispose();
    super.dispose();
  }

  void _ensureSolver(Size size) {
    if (_solver != null && size == _canvasSize) return;
    _canvasSize = size;
    final aspect = size.width / size.height;
    int gw, gh;
    if (aspect >= 1) {
      gw = _maxGridSide;
      gh = (_maxGridSide / aspect).round().clamp(48, _maxGridSide);
    } else {
      gh = _maxGridSide;
      gw = (_maxGridSide * aspect).round().clamp(48, _maxGridSide);
    }
    _solver = FluidSolver(w: gw, h: gh, aspect: aspect)
      ..rebuildSolids(_obstacles);
    _buildMesh(_solver!, size);
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
    double dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 1 / 20) dt = 1 / 60;
    _fpsEma = _fpsEma * 0.95 + (1 / dt) * 0.05;
    _hue = (_hue + dt * 40) % 360;

    solver.step(dt);
    _updateMesh(solver);
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
        final hit = _hitObstacle(n);
        if (hit != null) {
          _dragged = hit;
        } else {
          final shape = switch (_tool) {
            Tool.circle => ObstacleShape.circle,
            Tool.box => ObstacleShape.box,
            _ => ObstacleShape.triangle,
          };
          _dragged = Obstacle(shape: shape, x: n.dx, y: n.dy);
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
      radius: _splatRadiusCells,
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
            child: SafeArea(child: _buildToolbar()),
          ),
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
          _toolButton(Tool.eraser, Icons.auto_fix_high, 'Erase object'),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.white24,
          ),
          IconButton(
            tooltip: 'Clear everything',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearAll,
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
  _FluidPainter({required this.mesh, required this.obstacles})
      : super(repaint: mesh);

  final ValueNotifier<ui.Vertices?> mesh;
  final List<Obstacle> obstacles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final vertices = mesh.value;
    if (vertices != null) {
      // BlendMode.dst keeps the per-vertex colors as-is.
      canvas.drawVertices(vertices, BlendMode.dst, Paint());
    }
    final fill = Paint()..color = const Color(0xFF2B3440);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white38;
    for (final o in obstacles) {
      final c = Offset(o.x * size.width, o.y * size.height);
      final r = o.size * size.height;
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
    }
  }

  @override
  bool shouldRepaint(_FluidPainter oldDelegate) => true;
}
