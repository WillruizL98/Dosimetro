import 'dart:convert';

import 'package:flutter/services.dart';

class ErrorPython implements Exception {
  ErrorPython(this.mensaje);
  final String mensaje;
  @override
  String toString() => 'Error en Python: $mensaje';
}

/// Acceso a lo que vive en Kotlin: micrófono, servicio de medición, Python y archivos.
class Plataforma {
  static const _medicion = MethodChannel('dosimetro/medicion');
  static const _calibracion = MethodChannel('dosimetro/calibracion');
  static const _python = MethodChannel('dosimetro/python');
  static const _sistema = MethodChannel('dosimetro/sistema');
  static const _niveles = EventChannel('dosimetro/niveles');

  /// Niveles en vivo (~8 por segundo) y un registro por segundo mientras se mide.
  static Stream<Map<dynamic, dynamic>> niveles() =>
      _niveles.receiveBroadcastStream().map((e) => e as Map<dynamic, dynamic>);

  static Future<bool> pedirPermisos() async => (await _sistema.invokeMethod<bool>('permisos')) ?? false;

  static Future<void> iniciarMedicion(Map<String, dynamic> cfg) =>
      _medicion.invokeMethod('iniciar', {'cfg': jsonEncode(cfg)});

  static Future<void> detenerMedicion() => _medicion.invokeMethod('detener');

  static Future<void> pausar(bool pausa) => _medicion.invokeMethod('pausar', {'pausa': pausa});

  static Future<void> marcar(String texto) => _medicion.invokeMethod('marcar', {'texto': texto});

  /// Medición en curso (sigue viva aunque se cierre la pantalla).
  static Future<Map<dynamic, dynamic>> estadoMedicion() async =>
      (await _medicion.invokeMethod<Map<dynamic, dynamic>>('estado'))!;

  /// Tipo de audífono por el que sale el sonido ahora (cable, usb, bluetooth) o null.
  static Future<String?> audifono() => _medicion.invokeMethod<String>('audifono');

  static Future<Map<dynamic, dynamic>> volumen() async =>
      (await _medicion.invokeMethod<Map<dynamic, dynamic>>('volumen'))!;

  // Calibración
  static Future<Map<dynamic, dynamic>> medirMicrofono(int segundos) async =>
      (await _calibracion.invokeMethod<Map<dynamic, dynamic>>('medirMicrofono', {'segundos': segundos}))!;
  static Future<void> tonoCalibracion() => _calibracion.invokeMethod('tono');
  static Future<void> detenerTono() => _calibracion.invokeMethod('detenerTono');
  static Future<Map<dynamic, dynamic>> medirAudifono() async =>
      (await _calibracion.invokeMethod<Map<dynamic, dynamic>>('medirAudifono'))!;

  /// Llama a `modulo.funcion(datos)` en Python. Los datos viajan como JSON.
  static Future<dynamic> python(String modulo, String funcion, [Object? datos]) async {
    final respuesta = await _python.invokeMethod<String>('llamar', {
      'modulo': modulo,
      'funcion': funcion,
      'datos': jsonEncode(datos),
    });
    final mapa = jsonDecode(respuesta!) as Map<String, dynamic>;
    if (mapa['ok'] != true) throw ErrorPython(mapa['error'] as String);
    return mapa['resultado'];
  }

  static Future<String> directorio() async => (await _sistema.invokeMethod<String>('directorio'))!;

  static Future<void> compartir(String ruta, String tipo) =>
      _sistema.invokeMethod('compartir', {'ruta': ruta, 'tipo': tipo});

  static Future<void> abrir(String ruta, String tipo) => _sistema.invokeMethod('abrir', {'ruta': ruta, 'tipo': tipo});
}
