import 'dart:io';

import 'package:flutter/material.dart';

import '../modos.dart';
import '../servicios/almacen.dart';
import '../servicios/plataforma.dart';

/// Perfiles de calibración del micrófono y de los audífonos.
class PantallaCalibracion extends StatelessWidget {
  const PantallaCalibracion({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calibración'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Micrófono'),
              Tab(text: 'Audífonos'),
            ],
          ),
        ),
        body: const TabBarView(children: [_ListaPerfiles('microfono'), _ListaPerfiles('audifono')]),
      ),
    );
  }
}

class _ListaPerfiles extends StatefulWidget {
  const _ListaPerfiles(this.tipo);
  final String tipo;

  @override
  State<_ListaPerfiles> createState() => _EstadoLista();
}

class _EstadoLista extends State<_ListaPerfiles> {
  List<Map<String, dynamic>> _perfiles = [];
  String? _activa;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final perfiles = await Almacen.calibraciones(widget.tipo);
    final ajustes = await Almacen.ajustes();
    setState(() {
      _perfiles = perfiles;
      _activa = ajustes['activa_${widget.tipo}'] as String?;
    });
  }

  Future<void> _nueva() async {
    final creada = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => widget.tipo == 'microfono' ? const _CalibrarMicrofono() : const _CalibrarAudifono(),
      ),
    );
    if (creada == true) _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final mic = widget.tipo == 'microfono';
    if (!mic && Platform.isIOS) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.favorite, color: Colors.red),
              title: const Text('En iPhone no hace falta calibrar los audífonos'),
              subtitle: Text(
                'El iPhone calcula el nivel que llega a tus oídos según el modelo de audífono y lo guarda en '
                'la app Salud (Exposición a audio de los audífonos). El modo audífonos lee esos datos. '
                'Es más preciso con AirPods o Beats; con otros audífonos el iPhone hace un estimado.',
                style: tema.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          mic
              ? 'Relaciona el nivel digital del micrófono (dBFS) con el nivel real (dB SPL): '
                    'offset = lectura del sonómetro − nivel medido por el celular. Cada celular necesita la suya.'
              : 'Relaciona el nivel digital de la música con el nivel en el oído. Se mide un tono de 1 kHz '
                    'con el sonómetro pegado al auricular. Cada audífono necesita la suya.',
          style: tema.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        if (_perfiles.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              title: const Text('Sin calibrar'),
              subtitle: Text(
                mic
                    ? Platform.isIOS
                          ? 'Se usa un offset aproximado de ${num1(offsetSinCalibrar, ' dB')}: calibra antes de medir.'
                          : 'Se usa la referencia de Android: offset ${num1(offsetSinCalibrar, ' dB')} (aprox. ±5 dB).'
                    : 'Se usa un valor aproximado; el modo audífonos no será confiable.',
              ),
            ),
          ),
        RadioGroup<String>(
          groupValue: _activa,
          onChanged: (v) async {
            await Almacen.fijarAjuste('activa_${widget.tipo}', v);
            _cargar();
          },
          child: Column(
            children: [
              for (final p in _perfiles)
                Card(
                  child: RadioListTile<String>(
                    value: p['id'] as String,
                    title: Text(p['nombre'] as String),
                    subtitle: Text(
                      '${fechaCorta(p['fecha'] as String?)} · offset ${num1(p['offset'] as num, ' dB')}'
                      '${p['metodo'] == null ? '' : ' · ${p['metodo']}'}',
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await Almacen.borrarCalibracion(p['id'] as String);
                        if (_activa == p['id']) await Almacen.fijarAjuste('activa_${widget.tipo}', null);
                        _cargar();
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _nueva, icon: const Icon(Icons.add), label: const Text('Nueva calibración')),
      ],
    );
  }
}

class _CalibrarMicrofono extends StatefulWidget {
  const _CalibrarMicrofono();

  @override
  State<_CalibrarMicrofono> createState() => _EstadoCalMic();
}

class _EstadoCalMic extends State<_CalibrarMicrofono> {
  final _nombre = TextEditingController();
  final _referencia = TextEditingController();
  String _metodo = 'sonometro';
  int _segundos = 10;
  bool _midiendo = false;
  Map<dynamic, dynamic>? _medida;

  Future<void> _medir() async {
    if (!await Plataforma.pedirPermisos()) {
      if (mounted) mostrarMensaje(context, 'Se necesita el permiso de micrófono');
      return;
    }
    setState(() => _midiendo = true);
    try {
      final m = await Plataforma.medirMicrofono(_segundos);
      setState(() => _medida = m);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e');
    } finally {
      if (mounted) setState(() => _midiendo = false);
    }
  }

  Future<void> _guardar() async {
    final ref = double.tryParse(_referencia.text.replaceAll(',', '.'));
    if (ref == null || ref < 40 || ref > 130) {
      mostrarMensaje(context, 'Escribe la lectura del sonómetro (entre 40 y 130 dB)');
      return;
    }
    final medido = (_medida!['la_dbfs'] as num).toDouble();
    final offset = ref - medido;
    final id = Almacen.nuevoId();
    await Almacen.guardarCalibracion({
      'id': id,
      'tipo': 'microfono',
      'nombre': _nombre.text.trim().isEmpty ? 'Micrófono $id' : _nombre.text.trim(),
      'fecha': DateTime.now().toIso8601String(),
      'metodo': _metodo == 'sonometro' ? 'sonómetro' : 'calibrador 94 dB',
      'referencia': ref,
      'medido_dbfs': double.parse(medido.toStringAsFixed(2)),
      'offset': double.parse(offset.toStringAsFixed(2)),
      'calibrado': true,
    });
    await Almacen.fijarAjuste('activa_microfono', id);
    if ((offset < 95 || offset > 135) && mounted) {
      mostrarMensaje(context, 'Offset ${num1(offset)} dB: es poco común. Revisa la lectura y repite si hace falta.');
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Calibrar micrófono')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nombre,
            decoration: const InputDecoration(labelText: 'Nombre (ej.: Sonómetro del laboratorio)'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'sonometro', label: Text('Con sonómetro')),
              ButtonSegment(value: 'calibrador', label: Text('Calibrador 94 dB')),
            ],
            selected: {_metodo},
            onSelectionChanged: (s) => setState(() {
              _metodo = s.first;
              if (_metodo == 'calibrador') _referencia.text = '94';
            }),
          ),
          const SizedBox(height: 12),
          Text(
            _metodo == 'sonometro'
                ? '1. Pon un ruido estable y fuerte (ruido rosa por un parlante, 80–90 dBA).\n'
                      '2. Coloca el micrófono del celular junto al del sonómetro, a la misma distancia de la fuente.\n'
                      '3. Pon el sonómetro en ponderación A, respuesta lenta, y mide Leq durante el mismo tiempo.\n'
                      '4. Pulsa Medir y al final escribe el LAeq que marcó el sonómetro.'
                : '1. Ajusta el calibrador acústico sobre el micrófono del celular (con un adaptador o plastilina '
                      'para sellar).\n2. Enciéndelo (94 dB a 1 kHz) y pulsa Medir.',
            style: tema.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _segundos,
            decoration: const InputDecoration(labelText: 'Duración', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 5, child: Text('5 s')),
              DropdownMenuItem(value: 10, child: Text('10 s')),
              DropdownMenuItem(value: 30, child: Text('30 s')),
            ],
            onChanged: (v) => setState(() => _segundos = v!),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _midiendo ? null : _medir,
            icon: _midiendo
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.mic),
            label: Text(_midiendo ? 'Midiendo $_segundos s…' : 'Medir'),
          ),
          if (_medida != null) ...[
            const SizedBox(height: 16),
            Text(
              'El celular midió ${num1(_medida!['la_dbfs'] as num, ' dBFS')} (ponderación A).',
              style: tema.textTheme.titleSmall,
            ),
            TextField(
              controller: _referencia,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _metodo == 'sonometro' ? 'LAeq del sonómetro (dBA)' : 'Nivel del calibrador (dB)',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _guardar, child: const Text('Guardar calibración')),
          ],
        ],
      ),
    );
  }
}

class _CalibrarAudifono extends StatefulWidget {
  const _CalibrarAudifono();

  @override
  State<_CalibrarAudifono> createState() => _EstadoCalAud();
}

class _EstadoCalAud extends State<_CalibrarAudifono> {
  final _nombre = TextEditingController();
  final _referencia = TextEditingController();
  bool _sonando = false;
  bool _midiendo = false;

  Future<void> _tono() async {
    if (_sonando) {
      await Plataforma.detenerTono();
      setState(() => _sonando = false);
      return;
    }
    if (!await Plataforma.pedirPermisos()) return;
    if (await Plataforma.audifono() == null) {
      if (mounted) mostrarMensaje(context, 'Conecta los audífonos primero');
      return;
    }
    await Plataforma.tonoCalibracion();
    setState(() => _sonando = true);
  }

  Future<void> _guardar() async {
    final ref = double.tryParse(_referencia.text.replaceAll(',', '.'));
    if (ref == null || ref < 40 || ref > 130) {
      mostrarMensaje(context, 'Escribe la lectura del sonómetro (entre 40 y 130 dB)');
      return;
    }
    setState(() => _midiendo = true);
    try {
      final m = await Plataforma.medirAudifono();
      await Plataforma.detenerTono();
      final offset = ref - (m['rms_dbfs'] as num);
      final id = Almacen.nuevoId();
      await Almacen.guardarCalibracion({
        'id': id,
        'tipo': 'audifono',
        'nombre': _nombre.text.trim().isEmpty ? 'Audífonos ${m['audifono'] ?? ''}' : _nombre.text.trim(),
        'fecha': DateTime.now().toIso8601String(),
        'metodo': 'tono 1 kHz −20 dBFS',
        'referencia': ref,
        'medido_dbfs': m['rms_dbfs'],
        'offset': double.parse(offset.toStringAsFixed(2)),
        'sigue_volumen': m['sigue_volumen'],
        'volumen': m['volumen'],
        'calibrado': true,
      });
      await Almacen.fijarAjuste('activa_audifono', id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e');
    } finally {
      if (mounted) setState(() => _midiendo = false);
    }
  }

  @override
  void dispose() {
    if (_sonando) Plataforma.detenerTono();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Calibrar audífonos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nombre,
            decoration: const InputDecoration(labelText: 'Nombre del audífono'),
          ),
          const SizedBox(height: 12),
          Text(
            '1. Conecta los audífonos y pon el volumen en el nivel en que sueles escuchar.\n'
            '2. Pega el micrófono del sonómetro al auricular (idealmente con un acoplador).\n'
            '3. Pulsa Reproducir tono, lee el sonómetro (ponderación A o Z) y escríbelo.\n'
            '4. Pulsa Guardar con el tono sonando: la app mide la salida y prueba si sigue el volumen '
            '(bajará el volumen un momento).',
            style: tema.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _midiendo ? null : _tono,
            icon: Icon(_sonando ? Icons.stop : Icons.volume_up),
            label: Text(_sonando ? 'Detener tono' : 'Reproducir tono 1 kHz'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _referencia,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Lectura del sonómetro (dB)'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _sonando && !_midiendo ? _guardar : null,
            child: Text(_midiendo ? 'Midiendo…' : 'Guardar calibración'),
          ),
        ],
      ),
    );
  }
}
