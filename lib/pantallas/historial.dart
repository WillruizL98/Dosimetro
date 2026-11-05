import 'package:flutter/material.dart';

import '../modos.dart';
import '../servicios/almacen.dart';
import 'resultado.dart';

class PantallaHistorial extends StatefulWidget {
  const PantallaHistorial({super.key});

  @override
  State<PantallaHistorial> createState() => _EstadoHistorial();
}

class _EstadoHistorial extends State<PantallaHistorial> {
  List<Map<String, dynamic>>? _lista;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final todas = await Almacen.mediciones();
    setState(() => _lista = todas.where((m) => m['terminada'] == true).toList());
  }

  Future<void> _borrar(Map<String, dynamic> m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Borrar la medición?'),
        content: const Text('Se borran sus datos. Los PDF ya compartidos no se afectan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await Almacen.borrarMedicion(m);
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final lista = _lista;
    return Scaffold(
      appBar: AppBar(title: const Text('Historial')),
      body: lista == null
          ? const Center(child: CircularProgressIndicator())
          : lista.isEmpty
          ? const Center(child: Text('Todavía no hay mediciones terminadas.'))
          : ListView.separated(
              itemCount: lista.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final m = lista[i];
                final modo = Modo.porId(m['modo'] as String);
                return ListTile(
                  leading: Icon(modo.icono),
                  title: Text([modo.titulo, if ((m['lugar'] as String? ?? '').isNotEmpty) m['lugar']].join(' · ')),
                  subtitle: Text(
                    '${fechaCorta(m['fecha'] as String?)}'
                    '${(m['persona'] as String? ?? '').isEmpty ? '' : ' · ${m['persona']}'}',
                  ),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _borrar(m)),
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => PantallaResultado(sesion: m)));
                    _cargar();
                  },
                );
              },
            ),
    );
  }
}
