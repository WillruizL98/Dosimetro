import 'dart:convert';

import 'package:flutter/material.dart';

import 'modos.dart';
import 'pantallas/calibracion.dart';
import 'pantallas/historial.dart';
import 'pantallas/medicion.dart';
import 'pantallas/nueva_medicion.dart';
import 'servicios/almacen.dart';
import 'servicios/plataforma.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppDosimetro());
}

class AppDosimetro extends StatelessWidget {
  const AppDosimetro({super.key});

  @override
  Widget build(BuildContext context) {
    const semilla = Color(0xFFB25E00); // ámbar de señal de riesgo auditivo
    return MaterialApp(
      title: 'Dosímetro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: semilla, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: semilla, brightness: Brightness.dark, useMaterial3: true),
      home: const PantallaInicio(),
    );
  }
}

class PantallaInicio extends StatefulWidget {
  const PantallaInicio({super.key});

  @override
  State<PantallaInicio> createState() => _EstadoInicio();
}

class _EstadoInicio extends State<PantallaInicio> {
  Map<String, dynamic>? _mic;
  Map<String, dynamic>? _enCurso;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final mic = await Almacen.calibracionActiva('microfono');
      final estado = await Plataforma.estadoMedicion();
      Map<String, dynamic>? enCurso;
      if (estado['activa'] == true && estado['config'] != null) {
        final cfg = jsonDecode(estado['config'] as String) as Map<String, dynamic>;
        enCurso = await Almacen.medicion(cfg['sesion_id'] as String);
      }
      // Python arranca aquí la primera vez (tarda un par de segundos)
      await Plataforma.python('normas', 'listar');
      setState(() {
        _mic = mic;
        _enCurso = enCurso;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _ir(Widget pantalla) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => pantalla));
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final calibrado = _mic?['calibrado'] != false && _mic != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Dosímetro de ruido')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_enCurso != null)
            Card(
              color: tema.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: Colors.red),
                title: const Text('Medición en curso'),
                subtitle: Text('${Modo.porId(_enCurso!['modo'] as String).titulo} · ${_enCurso!['lugar'] ?? ''}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _ir(PantallaMedicion(sesion: _enCurso!, reanudar: true)),
              ),
            ),
          Card(
            child: ListTile(
              leading: Icon(
                calibrado ? Icons.verified : Icons.warning_amber,
                color: calibrado ? Colors.green : Colors.orange,
              ),
              title: Text(
                _mic == null
                    ? (_error == null ? 'Iniciando Python…' : 'Error al iniciar')
                    : 'Micrófono: ${_mic!['nombre']}',
              ),
              subtitle: Text(
                _error ??
                    (calibrado
                        ? 'Offset ${num1(_mic!['offset'] as num, ' dB')}'
                        : 'Calibra con un sonómetro para medir en dB reales'),
              ),
              onTap: () => _ir(const PantallaCalibracion()),
            ),
          ),
          const SizedBox(height: 8),
          Text('MODOS DE MEDICIÓN', style: tema.textTheme.labelMedium!.copyWith(letterSpacing: 1.2)),
          const SizedBox(height: 4),
          for (final modo in Modo.todos)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: Icon(modo.icono, size: 34, color: tema.colorScheme.primary),
                title: Text(modo.titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(modo.descripcion),
                trailing: const Icon(Icons.chevron_right),
                onTap: _enCurso == null
                    ? () => _ir(PantallaNuevaMedicion(modo: modo))
                    : () => mostrarMensaje(context, 'Termina primero la medición en curso'),
              ),
            ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Historial e informes'),
              subtitle: const Text('Resultados guardados, PDF y CSV'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _ir(const PantallaHistorial()),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Calibración'),
              subtitle: const Text('Micrófono con sonómetro y audífonos'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _ir(const PantallaCalibracion()),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Proyecto académico. Todo se procesa en este teléfono (Flutter + Python); no se envían datos a '
            'ningún servidor. No reemplaza un dosímetro certificado (IEC 61252).',
            style: tema.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
