import 'dart:convert';
import 'dart:io';

import 'plataforma.dart';

/// Offset del micrófono sin calibrar: el CDD de Android pide que 90 dB SPL a 1 kHz
/// den un RMS de 2500 sobre 32768 (−22,35 dBFS), así que dB SPL ≈ dBFS + 112,35.
const offsetMicrofonoAndroid = 112.35;

/// En iPhone no hay una referencia oficial; 120 dB es un punto de partida (calibrar siempre).
const offsetMicrofonoIPhone = 120.0;

double get offsetSinCalibrar => Platform.isIOS ? offsetMicrofonoIPhone : offsetMicrofonoAndroid;

/// Guarda todo como archivos JSON en la memoria interna de la app.
class Almacen {
  static Future<Directory> _carpeta(String nombre) async {
    final base = await Plataforma.directorio();
    final carpeta = Directory('$base/$nombre');
    await carpeta.create(recursive: true);
    return carpeta;
  }

  static Future<List<Map<String, dynamic>>> _leerTodos(String carpeta) async {
    final dir = await _carpeta(carpeta);
    final lista = <Map<String, dynamic>>[];
    await for (final archivo in dir.list()) {
      if (archivo is File && archivo.path.endsWith('.json')) {
        try {
          lista.add(jsonDecode(await archivo.readAsString()) as Map<String, dynamic>);
        } on FormatException {
          // archivo dañado: se ignora
        }
      }
    }
    lista.sort((a, b) => (b['fecha'] as String).compareTo(a['fecha'] as String));
    return lista;
  }

  static Future<void> _guardar(String carpeta, Map<String, dynamic> datos) async {
    final dir = await _carpeta(carpeta);
    await File('${dir.path}/${datos['id']}.json').writeAsString(jsonEncode(datos));
  }

  static Future<void> _borrar(String carpeta, String id) async {
    final archivo = File('${(await _carpeta(carpeta)).path}/$id.json');
    if (await archivo.exists()) await archivo.delete();
  }

  static String nuevoId() {
    final a = DateTime.now();
    String d(int n) => n.toString().padLeft(2, '0');
    return '${a.year}${d(a.month)}${d(a.day)}-${d(a.hour)}${d(a.minute)}${d(a.second)}';
  }

  // Mediciones: metadatos en JSON y datos por segundo en .jsonl
  static Future<List<Map<String, dynamic>>> mediciones() => _leerTodos('mediciones');
  static Future<void> guardarMedicion(Map<String, dynamic> m) => _guardar('mediciones', m);

  static Future<Map<String, dynamic>?> medicion(String id) async {
    final archivo = File('${(await _carpeta('mediciones')).path}/$id.json');
    if (!await archivo.exists()) return null;
    return jsonDecode(await archivo.readAsString()) as Map<String, dynamic>;
  }

  static Future<void> borrarMedicion(Map<String, dynamic> m) async {
    await _borrar('mediciones', m['id'] as String);
    final datos = File(m['ruta_datos'] as String);
    if (await datos.exists()) await datos.delete();
  }

  static Future<String> rutaDatos(String id) async => '${(await _carpeta('datos')).path}/$id.jsonl';

  /// Archivos de todas las sesiones de audífonos (para la dosis semanal).
  static Future<List<String>> rutasAudifonos() async => [
    for (final m in await mediciones())
      if (m['modo'] == 'audifonos') m['ruta_datos'] as String,
  ];

  // Calibraciones (tipo: microfono o audifono)
  static Future<List<Map<String, dynamic>>> calibraciones(String tipo) async =>
      (await _leerTodos('calibraciones')).where((c) => c['tipo'] == tipo).toList();
  static Future<void> guardarCalibracion(Map<String, dynamic> c) => _guardar('calibraciones', c);
  static Future<void> borrarCalibracion(String id) => _borrar('calibraciones', id);

  static Future<File> _ajustes() async => File('${await Plataforma.directorio()}/ajustes.json');

  static Future<Map<String, dynamic>> ajustes() async {
    final archivo = await _ajustes();
    if (!await archivo.exists()) return {};
    return jsonDecode(await archivo.readAsString()) as Map<String, dynamic>;
  }

  static Future<void> fijarAjuste(String clave, Object? valor) async {
    final a = await ajustes();
    a[clave] = valor;
    await (await _ajustes()).writeAsString(jsonEncode(a));
  }

  /// Calibración activa del tipo dado; si no hay, un perfil "sin calibrar".
  static Future<Map<String, dynamic>> calibracionActiva(String tipo) async {
    final id = (await ajustes())['activa_$tipo'];
    for (final c in await calibraciones(tipo)) {
      if (c['id'] == id) return c;
    }
    // En iPhone el nivel de los audífonos lo calcula el sistema y se lee de Salud.
    if (tipo == 'audifono' && Platform.isIOS) {
      return {'id': 'salud', 'tipo': tipo, 'nombre': 'App Salud del iPhone', 'offset': 0.0, 'calibrado': true};
    }
    return tipo == 'microfono'
        ? {
            'id': 'defecto',
            'tipo': tipo,
            'nombre': Platform.isIOS ? 'Sin calibrar (aproximado)' : 'Sin calibrar (referencia Android)',
            'offset': offsetSinCalibrar,
            'calibrado': false,
          }
        : {
            'id': 'defecto',
            'tipo': tipo,
            'nombre': 'Sin calibrar (aproximado)',
            'offset': 100.0,
            'sigue_volumen': true,
            'calibrado': false,
          };
  }

  static Future<String> rutaInforme(String nombre) async => '${(await _carpeta('informes')).path}/$nombre';
}
