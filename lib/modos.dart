import 'package:flutter/material.dart';

/// Los cuatro modos de la app.
class Modo {
  const Modo(this.id, this.titulo, this.descripcion, this.icono);
  final String id;
  final String titulo;
  final String descripcion;
  final IconData icono;

  bool get usaMicrofono => id != 'audifonos';

  static const jornada = Modo(
    'jornada',
    'Jornada laboral',
    'Dosis de 8 h con la norma colombiana, NIOSH, OSHA o ISO',
    Icons.engineering,
  );
  static const audifonos = Modo(
    'audifonos',
    'Escucha con audífonos',
    'Dosis semanal de la OMS para la música que escuchas',
    Icons.headphones,
  );
  static const bandas = Modo(
    'bandas',
    'Bandas y protector',
    'Espectro por octavas y nivel con tapón u orejera',
    Icons.equalizer,
  );
  static const evento = Modo(
    'evento',
    'Evento en vivo',
    'Promedio de la última hora frente al límite del show',
    Icons.speaker,
  );

  static const todos = [jornada, audifonos, bandas, evento];

  static Modo porId(String id) => todos.firstWhere((m) => m.id == id, orElse: () => jornada);
}

/// Formato colombiano: coma decimal.
String num1(num? v, [String sufijo = '']) => v == null ? '—' : '${v.toStringAsFixed(1).replaceAll('.', ',')}$sufijo';

String duracion(int segundos) {
  final h = segundos ~/ 3600, m = (segundos % 3600) ~/ 60, s = segundos % 60;
  String d(int n) => n.toString().padLeft(2, '0');
  return '${d(h)}:${d(m)}:${d(s)}';
}

String fechaCorta(String? iso) {
  final f = DateTime.tryParse(iso ?? '');
  if (f == null) return '—';
  String d(int n) => n.toString().padLeft(2, '0');
  return '${d(f.day)}/${d(f.month)}/${f.year} ${d(f.hour)}:${d(f.minute)}';
}

/// Color de la dosis: verde < 50 %, ámbar < 100 %, rojo desde 100 %.
Color colorDosis(num? dosis) {
  if (dosis == null) return Colors.grey;
  if (dosis >= 100) return const Color(0xFFE5533D);
  if (dosis >= 50) return const Color(0xFFF2A33A);
  return const Color(0xFF3FAF6C);
}

void mostrarMensaje(BuildContext context, String texto) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
