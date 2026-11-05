import 'package:flutter/material.dart';

import '../modos.dart';
import '../servicios/almacen.dart';
import '../servicios/plataforma.dart';
import '../widgets/graficas.dart';

/// Resultados de una medición terminada, informe PDF y exportación CSV.
class PantallaResultado extends StatefulWidget {
  const PantallaResultado({super.key, required this.sesion});
  final Map<String, dynamic> sesion;

  @override
  State<PantallaResultado> createState() => _EstadoResultado();
}

class _EstadoResultado extends State<PantallaResultado> {
  late Map<String, dynamic> _sesion = widget.sesion;
  Map<String, dynamic>? _r;
  Map<String, dynamic>? _semana;
  String? _error;
  bool _trabajando = false;

  Modo get modo => Modo.porId(_sesion['modo'] as String);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = Map<String, dynamic>.from(
        await Plataforma.python('dosis', 'resumen', {
          'ruta': _sesion['ruta_datos'],
          'modo': _sesion['modo'],
          'criterio': _sesion['criterio'],
          'limite': _sesion['limite'],
          'ventana_min': _sesion['ventana_min'],
          'perfil': _sesion['perfil'],
        }) as Map,
      );
      Map<String, dynamic>? semana;
      if (modo.id == 'audifonos') {
        semana = Map<String, dynamic>.from(
          await Plataforma.python('dosis', 'semana', {
            'rutas': await Almacen.rutasAudifonos(),
            'perfil': _sesion['perfil'],
            'ahora': r['fin_t'],
          }) as Map,
        );
      }
      setState(() {
        _r = r;
        _semana = semana;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  String get _nombreBase {
    final lugar = ((_sesion['lugar'] as String?) ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return 'Dosimetro_${modo.id}_${_sesion['id']}${lugar.isEmpty ? '' : '_$lugar'}';
  }

  Future<void> _pdf({required bool compartir}) async {
    setState(() => _trabajando = true);
    try {
      final ruta = await Plataforma.python('informe', 'generar_pdf', {
        'sesion': _sesion,
        'ruta': await Almacen.rutaInforme('$_nombreBase.pdf'),
        'rutas_semana': await Almacen.rutasAudifonos(),
      }) as String;
      compartir ? await Plataforma.compartir(ruta, 'application/pdf') : await Plataforma.abrir(ruta, 'application/pdf');
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _csv() async {
    setState(() => _trabajando = true);
    try {
      final ruta = await Plataforma.python('dosis', 'exportar_csv', {
        'ruta': _sesion['ruta_datos'],
        'destino': await Almacen.rutaInforme('$_nombreBase.csv'),
      }) as String;
      await Plataforma.compartir(ruta, 'text/csv');
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _notas() async {
    final texto = TextEditingController(text: (_sesion['notas'] as String?) ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Observaciones'),
        content: TextField(
          controller: texto,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return;
    _sesion = {..._sesion, 'notas': texto.text.trim()};
    await Almacen.guardarMedicion(_sesion);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Resultados')),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(16), child: Text(_error!))
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(modo.titulo, style: tema.textTheme.titleLarge),
                Text(
                  [
                    fechaCorta(_sesion['fecha'] as String?),
                    if ((_sesion['lugar'] as String? ?? '').isNotEmpty) _sesion['lugar'],
                    if ((_sesion['persona'] as String? ?? '').isNotEmpty) _sesion['persona'],
                  ].join(' · '),
                  style: tema.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if ((r['segundos'] as int? ?? 0) == 0)
                  const Text('La medición no tiene datos (duró menos de un segundo o no sonó nada).')
                else
                  ...(modo.id == 'audifonos' ? _audifonos(tema, r) : _microfono(tema, r)),
                if ((_sesion['notas'] as String? ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Observaciones', style: tema.textTheme.titleSmall),
                  Text(_sesion['notas'] as String),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _trabajando ? null : () => _pdf(compartir: false),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Ver informe PDF'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _trabajando ? null : () => _pdf(compartir: true),
                        icon: const Icon(Icons.share),
                        label: const Text('Compartir PDF'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _trabajando ? null : _csv,
                        icon: const Icon(Icons.table_chart),
                        label: const Text('CSV'),
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: _notas,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Observaciones'),
                ),
              ],
            ),
    );
  }

  List<Widget> _microfono(ThemeData tema, Map<String, dynamic> r) {
    final crit = r['criterio'] as Map<String, dynamic>;
    final minutos = (r['por_minuto'] as List).cast<Map<String, dynamic>>();
    return [
      Row(
        children: [
          AnilloDosis(dosis: r['dosis'] as num?, tamano: 130),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Duración ${r['duracion_texto']}', style: tema.textTheme.titleSmall),
                Text(crit['nombre'] as String, style: tema.textTheme.bodySmall),
                const SizedBox(height: 6),
                Text(
                  'Proyectada a 8 h: ${num1(r['dosis_proyectada'] as num?, ' %')}',
                  style: tema.textTheme.bodyMedium!.copyWith(color: colorDosis(r['dosis_proyectada'] as num?)),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      RejillaValores([
        Valor('LAeq', num1(r['laeq'] as num?), unidad: 'dBA'),
        Valor('LCeq', num1(r['lceq'] as num?), unidad: 'dBC'),
        Valor('LCpico', num1(r['lcpk'] as num?), unidad: 'dBC'),
        Valor('TWA', num1(r['twa'] as num?), unidad: 'dBA'),
        Valor('LEX,8h', num1(r['lex8h'] as num?), unidad: 'dBA'),
        Valor('L10 / L90', '${num1(r['l10'] as num?)} / ${num1(r['l90'] as num?)}', unidad: 'dBA'),
      ]),
      if (modo.id == 'evento') ...[
        Text('LAeq móvil ${r['ventana_min']} min', style: tema.textTheme.titleSmall),
        const SizedBox(height: 6),
        GraficaLinea(valores: (r['movil_por_minuto'] as List).cast<num?>(), limite: r['limite'] as num?),
        Text(
          'Máximo ${num1(r['movil_max'] as num?, ' dBA')} · ${r['minutos_sobre_limite']} min sobre el límite',
          style: tema.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
      ],
      if (modo.id == 'bandas' && r['bandas'] != null) ...[
        Text('Bandas de octava (Leq)', style: tema.textTheme.titleSmall),
        const SizedBox(height: 6),
        GraficaBarras(
          etiquetas: const ['63', '125', '250', '500', '1k', '2k', '4k', '8k'],
          valores: (r['bandas'] as List).cast<num?>(),
          desde: ((r['bandas'] as List).whereType<num>().reduce((a, b) => a < b ? a : b)) - 15,
        ),
        const SizedBox(height: 12),
      ],
      Text('LAeq por minuto', style: tema.textTheme.titleSmall),
      const SizedBox(height: 6),
      GraficaLinea(valores: [for (final m in minutos) m['laeq'] as num?], limite: crit['lc'] as num),
      const SizedBox(height: 12),
      for (final nota in (r['evaluacion'] as List).cast<String>())
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $nota')),
    ];
  }

  List<Widget> _audifonos(ThemeData tema, Map<String, dynamic> r) {
    final dias = (_semana?['dias'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return [
      Row(
        children: [
          AnilloDosis(dosis: _semana?['dosis'] as num?, etiqueta: '7 días', tamano: 130),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'Esta sesión sumó ${num1(r['dosis_semanal'] as num?, ' %')} de la dosis semanal.',
              style: tema.textTheme.titleSmall,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      RejillaValores([
        Valor('LAeq en el oído', num1(r['laeq'] as num?), unidad: 'dBA'),
        Valor('Escuchando', r['duracion_texto'] as String),
      ]),
      if (dias.isNotEmpty)
        GraficaBarras(
          etiquetas: [for (final d in dias) d['letra'] as String],
          valores: [for (final d in dias) d['dosis'] as num],
          colores: [for (final d in dias) colorDosis(d['dosis'] as num)],
          alto: 120,
        ),
    ];
  }
}
