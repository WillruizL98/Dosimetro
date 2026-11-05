"""Cálculo de dosis y niveles a partir del archivo de la medición.

Kotlin escribe un registro JSON por segundo (``la``, ``lc``, ``lz``, ``lafmax``,
``lafmin``, ``lcpk`` y las bandas ``b``). Aquí se leen y se calcula todo lo demás.
El archivo se lee de forma incremental para que la pantalla en vivo sea rápida.
"""

import csv
import json
import math
import os
from datetime import datetime

import normas

P0 = 20e-6  # presión de referencia (Pa)


# ---------------------------------------------------------------- lectura

class _Sesion:
    def __init__(self):
        self.posicion = 0
        self.cabecera = {}
        self.t, self.la, self.lc, self.lz = [], [], [], []
        self.lafmax, self.lafmin, self.lcpk, self.bandas = [], [], [], []
        self.vol = []
        self.marcas = []


_cache = {}


def _leer(ruta):
    """Devuelve la sesión con todos los registros, leyendo solo lo nuevo del archivo."""
    s = _cache.get(ruta)
    tam = os.path.getsize(ruta) if os.path.exists(ruta) else 0
    if s is None or tam < s.posicion:
        s = _Sesion()
        _cache[ruta] = s
    if tam == s.posicion:
        return s
    with open(ruta, "rb") as f:
        f.seek(s.posicion)
        datos = f.read()
    ultimo = datos.rfind(b"\n")
    if ultimo < 0:
        return s  # línea incompleta: se lee en la próxima llamada
    s.posicion += ultimo + 1
    for linea in datos[: ultimo + 1].decode("utf-8", "replace").splitlines():
        if not linea.strip():
            continue
        try:
            r = json.loads(linea)
        except ValueError:
            continue
        if r.get("tipo") == "cabecera":
            s.cabecera = r
        elif "marca" in r:
            s.marcas.append({"t": r["t"], "texto": r["marca"]})
        elif "la" in r:
            s.t.append(r["t"])
            s.la.append(r["la"])
            s.lc.append(r.get("lc"))
            s.lz.append(r.get("lz"))
            s.lafmax.append(r.get("lafmax", r["la"]))
            s.lafmin.append(r.get("lafmin", r["la"]))
            s.lcpk.append(r.get("lcpk"))
            if "b" in r:
                s.bandas.append(r["b"])
            if "vol" in r:
                s.vol.append(r["vol"])
    return s


# ---------------------------------------------------------------- fórmulas

def leq(niveles):
    """Nivel equivalente (promedio de energía) de niveles por segundo."""
    niveles = [n for n in niveles if n is not None]
    if not niveles:
        return None
    return 10 * math.log10(sum(10 ** (n / 10) for n in niveles) / len(niveles))


def tiempo_permitido_h(nivel, crit):
    """Horas permitidas a un nivel: T = Tc / 2^((L − Lc) / Q)."""
    return crit["horas"] / 2 ** ((nivel - crit["lc"]) / crit["q"])


def dosis_pct(niveles, crit, segundos_por_registro=1.0):
    """Dosis en %: 100 · Σ tᵢ / T(Lᵢ), sin contar lo que está bajo el umbral."""
    umbral = crit["umbral"]
    total = 0.0
    for n in niveles:
        if umbral is not None and n < umbral:
            continue
        total += (segundos_por_registro / 3600) / tiempo_permitido_h(n, crit)
    return 100 * total


def nivel_desde_dosis(dosis, horas, crit):
    """Nivel constante que daría esa dosis en esas horas (TWA o Lavg)."""
    if dosis <= 0 or horas <= 0:
        return None
    return crit["lc"] + crit["q"] / math.log10(2) * math.log10(dosis / 100 * crit["horas"] / horas)


def percentil_excedido(niveles, p):
    """L_p: nivel superado el p % del tiempo (L10, L50, L90)."""
    if not niveles:
        return None
    orden = sorted(niveles, reverse=True)
    i = min(len(orden) - 1, max(0, math.ceil(p / 100 * len(orden)) - 1))
    return orden[i]


def _r(v, d=1):
    return None if v is None else round(v, d)


def _hhmm(horas):
    if horas is None:
        return "—"
    if horas == math.inf:
        return "sin límite"
    minutos = int(round(horas * 60))
    return f"{minutos // 60} h {minutos % 60:02d} min" if minutos >= 60 else f"{minutos} min"


def _twa(d, crit):
    """TWA de 8 h; por debajo de 70 dBA no tiene sentido mostrarlo (dosis casi nula)."""
    twa = nivel_desde_dosis(d, crit["horas"], crit)
    return _r(twa) if twa is not None and twa >= 70 else None


# ---------------------------------------------------------------- en vivo

def estado(datos):
    """Valores para la pantalla en vivo de los modos jornada, bandas y evento."""
    s = _leer(datos["ruta"])
    crit = normas.criterio(datos.get("criterio", "res1792"))
    n = len(s.la)
    if n == 0:
        return {"segundos": 0}
    horas = n / 3600
    d = dosis_pct(s.la, crit)
    ultimo_min = s.la[-60:]
    nivel_reciente = leq(ultimo_min)
    if crit["umbral"] is not None and nivel_reciente < crit["umbral"]:
        restante = math.inf
    else:
        restante = max(0.0, 1 - d / 100) * tiempo_permitido_h(nivel_reciente, crit)
    picos = [p for p in s.lcpk if p is not None]
    r = {
        "segundos": n,
        "laeq": _r(leq(s.la)),
        "lceq": _r(leq(s.lc)),
        "lcpk": _r(max(picos) if picos else None),
        "lafmax": _r(max(s.lafmax)),
        "dosis": _r(d),
        "dosis_proyectada": _r(d * crit["horas"] / horas),
        "twa": _twa(d, crit),
        "lex8h": _r(leq(s.la) + 10 * math.log10(horas / 8)),
        "nivel_reciente": _r(nivel_reciente),
        "restante_h": None if restante == math.inf else round(restante, 3),
        "restante_texto": "ya superó el 100 %" if d >= 100 else _hhmm(restante),
    }
    if s.bandas:
        r["bandas"] = bandas_leq(s.bandas[-300:])  # últimos 5 min
        r["bandas_centros"] = s.cabecera.get("bandas", [63, 125, 250, 500, 1000, 2000, 4000, 8000])
        r["lc_menos_la"] = _r(leq(s.lc[-300:]) - leq(s.la[-300:]))
    if datos.get("modo") == "evento":
        r.update(evento(s, datos.get("limite", 100.0), datos.get("ventana_min", 60)))
    return r


def bandas_leq(filas):
    if not filas:
        return []
    return [_r(leq([f[i] for f in filas])) for i in range(len(filas[0]))]


def evento(s, limite, ventana_min):
    """Promedios móviles de 15 y 60 min, margen al límite y minutos por encima."""
    v = int(ventana_min * 60)
    actual = leq(s.la[-v:])
    l15 = leq(s.la[-900:])
    # LAeq móvil de la ventana, minuto a minuto, para la gráfica y el máximo
    energia = [10 ** (n / 10) for n in s.la]
    acumulada = [0.0]
    for e in energia:
        acumulada.append(acumulada[-1] + e)
    movil = []
    for fin in range(60, len(energia) + 1, 60):
        ini = max(0, fin - v)
        movil.append(round(10 * math.log10((acumulada[fin] - acumulada[ini]) / (fin - ini)), 1))
    sobre = sum(1 for m in movil if m > limite)
    return {
        "limite": limite,
        "ventana_min": ventana_min,
        "laeq_ventana": _r(actual),
        "laeq_15": _r(l15),
        "margen": _r(limite - actual),
        "movil_por_minuto": movil,
        "movil_max": max(movil) if movil else _r(actual),
        "minutos_sobre_limite": sobre,
    }


# ---------------------------------------------------------------- resumen completo

def resumen(datos):
    """Todo lo que necesita la pantalla de resultados y el informe PDF."""
    s = _leer(datos["ruta"])
    modo = datos.get("modo", "jornada")
    if modo == "audifonos":
        return resumen_audifonos(s, datos)
    crit = normas.criterio(datos.get("criterio", "res1792"))
    r = estado(datos)
    n = len(s.la)
    if n == 0:
        return {"segundos": 0, "criterio": crit}
    t0 = s.t[0]

    # serie por minuto
    minutos = []
    for i in range(0, n, 60):
        tramo = s.la[i:i + 60]
        picos = [p for p in s.lcpk[i:i + 60] if p is not None]
        minutos.append({
            "min": i // 60,
            "laeq": _r(leq(tramo)),
            "lafmax": _r(max(s.lafmax[i:i + 60])),
            "lcpk": _r(max(picos) if picos else None),
        })

    # tabla por hora
    horas = []
    for i in range(0, n, 3600):
        tramo = s.la[i:i + 3600]
        horas.append({
            "hora": datetime.fromtimestamp(s.t[i]).strftime("%H:%M"),
            "minutos": round(len(tramo) / 60),
            "laeq": _r(leq(tramo)),
            "lafmax": _r(max(s.lafmax[i:i + 3600])),
            "dosis": _r(dosis_pct(tramo, crit)),
        })

    # histograma de LA por segundo, clases de 1 dB
    histograma = {}
    for nivel in s.la:
        clase = int(math.floor(nivel))
        histograma[clase] = histograma.get(clase, 0) + 1

    r.update({
        "criterio": {"id": datos.get("criterio", "res1792"), **crit},
        "inicio": datetime.fromtimestamp(t0).isoformat(timespec="seconds"),
        "fin": datetime.fromtimestamp(s.t[-1]).isoformat(timespec="seconds"),
        "duracion_texto": _hhmm(n / 3600),
        "lafmin": _r(min(s.lafmin)),
        "l10": _r(percentil_excedido(s.la, 10)),
        "l50": _r(percentil_excedido(s.la, 50)),
        "l90": _r(percentil_excedido(s.la, 90)),
        "lavg": _r(nivel_desde_dosis(r["dosis"], n / 3600, crit)) if r["dosis"] else None,
        "por_minuto": minutos,
        "por_hora": horas,
        "histograma": sorted([[k, v] for k, v in histograma.items()]),
        "marcas": [{"min": round((m["t"] - t0) / 60, 1), "texto": m["texto"]} for m in s.marcas],
        "equipo": {k: s.cabecera.get(k) for k in ("dispositivo", "fuente", "offset", "fs")},
        "evaluacion": evaluar(r, crit),
    })
    if s.bandas:
        r["bandas"] = bandas_leq(s.bandas)
        r["lc_menos_la"] = _r(r["lceq"] - r["laeq"]) if r["lceq"] is not None else None
    if modo == "evento":
        r.update(evento(s, datos.get("limite", 100.0), datos.get("ventana_min", 60)))
    return r


def evaluar(r, crit):
    """Frases de conclusión para la pantalla y el informe."""
    notas = []
    d, dp = r["dosis"], r["dosis_proyectada"]
    if d >= 100:
        notas.append(f"La dosis medida ({d:.0f} %) supera el 100 % del criterio {crit['corto']}.")
    elif dp >= 100:
        notas.append(f"La dosis medida es {d:.0f} %, pero si la jornada siguiera igual "
                     f"llegaría a {dp:.0f} % en {crit['horas']} h.")
    elif dp >= 50:
        notas.append(f"La dosis proyectada a {crit['horas']} h es {dp:.0f} %: supera el nivel de acción (50 %).")
    else:
        notas.append(f"La dosis proyectada a {crit['horas']} h es {dp:.0f} %: por debajo del nivel de acción.")
    if r.get("lcpk") is not None and r["lcpk"] >= crit["pico"]:
        notas.append(f"Se registró un pico de {r['lcpk']:.1f} dBC, igual o mayor al límite de {crit['pico']} dBC.")
    if r.get("lex8h") is not None:
        if r["lex8h"] >= 87:
            notas.append(f"LEX,8h = {r['lex8h']:.1f} dBA: supera el valor límite europeo de 87 dBA.")
        elif r["lex8h"] >= 85:
            notas.append(f"LEX,8h = {r['lex8h']:.1f} dBA: supera el valor de acción superior (85 dBA).")
        elif r["lex8h"] >= 80:
            notas.append(f"LEX,8h = {r['lex8h']:.1f} dBA: supera el valor de acción inferior (80 dBA).")
    return notas


# ---------------------------------------------------------------- modo audífonos

def _pa2h(niveles, segundos=1.0):
    """Exposición sonora en Pa²·h de niveles por segundo."""
    return sum((P0 ** 2) * 10 ** (n / 10) for n in niveles) * segundos / 3600


def resumen_audifonos(s, datos):
    ref = normas.ESCUCHA[datos.get("perfil", "adulto")]
    e = _pa2h(s.la)
    return {
        "segundos": len(s.la),
        "laeq": _r(leq(s.la)),
        "lafmax": _r(max(s.la)) if s.la else None,
        "pa2h": round(e, 4),
        "dosis_semanal": _r(100 * e / ref["pa2h"]),
        "inicio": datetime.fromtimestamp(s.t[0]).isoformat(timespec="seconds") if s.t else None,
        "fin_t": s.t[-1] if s.t else None,
        "duracion_texto": _hhmm(len(s.la) / 3600),
        "perfil": ref,
        "equipo": {k: s.cabecera.get(k) for k in ("dispositivo", "offset", "sigue_volumen")},
    }


def semana(datos):
    """Dosis de escucha de los últimos 7 días (OMS), sumando todas las sesiones de audífonos."""
    ref = normas.ESCUCHA[datos.get("perfil", "adulto")]
    ahora = datos.get("ahora") or datetime.now().timestamp()
    desde = ahora - 7 * 24 * 3600
    por_dia = {}
    total = 0.0
    for ruta in datos["rutas"]:
        if not os.path.exists(ruta):
            continue
        s = _leer(ruta)
        for t, n in zip(s.t, s.la):
            if t < desde:
                continue
            e = (P0 ** 2) * 10 ** (n / 10) / 3600
            dia = datetime.fromtimestamp(t).strftime("%Y-%m-%d")
            por_dia[dia] = por_dia.get(dia, 0.0) + e
            total += e
    dias = []
    for k in range(6, -1, -1):
        fecha = datetime.fromtimestamp(ahora - k * 24 * 3600)
        clave = fecha.strftime("%Y-%m-%d")
        dias.append({
            "dia": clave,
            "letra": "LMMJVSD"[fecha.weekday()],
            "dosis": round(100 * por_dia.get(clave, 0.0) / ref["pa2h"], 1),
        })
    dosis = 100 * total / ref["pa2h"]
    r = {"dosis": round(dosis, 1), "dias": dias, "perfil": ref, "pa2h": round(total, 4)}
    nivel = datos.get("nivel_actual")
    if nivel is not None:
        p2 = (P0 ** 2) * 10 ** (nivel / 10)
        horas = max(0.0, ref["pa2h"] - total) / p2
        r["restante_texto"] = "ya superó el 100 %" if dosis >= 100 else _hhmm(horas)
    return r


# ---------------------------------------------------------------- exportar

def exportar_csv(datos):
    """Un renglón por segundo, para abrir en Excel."""
    s = _leer(datos["ruta"])
    centros = s.cabecera.get("bandas", [])
    with open(datos["destino"], "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        cab = ["hora", "LAeq_1s", "LCeq_1s", "LZeq_1s", "LAFmax", "LAFmin", "LCpeak"]
        cab += [f"{c}Hz" for c in centros] if s.bandas else []
        cab += ["volumen"] if s.vol else []
        w.writerow(cab)
        for i, t in enumerate(s.t):
            fila = [datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S"),
                    s.la[i], s.lc[i], s.lz[i], s.lafmax[i], s.lafmin[i], s.lcpk[i]]
            if s.bandas:
                fila += s.bandas[i]
            if s.vol:
                fila.append(s.vol[i])
            w.writerow(["" if v is None else str(v).replace(".", ",") for v in fila])
    return datos["destino"]
