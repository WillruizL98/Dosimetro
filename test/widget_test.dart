import 'package:dosimetro/modos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formato con coma decimal', () {
    expect(num1(88.44, ' dBA'), '88,4 dBA');
    expect(num1(null), '—');
  });

  test('duración en hh:mm:ss', () {
    expect(duracion(3 * 3600 + 20 * 60 + 14), '03:20:14');
  });

  test('los cuatro modos', () {
    expect(Modo.todos.map((m) => m.id), ['jornada', 'audifonos', 'bandas', 'evento']);
    expect(Modo.audifonos.usaMicrofono, isFalse);
  });
}
