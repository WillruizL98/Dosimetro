"""Pruebas del backend en el PC con mediciones simuladas.

Uso:  python pruebas_python/prueba_backend.py  (genera PDFs en pruebas_python/salida)
"""

import json
import math
import os
import random
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(AQUI, "..", "android", "app", "src", "main", "python"))

import dosis  # noqa: E402
import informe  # noqa: E402
import protector  # noqa: E402

SALIDA = os.path.join(AQUI, "salida")
os.makedirs(SALIDA, exist_ok=True)
T0 = 1_793_000_000.0


def simular(nombre, segundos, nivel, bandas=True, audifonos=False, marcas=()):
    ruta = os.path.join(SALIDA, nombre)
    rnd = random.Random(1)
    with open(ruta, "w", encoding="utf-8") as f:
        cab = {"tipo": "cabecera", "modo": "x", "inicio": T0, "offset": 112.35, "fs": 48000,
               "fuente": "UNPROCESSED", "dispositivo": "Prueba PC", "bandas": [63, 125, 250, 500, 1000, 2000, 4000, 8000]}
        f.write(json.dumps(cab) + "\n")
        for i in range(segundos):
            la = nivel(i) + rnd.gauss(0, 1.5)
            r = {"t": T0 + i, "la": round(la, 1)}
            if audifonos:
                r.update({"vol": 11, "aud": "cable"})
            else:
                r.update({"lc": round(la + 6, 1), "lz": round(la + 7, 1), "lafmax": round(la + 3, 1),
                          "lafmin": round(la - 4, 1), "lcpk": round(la + 20 + rnd.random() * 8, 1)})
                if bandas:
                    r["b"] = [round(la + d, 1) for d in (4, 6, 4, 1, -1, -3, -7, -13)]
            f.write(json.dumps(r) + "\n")
            for m_seg, texto in marcas:
                if m_seg == i:
                    f.write(json.dumps({"t": T0 + i, "marca": texto}) + "\n")
    return ruta


def comprobar(cond, texto):
    print(("OK   " if cond else "FALLA") + " " + texto)
    if not cond:
        sys.exit(1)


# 1. Fórmulas con valores conocidos
crit = {"lc": 85, "q": 5, "umbral": 80, "horas": 8}
comprobar(abs(dosis.dosis_pct([85] * 8 * 3600, crit) - 100) < 1e-6, "85 dBA durante 8 h = 100 % (Q 5)")
comprobar(abs(dosis.dosis_pct([90] * 4 * 3600, crit) - 100) < 1e-6, "90 dBA durante 4 h = 100 % (Q 5)")
comprobar(dosis.dosis_pct([79.9] * 3600, crit) == 0, "bajo el umbral de 80 dBA no suma")
crit3 = {"lc": 85, "q": 3, "umbral": None, "horas": 8}
comprobar(abs(dosis.dosis_pct([88] * 4 * 3600, crit3) - 100) < 1e-6, "88 dBA durante 4 h = 100 % (Q 3)")
comprobar(abs(dosis.nivel_desde_dosis(160, 8, crit) - (85 + 16.61 * math.log10(1.6))) < 0.01, "TWA con dosis 160 %")
comprobar(abs(dosis.leq([90, 90]) - 90) < 1e-9 and abs(dosis.leq([90, 80]) - 87.4) < 0.05, "Leq energético")
comprobar(abs(dosis._pa2h([80] * 40 * 3600) - 1.6) < 0.001, "80 dBA × 40 h = 1,6 Pa²·h (OMS)")

# 2. HML de un ejemplo de la ISO 4869-2: H 32, M 25, L 17; LC − LA = 5 → PNR = 25 − 8/8·3 = 22
comprobar(abs(protector.hml_pnr(90, 95, 32, 25, 17) - 22) < 1e-9, "HML con LC − LA = 5 dB")

# 3. Mediciones simuladas e informes
jornada = simular("jornada.jsonl", 3 * 3600 + 20 * 60, lambda i: 88.4 + 3 * math.sin(i / 900))
r = dosis.resumen({"ruta": jornada, "modo": "jornada", "criterio": "res1792"})
print(f"     jornada: LAeq {r['laeq']} dosis {r['dosis']} % proy {r['dosis_proyectada']} % "
      f"TWA {r['twa']} LEX {r['lex8h']} restante {r['restante_texto']}")
comprobar(60 < r["dosis"] < 80, "dosis de la jornada simulada en el rango esperado")

evento = simular("evento.jsonl", 2 * 3600, lambda i: 92 + 8 * min(1, i / 4000), bandas=False,
                 marcas=[(1200, "Banda 1"), (3600, "Banda 2")])
ev = dosis.resumen({"ruta": evento, "modo": "evento", "criterio": "niosh", "limite": 100, "ventana_min": 60})
print(f"     evento: LAeq60 {ev['laeq_ventana']} máx {ev['movil_max']} min sobre {ev['minutos_sobre_limite']}")

bandas = simular("bandas.jsonl", 300, lambda i: 93)
b = dosis.resumen({"ruta": bandas, "modo": "bandas", "criterio": "iso"})
print(f"     bandas: {b['bandas']} LC−LA {b['lc_menos_la']}")

aud = simular("audifonos.jsonl", 5400, lambda i: 86, audifonos=True)
sem = dosis.semana({"rutas": [aud], "ahora": T0 + 6000, "nivel_actual": 86})
print(f"     audífonos: semana {sem['dosis']} % restante {sem['restante_texto']}")
comprobar(abs(sem["dosis"] - 100 * 1.5 * 0.04 * 10 ** 0.6 / 1.6) < 3, "dosis semanal de 1,5 h a 86 dBA")

sesiones = {
    "jornada": {"ruta_datos": jornada, "criterio": "res1792", "lugar": "Taller de carpintería",
                "persona": "Operario de sierra", "actividad": "Corte de tablas", "responsable": "Wilmar Ruiz"},
    "evento": {"ruta_datos": evento, "criterio": "niosh", "limite": 100, "ventana_min": 60,
               "lugar": "Auditorio", "persona": "Ingeniero FOH"},
    "bandas": {"ruta_datos": bandas, "criterio": "iso", "lugar": "Planta",
               "protector": {"nombre": "Tapón espuma", "snr": 28, "h": 30, "m": 24, "l": 20, "nrr": 29}},
    "audifonos": {"ruta_datos": aud, "perfil": "adulto", "persona": "Estudiante"},
}
for modo, s in sesiones.items():
    s.update({"modo": modo, "calibracion": {"nombre": "Prueba"}})
    ruta = informe.generar_pdf({"sesion": s, "ruta": os.path.join(SALIDA, f"informe_{modo}.pdf"),
                                "rutas_semana": [aud]})
    comprobar(os.path.getsize(ruta) > 2000, f"informe {modo} generado")
print("Todo bien.")
