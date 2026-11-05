import 'dart:io';

import 'package:flutter/material.dart';

import '../modos.dart';
import '../servicios/almacen.dart';
import '../servicios/plataforma.dart';
import 'medicion.dart';

/// Datos de la medición antes de empezar: lugar, persona, criterio y opciones del modo.
class PantallaNuevaMedicion extends StatefulWidget {
  const PantallaNuevaMedicion({super.key, required this.modo});
  final Modo modo;

  @override
  State<PantallaNuevaMedicion> createState() => _EstadoNueva();
}

class _EstadoNueva extends State<PantallaNuevaMedicion> {
  final _form = GlobalKey<FormState>();
  final _lugar = TextEditingController();
  final _persona = TextEditingController();
  final _actividad = TextEditingController();
  final _responsable = TextEditingController();
  final _limite = TextEditingController(text: '100');
  final _protector = {
    for (final k in ['nombre', 'snr', 'h', 'm', 'l', 'nrr']) k: TextEditingController(),
  };
  List<Map<String, dynamic>> _criterios = [];
  String _criterio = 'res1792';
  int _ventana = 60;
  String _perfil = 'adulto';
  Map<String, dynamic>? _calibracion;
  bool _iniciando = false;

  Modo get modo => widget.modo;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final lista = await Plataforma.python('normas', 'listar') as List;
    final ajustes = await Almacen.ajustes();
    final cal = await Almacen.calibracionActiva(modo.usaMicrofono ? 'microfono' : 'audifono');
    setState(() {
      _criterios = lista.cast<Map<String, dynamic>>();
      _criterio = (ajustes['criterio'] as String?) ?? (modo.id == 'evento' ? 'niosh' : 'res1792');
      _responsable.text = (ajustes['responsable'] as String?) ?? '';
      _calibracion = cal;
    });
  }

  Future<void> _iniciar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _iniciando = true);
    try {
      if (!await Plataforma.pedirPermisos()) {
        if (mounted) mostrarMensaje(context, 'Sin permiso de micrófono no se puede medir');
        return;
      }
      if (modo.id == 'audifonos' && await Plataforma.audifono() == null) {
        if (mounted) mostrarMensaje(context, 'Conecta los audífonos: el modo solo cuenta lo que suena por ellos');
      }
      await Almacen.fijarAjuste('criterio', _criterio);
      await Almacen.fijarAjuste('responsable', _responsable.text.trim());
      final id = Almacen.nuevoId();
      final sesion = <String, dynamic>{
        'id': id,
        'modo': modo.id,
        'fecha': DateTime.now().toIso8601String(),
        'lugar': _lugar.text.trim(),
        'persona': _persona.text.trim(),
        'actividad': _actividad.text.trim(),
        'responsable': _responsable.text.trim(),
        'criterio': _criterio,
        'ruta_datos': await Almacen.rutaDatos(id),
        'calibracion': {
          'id': _calibracion!['id'],
          'nombre': _calibracion!['nombre'],
          'offset': _calibracion!['offset'],
          if (modo.id == 'audifonos') ...{
            'sigue_volumen': _calibracion!['sigue_volumen'] ?? true,
            'volumen': _calibracion!['volumen'] ?? -1,
          },
        },
        'terminada': false,
        if (modo.id == 'evento') ...{
          'limite': double.parse(_limite.text.replaceAll(',', '.')),
          'ventana_min': _ventana,
        },
        if (modo.id == 'audifonos') 'perfil': _perfil,
        if (modo.id == 'bandas')
          'protector': {for (final e in _protector.entries) e.key: e.value.text.trim().replaceAll(',', '.')},
      };
      await Almacen.guardarMedicion(sesion);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PantallaMedicion(sesion: sesion)));
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e');
    } finally {
      if (mounted) setState(() => _iniciando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cal = _calibracion;
    return Scaffold(
      appBar: AppBar(title: Text(modo.titulo)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(modo.descripcion, style: tema.textTheme.bodyMedium),
            const SizedBox(height: 12),
            if (cal != null)
              Card(
                color: cal['calibrado'] == false ? tema.colorScheme.tertiaryContainer : null,
                child: ListTile(
                  dense: true,
                  leading: Icon(cal['calibrado'] == false ? Icons.warning_amber : Icons.verified),
                  title: Text(cal['nombre'] as String),
                  subtitle: Text(
                    cal['calibrado'] == false
                        ? 'Los valores serán aproximados. Calibra desde la pantalla de inicio.'
                        : 'Offset ${num1(cal['offset'] as num, ' dB')}',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _lugar,
              decoration: const InputDecoration(labelText: 'Lugar'),
            ),
            TextFormField(
              controller: _persona,
              decoration: InputDecoration(labelText: modo.id == 'evento' ? 'Evento / artista' : 'Persona o puesto'),
            ),
            if (modo.id != 'audifonos')
              TextFormField(
                controller: _actividad,
                decoration: const InputDecoration(labelText: 'Actividad o fuente de ruido'),
              ),
            TextFormField(
              controller: _responsable,
              decoration: const InputDecoration(labelText: 'Responsable de la medición'),
            ),
            const SizedBox(height: 16),
            if (modo.usaMicrofono && _criterios.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: _criterio,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Criterio de dosis', border: OutlineInputBorder()),
                items: [
                  for (final c in _criterios)
                    DropdownMenuItem(value: c['id'] as String, child: Text(c['nombre'] as String)),
                ],
                onChanged: (v) => setState(() => _criterio = v!),
              ),
              const SizedBox(height: 6),
              Text(
                _criterios.firstWhere((c) => c['id'] == _criterio)['nota'] as String,
                style: tema.textTheme.bodySmall,
              ),
            ],
            if (modo.id == 'evento') ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _limite,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Límite (dBA)', border: OutlineInputBorder()),
                      validator: (v) {
                        final n = double.tryParse((v ?? '').replaceAll(',', '.'));
                        return n == null || n < 70 || n > 120 ? 'Entre 70 y 120' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _ventana,
                      decoration: const InputDecoration(labelText: 'Promedio de', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 15, child: Text('15 min')),
                        DropdownMenuItem(value: 60, child: Text('60 min')),
                      ],
                      onChanged: (v) => setState(() => _ventana = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Ejemplo: 100 dBA en 60 min es el límite que usan normas de eventos como la suiza.',
                style: tema.textTheme.bodySmall,
              ),
            ],
            if (modo.id == 'audifonos') ...[
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'adulto', label: Text('Adulto · 80 dBA')),
                  ButtonSegment(value: 'sensible', label: Text('Sensible · 75 dBA')),
                ],
                selected: {_perfil},
                onSelectionChanged: (s) => setState(() => _perfil = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                'OMS / UIT-T H.870: dosis semanal equivalente a 80 dBA durante 40 h (75 dBA en modo sensible).',
                style: tema.textTheme.bodySmall,
              ),
            ],
            if (modo.id == 'bandas') ...[
              const SizedBox(height: 16),
              Text('Protector auditivo (opcional, datos del empaque)', style: tema.textTheme.titleSmall),
              TextFormField(
                controller: _protector['nombre'],
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              Row(
                children: [
                  for (final k in ['snr', 'h', 'm', 'l', 'nrr']) ...[
                    Expanded(
                      child: TextFormField(
                        controller: _protector[k],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: k.toUpperCase()),
                      ),
                    ),
                    if (k != 'nrr') const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _iniciando || _calibracion == null ? null : _iniciar,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Empezar a medir'),
            ),
            const SizedBox(height: 8),
            Text(
              modo.usaMicrofono
                  ? 'Pon el celular cerca del oído de la persona (bolsillo de la camisa o en el hombro), con el micrófono destapado.'
                  : Platform.isIOS
                  ? 'Escucha música como siempre. El iPhone mide el nivel de los audífonos y la app lo lee de Salud '
                        '(llega con unos minutos de retraso). Revisa Ajustes > Sonido > Seguridad de audífonos.'
                  : 'Escucha música como siempre. La app mide en segundo plano mientras suene algo por los audífonos.',
              style: tema.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
