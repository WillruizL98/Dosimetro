import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modos.dart';
import '../servicios/almacen.dart';
import '../servicios/plataforma.dart';
import '../widgets/graficas.dart';
import 'resultado.dart';

/// Medición en vivo. El micrófono lo maneja un servicio de Android, así que la
/// medición sigue aunque se salga de esta pantalla o se apague la pantalla.
class PantallaMedicion extends StatefulWidget {
  const PantallaMedicion({super.key, required this.sesion, this.reanudar = false});
  final Map<String, dynamic> sesion;
  final bool reanudar;

  @override
  State<PantallaMedicion> createState() => _EstadoMedicion();
}

class _EstadoMedicion extends State<PantallaMedicion> {
  StreamSubscription<Map<dynamic, dynamic>>? _suscripcion;
  Timer? _reloj;
  double? _laf;
  String? _audifono;
  int _segundos = 0;
  bool _pausada = false;
  bool _calculando = false;
  String? _error;
  Map<String, dynamic>? _estado;
  Map<String, dynamic>? _semana;
  Map<String, dynamic>? _protegido;
  bool _avisoLimite = false;

  Map<String, dynamic> get s => widget.sesion;
  Modo get modo => Modo.porId(s['modo'] as String);

  @override
  void initState() {
    super.initState();
    _suscripcion = Plataforma.niveles().listen(_alRecibir, onError: (e) => setState(() => _error = '$e'));
    _arrancar();
  }

  Future<void> _arrancar() async {
    if (widget.reanudar) {
      final e = await Plataforma.estadoMedicion();
      setState(() {
        _pausada = e['pausada'] == true;
        _segundos = (e['segundos'] as int?) ?? 0;
      });
    } else {
      final cal = s['calibracion'] as Map<String, dynamic>;
      await Plataforma.iniciarMedicion({
        'sesion_id': s['id'],
        'modo': s['modo'],
        'ruta': s['ruta_datos'],
        'offset': cal['offset'],
        'sigue_volumen': cal['sigue_volumen'] ?? true,
        'volumen_cal': cal['volumen'] ?? -1,
        'titulo': '${modo.titulo}${(s['lugar'] as String).isEmpty ? '' : ' · ${s['lugar']}'}',
      });
    }
    _actualizar();
    _reloj = Timer.periodic(Duration(seconds: modo.usaMicrofono ? 2 : 5), (_) => _actualizar());
  }

  void _alRecibir(Map<dynamic, dynamic> d) {
    if (!mounted) return;
    setState(() {
      if (d.containsKey('error')) _error = d['error'] as String?;
      if (d.containsKey('laf')) _laf = (d['laf'] as num?)?.toDouble();
      if (d.containsKey('audifono')) _audifono = d['audifono'] as String?;
      if (d['segundos'] != null) _segundos = d['segundos'] as int;
    });
  }

  /// Pide a Python los valores acumulados (lee el archivo de la sesión).
  Future<void> _actualizar() async {
    if (_calculando || !mounted) return;
    _calculando = true;
    try {
      if (modo.usaMicrofono) {
        final r = Map<String, dynamic>.from(
          await Plataforma.python('dosis', 'estado', {
            'ruta': s['ruta_datos'],
            'criterio': s['criterio'],
            'modo': s['modo'],
            'limite': s['limite'],
            'ventana_min': s['ventana_min'],
          }) as Map,
        );
        Map<String, dynamic>? protegido;
        final p = s['protector'] as Map<String, dynamic>?;
        if (modo.id == 'bandas' &&
            r['laeq'] != null &&
            p != null &&
            ['snr', 'h', 'nrr'].any((k) => (p[k] as String? ?? '').isNotEmpty)) {
          protegido = Map<String, dynamic>.from(
            await Plataforma.python('protector', 'calcular', {...p, 'la': r['laeq'], 'lc': r['lceq']}) as Map,
          );
        }
        _avisarLimite(r);
        if (mounted) {
          setState(() {
            _estado = r;
            _protegido = protegido;
          });
        }
      } else {
        final sesion = Map<String, dynamic>.from(
          await Plataforma.python('dosis', 'resumen', {
            'ruta': s['ruta_datos'],
            'modo': 'audifonos',
            'perfil': s['perfil'],
          }) as Map,
        );
        final semana = Map<String, dynamic>.from(
          await Plataforma.python('dosis', 'semana', {
            'rutas': await Almacen.rutasAudifonos(),
            'perfil': s['perfil'],
            'nivel_actual': _laf,
          }) as Map,
        );
        if (mounted) {
          setState(() {
            _estado = sesion;
            _semana = semana;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _calculando = false;
    }
  }

  /// En modo evento vibra una vez cuando el margen al límite baja de 1 dB.
  void _avisarLimite(Map<String, dynamic> r) {
    final margen = r['margen'] as num?;
    if (modo.id != 'evento' || margen == null) return;
    if (margen < 1 && !_avisoLimite) {
      HapticFeedback.heavyImpact();
      _avisoLimite = true;
    } else if (margen >= 2) {
      _avisoLimite = false;
    }
  }

  Future<void> _pausar() async {
    await Plataforma.pausar(!_pausada);
    setState(() => _pausada = !_pausada);
  }

  Future<void> _marcar() async {
    final texto = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Marcar momento'),
        content: TextField(
          controller: texto,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ej.: banda 2, solo de batería'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Marcar')),
        ],
      ),
    );
    if (ok == true && texto.text.trim().isNotEmpty) {
      await Plataforma.marcar(texto.text.trim());
      if (mounted) mostrarMensaje(context, 'Marca guardada en ${duracion(_segundos)}');
    }
  }

  Future<void> _terminar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Terminar la medición?'),
        content: Text('Duración: ${duracion(_segundos)}. Después se genera el informe.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Seguir midiendo')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Terminar')),
        ],
      ),
    );
    if (ok != true) return;
    _reloj?.cancel();
    await Plataforma.detenerMedicion();
    final sesion = {...s, 'terminada': true, 'fin': DateTime.now().toIso8601String()};
    await Almacen.guardarMedicion(sesion);
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => PantallaResultado(sesion: sesion)));
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    _reloj?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(modo.titulo),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_pausada ? '❚❚' : '●'} ${duracion(_segundos)}',
                style: tema.textTheme.titleMedium!.copyWith(
                  color: _pausada ? tema.colorScheme.outline : Colors.red,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Card(
              color: tema.colorScheme.errorContainer,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            ),
          _nivelInstantaneo(tema),
          const SizedBox(height: 12),
          ...switch (modo.id) {
            'audifonos' => _vistaAudifonos(tema),
            'bandas' => _vistaBandas(tema),
            'evento' => _vistaEvento(tema),
            _ => _vistaJornada(tema),
          },
          const SizedBox(height: 8),
          Text(
            'Puedes salir de esta pantalla o apagar la pantalla: la medición sigue y aparece en la notificación.',
            style: tema.textTheme.bodySmall,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pausar,
                  icon: Icon(_pausada ? Icons.play_arrow : Icons.pause),
                  label: Text(_pausada ? 'Reanudar' : 'Pausar'),
                ),
              ),
              if (modo.id == 'evento') ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _marcar,
                    icon: const Icon(Icons.flag),
                    label: const Text('Marcar'),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _terminar,
                  icon: const Icon(Icons.stop),
                  label: const Text('Terminar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nivelInstantaneo(ThemeData tema) {
    final etiqueta = modo.usaMicrofono ? 'LAF (ahora)' : 'Nivel en el oído (estimado)';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          _laf == null ? '—' : num1(_laf),
          style: tema.textTheme.displayMedium!.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('dBA', style: tema.textTheme.titleMedium),
              Text(
                modo.usaMicrofono ? etiqueta : (_audifono == null ? 'sin audífonos' : '$etiqueta · $_audifono'),
                style: tema.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _vistaJornada(ThemeData tema) {
    final e = _estado ?? {};
    return [
      Center(child: AnilloDosis(dosis: e['dosis'] as num?)),
      const SizedBox(height: 16),
      RejillaValores([
        Valor('LAeq', num1(e['laeq'] as num?), unidad: 'dBA'),
        Valor('LCpico', num1(e['lcpk'] as num?), unidad: 'dBC'),
        Valor(
          'Dosis proy. 8 h',
          num1(e['dosis_proyectada'] as num?),
          unidad: '%',
          color: colorDosis(e['dosis_proyectada'] as num?),
        ),
        Valor('TWA', num1(e['twa'] as num?), unidad: 'dBA'),
        Valor('LEX,8h', num1(e['lex8h'] as num?), unidad: 'dBA'),
        Valor('LAFmáx', num1(e['lafmax'] as num?), unidad: 'dBA'),
      ]),
      Valor('Llega al 100 % en', (e['restante_texto'] as String?) ?? '—', color: colorDosis(e['dosis'] as num?)),
      const SizedBox(height: 8),
      Text('Criterio: ${s['criterio']} · al nivel del último minuto', style: tema.textTheme.labelSmall),
    ];
  }

  List<Widget> _vistaBandas(ThemeData tema) {
    final e = _estado ?? {};
    final bandas = (e['bandas'] as List?)?.cast<num?>() ?? List<num?>.filled(8, null);
    return [
      RejillaValores([
        Valor('LAeq', num1(e['laeq'] as num?), unidad: 'dBA'),
        Valor('LCeq', num1(e['lceq'] as num?), unidad: 'dBC'),
        Valor('LC − LA', num1(e['lc_menos_la'] as num?), unidad: 'dB'),
        Valor('Dosis', num1(e['dosis'] as num?), unidad: '%', color: colorDosis(e['dosis'] as num?)),
      ]),
      Text('Bandas de octava (Leq de los últimos 5 min)', style: tema.textTheme.titleSmall),
      const SizedBox(height: 8),
      GraficaBarras(
        etiquetas: const ['63', '125', '250', '500', '1k', '2k', '4k', '8k'],
        valores: bandas,
        desde: bandas.whereType<num>().isEmpty ? 0 : (bandas.whereType<num>().reduce((a, b) => a < b ? a : b) - 15),
        alto: 180,
      ),
      if ((e['lc_menos_la'] as num? ?? 0) > 5)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'LC − LA mayor a 5 dB: predominan los graves; conviene un protector con buena atenuación en bajas.',
            style: tema.textTheme.bodySmall,
          ),
        ),
      if (_protegido != null) ...[
        const SizedBox(height: 12),
        Text('Con el protector', style: tema.textTheme.titleSmall),
        for (final r in (_protegido!['resultados'] as List).cast<Map<String, dynamic>>())
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${r['metodo']}: ${num1(r['protegido'] as num, ' dBA')}'),
            subtitle: Text('${r['clase']} · ${r['texto']}'),
          ),
      ],
    ];
  }

  List<Widget> _vistaEvento(ThemeData tema) {
    final e = _estado ?? {};
    final margen = e['margen'] as num?;
    final color = margen == null
        ? null
        : margen < 0
        ? const Color(0xFFE5533D)
        : margen < 2
        ? const Color(0xFFF2A33A)
        : const Color(0xFF3FAF6C);
    final movil = (e['movil_por_minuto'] as List?)?.cast<num?>() ?? const <num?>[];
    return [
      Valor('LAeq móvil ${s['ventana_min']} min', num1(e['laeq_ventana'] as num?), unidad: 'dBA', color: color),
      const SizedBox(height: 8),
      if (movil.length >= 2) ...[
        GraficaLinea(valores: movil, limite: s['limite'] as num?),
        Text(
          'LAeq móvil minuto a minuto · línea: límite ${num1(s['limite'] as num?, ' dBA')}',
          style: tema.textTheme.labelSmall,
        ),
        const SizedBox(height: 8),
      ],
      RejillaValores([
        Valor('LAeq 15 min', num1(e['laeq_15'] as num?), unidad: 'dBA'),
        Valor('LCpico', num1(e['lcpk'] as num?), unidad: 'dBC'),
        Valor('Margen al límite', num1(margen), unidad: 'dB', color: color),
        Valor('Min. sobre límite', '${e['minutos_sobre_limite'] ?? 0}'),
        Valor('Dosis personal', num1(e['dosis'] as num?), unidad: '%', color: colorDosis(e['dosis'] as num?)),
        Valor('LAeq total', num1(e['laeq'] as num?), unidad: 'dBA'),
      ]),
      if (margen != null && margen < 2)
        Text(
          margen < 0 ? 'Por encima del límite: bajar el nivel general.' : 'Cerca del límite: bajar un poco.',
          style: tema.textTheme.titleSmall!.copyWith(color: color),
        ),
    ];
  }

  List<Widget> _vistaAudifonos(ThemeData tema) {
    final e = _estado ?? {};
    final sem = _semana;
    final dias = (sem?['dias'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return [
      Center(
        child: AnilloDosis(dosis: sem?['dosis'] as num?, etiqueta: 'dosis semanal'),
      ),
      const SizedBox(height: 16),
      if (dias.isNotEmpty)
        GraficaBarras(
          etiquetas: [for (final d in dias) d['letra'] as String],
          valores: [for (final d in dias) d['dosis'] as num],
          colores: [for (final d in dias) colorDosis(d['dosis'] as num)],
          alto: 120,
        ),
      const SizedBox(height: 12),
      RejillaValores([
        Valor('LAeq sesión', num1(e['laeq'] as num?), unidad: 'dBA'),
        Valor('Escuchando', (e['duracion_texto'] as String?) ?? '—'),
      ]),
      Valor(
        'A este nivel te quedan',
        (sem?['restante_texto'] as String?) ?? '—',
        color: colorDosis(sem?['dosis'] as num?),
      ),
      const SizedBox(height: 8),
      Text('${(sem?['perfil'] as Map?)?['nombre'] ?? ''} · 7 días', style: tema.textTheme.labelSmall),
    ];
  }
}
