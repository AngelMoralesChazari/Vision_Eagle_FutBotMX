// ============================================================================
//  field_screen.dart — Cancha 2D (vista táctica)
//  Reproduce el movimiento de robots y pelota sobre un modelo a escala.
//  Medidas oficiales RoboCupJunior Soccer 2026.
// ============================================================================
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'models.dart';

// ============================================================================
//  CANCHA 2D (vista táctica) — Hito 1: el entorno
//  Medidas oficiales RoboCupJunior Soccer 2026 (en cm).
// ============================================================================
class Field {
  static const double playL = 219;   // largo (entre porterías)
  static const double playW = 158;   // ancho
  static const double out = 12;      // área exterior (out)
  static const double totalL = playL + 2 * out;   // 243
  static const double totalW = playW + 2 * out;   // 182
  static const double goalMouth = 60;
  static const double goalDepth = 7.4;
  static const double penDepth = 25;
  static const double penWidth = 80;
  static const double penRadius = 15;
  static const double circleR = 30;  // círculo central Ø60
  static const double neutralFromShort = 45;
}

class FieldScreen extends StatefulWidget {
  final List<LayerView> layers;
  final double imgW, imgH;
  final int frameCount;
  const FieldScreen({
    super.key,
    required this.layers,
    required this.imgW,
    required this.imgH,
    required this.frameCount,
  });
  @override
  State<FieldScreen> createState() => _FieldScreenState();
}

class _FieldScreenState extends State<FieldScreen> {
  int _idx = 0;
  bool _playing = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _togglePlay() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 120), (t) {
      setState(() {
        _idx++;
        if (_idx >= widget.frameCount) _idx = 0;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.frameCount;
    return Scaffold(
      appBar: AppBar(title: const Text('Cancha 2D · vista táctica')),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: FieldPainter(
                        layers: widget.layers,
                        imgW: widget.imgW,
                        imgH: widget.imgH,
                        currentFrame: _idx,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 300, child: _buildPanel()),
              ],
            ),
          ),
          Row(children: [
            IconButton(
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              onPressed: n > 1 ? _togglePlay : null,
            ),
            Expanded(
              child: Slider(
                value: _idx.clamp(0, (n - 1).clamp(0, 1 << 30)).toDouble(),
                min: 0,
                max: (n - 1).clamp(1, 1 << 30).toDouble(),
                onChanged: n > 1
                    ? (v) {
                        _timer?.cancel();
                        setState(() {
                          _playing = false;
                          _idx = v.round();
                        });
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('${(_idx + 1).clamp(1, n)}/$n'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Marcadores',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'Posiciones provisionales (mapeo simple). La posición real llega con la calibración.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          for (final L in widget.layers) _layerCard(L),
        ],
      ),
    );
  }

  Widget _layerCard(LayerView L) {
    final isBall = L.isBall;
    final colorOptions = isBall
        ? const [Color(0xFFFF8A00), Color(0xFF111111)]    // naranja, negra
        : const [Color(0xFFE53935), Color(0xFF1E88E5)];   // rojo, azul
    final colorNames =
        isBall ? const ['Naranja', 'Negra'] : const ['Rojo', 'Azul'];
    final shapeOptions =
        isBall ? const ['circle', 'square'] : const ['square', 'triangle'];
    final shapeNames =
        isBall ? const ['Círculo', 'Cuadrado'] : const ['Cuadrado', 'Triángulo'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(isBall ? Icons.sports_soccer : Icons.smart_toy,
                  size: 18, color: L.color2d),
              const SizedBox(width: 6),
              Expanded(
                child: Text(L.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(isBall ? 'Color' : 'Equipo / color',
                style: const TextStyle(fontSize: 12)),
            Wrap(spacing: 6, children: [
              for (int i = 0; i < colorOptions.length; i++)
                ChoiceChip(
                  label: Text(colorNames[i]),
                  selected: L.color2d == colorOptions[i],
                  avatar: CircleAvatar(backgroundColor: colorOptions[i], radius: 7),
                  onSelected: (_) => setState(() => L.color2d = colorOptions[i]),
                ),
            ]),
            const SizedBox(height: 6),
            const Text('Forma', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 6, children: [
              for (int i = 0; i < shapeOptions.length; i++)
                ChoiceChip(
                  label: Text(shapeNames[i]),
                  selected: L.shape2d == shapeOptions[i],
                  onSelected: (_) => setState(() => L.shape2d = shapeOptions[i]),
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Etiqueta'),
              value: L.show2dLabel,
              onChanged: (v) => setState(() => L.show2dLabel = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Rastro (flechas)'),
              value: L.show2dTrail,
              onChanged: (v) => setState(() => L.show2dTrail = v),
            ),
          ],
        ),
      ),
    );
  }
}

class FieldPainter extends CustomPainter {
  final List<LayerView> layers;
  final double imgW, imgH;
  final int currentFrame;
  FieldPainter({
    required this.layers,
    required this.imgW,
    required this.imgH,
    required this.currentFrame,
  });

  // imagen px -> cancha cm (provisional: normaliza sobre la cancha de juego)
  double _toFieldX(double ix) => Field.out + (ix / imgW) * Field.playL;
  double _toFieldY(double iy) => Field.out + (iy / imgH) * Field.playW;

  Offset? _posAt(LayerView L, int f) {
    Offset? last;
    for (final t in L.trail) {
      if (t.$1 <= f) last = t.$2;
    }
    return last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale =
        min(size.width / Field.totalL, size.height / Field.totalW);
    final ox = (size.width - Field.totalL * scale) / 2;
    final oy = (size.height - Field.totalW * scale) / 2;
    Offset p(double cx, double cy) => Offset(ox + cx * scale, oy + cy * scale);

    const green = Color(0xFF2E7D32);
    const greenOut = Color(0xFF15401E);
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // out area
    canvas.drawRect(Rect.fromPoints(p(0, 0), p(Field.totalL, Field.totalW)),
        Paint()..color = greenOut);
    // porterías
    final gy0 = Field.totalW / 2 - Field.goalMouth / 2;
    final gy1 = Field.totalW / 2 + Field.goalMouth / 2;
    canvas.drawRect(
        Rect.fromPoints(p(Field.out - Field.goalDepth, gy0), p(Field.out, gy1)),
        Paint()..color = const Color(0xFF1976D2)); // azul
    canvas.drawRect(
        Rect.fromPoints(p(Field.out + Field.playL, gy0),
            p(Field.out + Field.playL + Field.goalDepth, gy1)),
        Paint()..color = const Color(0xFFFBC02D)); // amarilla
    // cancha de juego
    canvas.drawRect(
        Rect.fromPoints(p(Field.out, Field.out),
            p(Field.out + Field.playL, Field.out + Field.playW)),
        Paint()..color = green);
    canvas.drawRect(
        Rect.fromPoints(p(Field.out, Field.out),
            p(Field.out + Field.playL, Field.out + Field.playW)),
        white);
    // áreas de penalti
    _penalty(canvas, p, scale, true, white);
    _penalty(canvas, p, scale, false, white);
    // círculo central
    canvas.drawCircle(
        p(Field.totalL / 2, Field.totalW / 2), Field.circleR * scale, white);
    // puntos neutrales
    final spot = Paint()..color = Colors.black87;
    final ny0 = Field.totalW / 2 - Field.penWidth / 2;
    final ny1 = Field.totalW / 2 + Field.penWidth / 2;
    for (final s in [
      p(Field.totalL / 2, Field.totalW / 2),
      p(Field.out + Field.neutralFromShort, ny0),
      p(Field.out + Field.neutralFromShort, ny1),
      p(Field.out + Field.playL - Field.neutralFromShort, ny0),
      p(Field.out + Field.playL - Field.neutralFromShort, ny1),
    ]) {
      canvas.drawCircle(s, 3, spot);
    }

    // marcadores (mapeo provisional)
    for (final L in layers) {
      if (L.show2dTrail) _arrows(canvas, L, p);
      final imgPos = _posAt(L, currentFrame);
      if (imgPos == null) continue;
      final fp = p(_toFieldX(imgPos.dx), _toFieldY(imgPos.dy));
      _marker(canvas, L, fp);
      if (L.show2dLabel) _label(canvas, L.name, fp, L.color2d);
    }
  }

  void _penalty(Canvas canvas, Offset Function(double, double) p, double scale,
      bool left, Paint white) {
    final y0 = Field.totalW / 2 - Field.penWidth / 2;
    final y1 = Field.totalW / 2 + Field.penWidth / 2;
    final r = Field.penRadius;
    final path = Path();
    if (left) {
      final xLine = Field.out;
      final xFront = Field.out + Field.penDepth;
      final a = p(xLine, y0), b = p(xFront - r, y0), c = p(xFront, y0 + r);
      final d = p(xFront, y1 - r), e = p(xFront - r, y1), f = p(xLine, y1);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
      path.arcToPoint(c, radius: Radius.circular(r * scale), clockwise: true);
      path.lineTo(d.dx, d.dy);
      path.arcToPoint(e, radius: Radius.circular(r * scale), clockwise: true);
      path.lineTo(f.dx, f.dy);
    } else {
      final xLine = Field.out + Field.playL;
      final xFront = xLine - Field.penDepth;
      final a = p(xLine, y0), b = p(xFront + r, y0), c = p(xFront, y0 + r);
      final d = p(xFront, y1 - r), e = p(xFront + r, y1), f = p(xLine, y1);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
      path.arcToPoint(c, radius: Radius.circular(r * scale), clockwise: false);
      path.lineTo(d.dx, d.dy);
      path.arcToPoint(e, radius: Radius.circular(r * scale), clockwise: false);
      path.lineTo(f.dx, f.dy);
    }
    canvas.drawPath(path, white);
  }

  void _marker(Canvas canvas, LayerView L, Offset at) {
    final fill = Paint()
      ..color = L.color2d
      ..style = PaintingStyle.fill;
    final edge = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const s = 9.0;
    if (L.shape2d == 'circle') {
      canvas.drawCircle(at, s, fill);
      canvas.drawCircle(at, s, edge);
    } else if (L.shape2d == 'triangle') {
      final path = Path()
        ..moveTo(at.dx, at.dy - s)
        ..lineTo(at.dx + s, at.dy + s)
        ..lineTo(at.dx - s, at.dy + s)
        ..close();
      canvas.drawPath(path, fill);
      canvas.drawPath(path, edge);
    } else {
      final r = Rect.fromCenter(center: at, width: s * 2, height: s * 2);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, edge);
    }
  }

  void _arrows(Canvas canvas, LayerView L, Offset Function(double, double) p) {
    final pts = <Offset>[];
    for (final t in L.trail) {
      if (t.$1 <= currentFrame) {
        pts.add(p(_toFieldX(t.$2.dx), _toFieldY(t.$2.dy)));
      }
    }
    if (pts.length < 2) return;
    final drawn = <Offset>[];
    for (final q in pts) {
      if (drawn.isEmpty || (q - drawn.last).distance >= 26) drawn.add(q);
    }
    if (drawn.last != pts.last) drawn.add(pts.last);
    for (int i = 0; i < drawn.length - 1; i++) {
      final dir = drawn[i + 1] - drawn[i];
      if (dir.distance < 0.01) continue;
      final angle = atan2(dir.dy, dir.dx) + pi / 2;
      _arrowHead(canvas, drawn[i], angle, L.color2d, 7);
    }
  }

  void _arrowHead(Canvas canvas, Offset at, double angle, Color color, double r) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    final path = Path()
      ..moveTo(0, -r)
      ..lineTo(r * 0.7, r * 0.7)
      ..lineTo(-r * 0.7, r * 0.7)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = 4.0;
    final rect = Rect.fromLTWH(at.dx + 11, at.dy - tp.height / 2 - pad,
        tp.width + pad * 2, tp.height + pad);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = color.withOpacity(0.85));
    tp.paint(canvas, Offset(rect.left + pad, rect.top + pad / 2));
  }

  @override
  bool shouldRepaint(covariant FieldPainter old) => true;
}