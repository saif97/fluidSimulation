import 'dart:typed_data';
import 'dart:ui';

/// A silhouette defined by SVG path data, normalized once to a unit box
/// centered at the origin (longer axis spans -1..1, y-down to match canvas
/// space). The same [path] drives both obstacle hit-testing and rendering, so
/// the solid mask and the drawn art always align. [bounds] is cached for a
/// cheap bbox reject before the full point-in-path test.
class SvgShape {
  SvgShape(String svgPathData) : path = _normalize(_parseSvgPath(svgPathData)) {
    bounds = path.getBounds();
  }

  final Path path;
  late final Rect bounds;

  /// Recenters [p] on the origin and scales its longer axis to span -1..1.
  static Path _normalize(Path p) {
    final b = p.getBounds();
    final s = 2.0 / (b.width > b.height ? b.width : b.height);
    return p.transform(Float64List.fromList([
      s, 0, 0, 0, //
      0, s, 0, 0, //
      0, 0, 1, 0, //
      -b.center.dx * s, -b.center.dy * s, 0, 1,
    ]));
  }

  /// Minimal SVG path-data parser (M/L/H/V/C/S/Q/T/Z, absolute + relative).
  /// Enough for single-path silhouettes; arcs (A) are not supported.
  static Path _parseSvgPath(String d) {
    final path = Path();
    final tokens = RegExp(r'[MmLlHhVvCcSsQqTtZz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?')
        .allMatches(d)
        .map((m) => m.group(0)!)
        .toList();
    int i = 0;
    double cx = 0, cy = 0, sx = 0, sy = 0, lcx = 0, lcy = 0, lqx = 0, lqy = 0;
    String cmd = '';
    double n() => double.parse(tokens[i++]);
    while (i < tokens.length) {
      final t = tokens[i];
      if (t.length == 1 && RegExp(r'[A-Za-z]').hasMatch(t)) {
        cmd = t;
        i++;
      }
      final rel = cmd == cmd.toLowerCase();
      switch (cmd.toUpperCase()) {
        case 'M':
          double x = n(), y = n();
          if (rel) {
            x += cx;
            y += cy;
          }
          path.moveTo(x, y);
          cx = sx = x;
          cy = sy = y;
          cmd = rel ? 'l' : 'L';
        case 'L':
          double x = n(), y = n();
          if (rel) {
            x += cx;
            y += cy;
          }
          path.lineTo(x, y);
          cx = x;
          cy = y;
        case 'H':
          double x = n();
          if (rel) x += cx;
          path.lineTo(x, cy);
          cx = x;
        case 'V':
          double y = n();
          if (rel) y += cy;
          path.lineTo(cx, y);
          cy = y;
        case 'C':
          double x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n();
          if (rel) {
            x1 += cx;
            y1 += cy;
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          path.cubicTo(x1, y1, x2, y2, x, y);
          lcx = x2;
          lcy = y2;
          cx = x;
          cy = y;
        case 'S':
          double x2 = n(), y2 = n(), x = n(), y = n();
          if (rel) {
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          path.cubicTo(2 * cx - lcx, 2 * cy - lcy, x2, y2, x, y);
          lcx = x2;
          lcy = y2;
          cx = x;
          cy = y;
        case 'Q':
          double x1 = n(), y1 = n(), x = n(), y = n();
          if (rel) {
            x1 += cx;
            y1 += cy;
            x += cx;
            y += cy;
          }
          path.quadraticBezierTo(x1, y1, x, y);
          lqx = x1;
          lqy = y1;
          cx = x;
          cy = y;
        case 'T':
          double x = n(), y = n();
          if (rel) {
            x += cx;
            y += cy;
          }
          final x1 = 2 * cx - lqx, y1 = 2 * cy - lqy;
          path.quadraticBezierTo(x1, y1, x, y);
          lqx = x1;
          lqy = y1;
          cx = x;
          cy = y;
        case 'Z':
          path.close();
          cx = sx;
          cy = sy;
        default:
          i++; // skip anything unsupported
      }
    }
    return path;
  }
}

/// Library of named silhouette shapes. Add a new obstacle silhouette by
/// dropping its SVG path data here as another `SvgShape` — it is parsed and
/// normalized lazily on first use, then shared by the solver and the painter.
class SvgShapes {
  SvgShapes._();

  /// Cow silhouette (svgrepo.com/show/481362, CC0), used verbatim. Faces -x so
  /// it meets a left-to-right wind head-on.
  static final SvgShape cow = SvgShape(_cow);

  static const String _cow =
      'M508.814,298.717c0,0-3.011-45.186-3.011-66.266c0-18.84-7.226-38.239-18.435-44.31'
      'c-14.85-32.44-67.54-30.799-89.424-30.799c-25.605,0-82.032-1.538-106.88-1.538'
      's-79.107-7.13-107.716-15.407c-28.616-8.286-47.066-23.717-50.826-19.207'
      'c-3.761,4.524-11.297,9.798-21.836,8.285c21.836-8.285,20.33-31.619,17.32-34.63'
      'c-3.012-3.012-15.065-3.768-26.354,9.783c6.772-12.802-6.031-30.113-12.802-33.881'
      'c-6.78-3.768-13.552-2.263-8.286,1.505c5.274,3.769,8.286,20.331,0.757,27.111'
      'c0,0-23.342,14.3-27.858,17.319c-4.517,3.012-33.134,39.904-38.407,42.916'
      'C9.79,162.608,0,167.874,0,170.894c0,3.012,11.296,25.971,17.319,25.971'
      'c6.023,0,53.081,5.648,82.446,7.911c0,0,18.833,30.52,28.242,57.598'
      'c5.09,14.667,10.539,45.457,17.319,57.582c14.3,25.596,33.133,47.432,33.133,60.984'
      'c0,13.559,0,43.672,0,43.672l-8.285,14.308c0,0,6.023,3.768,17.319,3.768'
      'c11.297,0,12.795-8.285,12.795-12.053c0-3.761,0-56.467,0-56.467'
      's-3.011-14.308-3.011-23.35c0-9.034,12.053-57.224,12.802-63.995'
      'c0,0,1.506,16.562,1.506,21.08c0,0,35.1,12.165,53.089,13.957'
      'c30.114,3.011,51.201,9.042,94.874,4.517c35.323-3.649,63.294-24.497,63.294-24.497'
      's-3.02-14.308,0.749-21.836c6.022,42.167,40.661,71.532,40.661,73.786'
      'c0,2.263-5.313,70.058-5.313,70.058l-6.78,15.814c0,0,2.302,3.736,13.599,3.736'
      's15.057-6.779,15.057-15.057c0-8.285,15.057-79.068,15.814-84.334'
      'c0.757-5.274-4.517-42.924-6.023-46.684c-1.179-2.956-0.048-51.895,0.502-76.407'
      'c6.509,21.884,7.282,57.756,5.665,68.719c-3.386,22.959,6.022,45.178,6.022,45.178'
      's3.012,7.528,7.529-9.034C514.837,309.257,508.814,298.717,508.814,298.717z';
}
