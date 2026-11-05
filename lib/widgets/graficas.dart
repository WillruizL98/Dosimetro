import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../modos.dart';

/// Anillo de dosis: se llena hasta 100 % y cambia de color según el riesgo.
class AnilloDosis extends StatelessWidget {
  const AnilloDosis({super.key, required this.dosis, this.etiqueta = 'dosis', this.tamano = 170});
  final num? dosis;
  final String etiqueta;
  final double tamano;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return SizedBox(
      width: tamano,
      height: tamano,
      child: CustomPaint(
        painter: _PintorAnillo((dosis ?? 0).toDouble(), colorDosis(dosis), tema.colorScheme.surfaceContainerHighest),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                dosis == null ? '—' : '${dosis!.round()} %',
                style: tema.textTheme.displaySmall!.copyWith(fontWeight: FontWeight.w600, color: colorDosis(dosis)),
              ),
              Text(etiqueta.toUpperCase(), style: tema.textTheme.labelSmall!.copyWith(letterSpacing: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PintorAnillo extends CustomPainter {
  _PintorAnillo(this.dosis, this.color, this.fondo);
  final double dosis;
  final Color color;
  final Color fondo;

  @override
  void paint(Canvas canvas, Size size) {
    const grosor = 14.0;
    final rect = Rect.fromLTWH(grosor / 2, grosor / 2, size.width - grosor, size.height - grosor);
    final pincel = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = grosor
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, 2 * math.pi, false, pincel..color = fondo);
    final angulo = 2 * math.pi * (dosis.clamp(0, 100) / 100);
    canvas.drawArc(rect, -math.pi / 2, angulo, false, pincel..color = color);
  }

  @override
  bool shouldRepaint(_PintorAnillo o) => o.dosis != dosis || o.color != color;
}

/// Serie en el tiempo (un valor por minuto o por segundo) con línea de límite.
class GraficaLinea extends StatelessWidget {
  const GraficaLinea({super.key, required this.valores, this.limite, this.alto = 160, this.unidad = 'dBA'});
  final List<num?> valores;
  final num? limite;
  final double alto;
  final String unidad;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return SizedBox(
      height: alto,
      width: double.infinity,
      child: CustomPaint(
        painter: _PintorLinea(
          valores,
          limite,
          esquema.primary,
          esquema.outlineVariant,
          esquema.onSurfaceVariant,
          esquema.error,
          unidad,
        ),
      ),
    );
  }
}

class _PintorLinea extends CustomPainter {
  _PintorLinea(this.valores, this.limite, this.color, this.guia, this.texto, this.colorLimite, this.unidad);
  final List<num?> valores;
  final num? limite;
  final Color color, guia, texto, colorLimite;
  final String unidad;

  @override
  void paint(Canvas canvas, Size size) {
    final puntos = valores.whereType<num>().toList();
    if (puntos.isEmpty) return;
    final todos = [...puntos, ?limite];
    var vmin = (todos.reduce(math.min) / 10).floor() * 10.0;
    var vmax = (todos.reduce(math.max) / 10).ceil() * 10.0;
    if (vmax - vmin < 20) vmax = vmin + 20;
    const izq = 30.0, abajo = 4.0;
    final ancho = size.width - izq, alto = size.height - abajo;
    double y(num v) => alto - alto * (v - vmin) / (vmax - vmin);
    double x(int i) => izq + ancho * i / math.max(1, valores.length - 1);

    final linea = Paint()
      ..color = guia
      ..strokeWidth = 0.6;
    for (var v = vmin; v <= vmax; v += 10) {
      canvas.drawLine(Offset(izq, y(v)), Offset(size.width, y(v)), linea);
      _texto(canvas, v.toStringAsFixed(0), Offset(0, y(v) - 7));
    }
    _texto(canvas, unidad, const Offset(izq + 4, 0));
    if (limite != null) {
      final p = Paint()
        ..color = colorLimite
        ..strokeWidth = 1.2;
      for (var xx = izq; xx < size.width; xx += 8) {
        canvas.drawLine(Offset(xx, y(limite!)), Offset(math.min(xx + 4, size.width), y(limite!)), p);
      }
    }
    final camino = Path();
    var primero = true;
    for (var i = 0; i < valores.length; i++) {
      final v = valores[i];
      if (v == null) continue;
      if (primero) {
        camino.moveTo(x(i), y(v));
        primero = false;
      } else {
        camino.lineTo(x(i), y(v));
      }
    }
    if (puntos.length == 1) {
      // un solo minuto: se dibuja como punto
      final i = valores.indexWhere((v) => v != null);
      canvas.drawCircle(
        Offset(valores.length == 1 ? izq + ancho / 2 : x(i), y(valores[i]!)),
        4,
        Paint()..color = color,
      );
    }
    canvas.drawPath(
      camino,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  void _texto(Canvas canvas, String s, Offset o) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: texto, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_PintorLinea o) => true;
}

/// Barras con etiqueta abajo y valor arriba (bandas de octava, dosis por día).
class GraficaBarras extends StatelessWidget {
  const GraficaBarras({
    super.key,
    required this.etiquetas,
    required this.valores,
    this.alto = 160,
    this.desde,
    this.colores,
  });
  final List<String> etiquetas;
  final List<num?> valores;
  final double alto;
  final num? desde;
  final List<Color>? colores;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final vals = valores.map((v) => (v ?? 0).toDouble()).toList();
    final tope = vals.isEmpty ? 1.0 : math.max(1.0, vals.reduce(math.max));
    final base = (desde ?? 0).toDouble();
    return SizedBox(
      height: alto,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < vals.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(vals[i] == 0 ? '' : vals[i].toStringAsFixed(0), style: tema.textTheme.labelSmall),
                    const SizedBox(height: 2),
                    Container(
                      height: math.max(
                        1,
                        (alto - 40) * ((vals[i] - base).clamp(0, tope - base) / math.max(1, tope - base)),
                      ),
                      color: colores?[i] ?? tema.colorScheme.primary,
                    ),
                    const SizedBox(height: 4),
                    Text(etiquetas[i], style: tema.textTheme.labelSmall, maxLines: 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Celda de valor con etiqueta pequeña (como en un instrumento).
class Valor extends StatelessWidget {
  const Valor(this.etiqueta, this.valor, {super.key, this.unidad = '', this.color});
  final String etiqueta;
  final String valor;
  final String unidad;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(border: Border.all(color: tema.colorScheme.outlineVariant)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(etiqueta.toUpperCase(), style: tema.textTheme.labelSmall!.copyWith(letterSpacing: 1)),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: valor,
                  style: tema.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600, color: color),
                ),
                TextSpan(text: unidad.isEmpty ? '' : ' $unidad', style: tema.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dos celdas por fila.
class RejillaValores extends StatelessWidget {
  const RejillaValores(this.celdas, {super.key});
  final List<Widget> celdas;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < celdas.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(child: celdas[i]),
                const SizedBox(width: 8),
                Expanded(child: i + 1 < celdas.length ? celdas[i + 1] : const SizedBox()),
              ],
            ),
          ),
      ],
    );
  }
}
