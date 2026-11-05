"""Criterios de exposición al ruido que la app puede usar.

Cada criterio define el nivel de criterio ``lc`` (dBA que dan 100 % de dosis en
``horas``), la tasa de intercambio ``q`` (dB que duplican o reducen a la mitad el
tiempo permitido) y el ``umbral`` (por debajo no suma dosis; ``None`` = todo suma).
"""

CRITERIOS = {
    "res1792": {
        "nombre": "Colombia · Resolución 1792 de 1990",
        "corto": "Res. 1792/1990",
        "lc": 85, "q": 5, "umbral": 80, "horas": 8,
        "pico": 140,
        "nota": "85 dBA durante 8 h; cada 5 dB más, el tiempo permitido se reduce a la mitad.",
    },
    "niosh": {
        "nombre": "NIOSH REL (EE. UU.)",
        "corto": "NIOSH",
        "lc": 85, "q": 3, "umbral": 80, "horas": 8,
        "pico": 140,
        "nota": "Recomendación de NIOSH (1998): 85 dBA en 8 h con tasa de 3 dB.",
    },
    "osha_pel": {
        "nombre": "OSHA PEL (EE. UU.)",
        "corto": "OSHA PEL",
        "lc": 90, "q": 5, "umbral": 90, "horas": 8,
        "pico": 140,
        "nota": "Límite legal de OSHA 29 CFR 1910.95: 90 dBA en 8 h con tasa de 5 dB.",
    },
    "osha_hc": {
        "nombre": "OSHA nivel de acción (conservación auditiva)",
        "corto": "OSHA AL",
        "lc": 85, "q": 5, "umbral": 80, "horas": 8,
        "pico": 140,
        "nota": "A partir de 50 % de esta dosis OSHA exige programa de conservación auditiva.",
    },
    "iso": {
        "nombre": "ISO 9612 · Directiva 2003/10/CE",
        "corto": "ISO / UE",
        "lc": 85, "q": 3, "umbral": None, "horas": 8,
        "pico": 137,
        "nota": "Valores de acción 80 y 85 dBA y valor límite 87 dBA (LEX,8h); picos 135, 137 y 140 dBC.",
    },
}

# OMS / UIT-T H.870 (escucha segura): dosis semanal permitida en Pa²·h
ESCUCHA = {
    "adulto": {"nombre": "OMS / UIT-T H.870 · adultos", "nivel": 80, "pa2h": 1.6},
    "sensible": {"nombre": "OMS / UIT-T H.870 · modo sensible", "nivel": 75, "pa2h": 0.51},
}

# Límite de eventos: promedio móvil de LAeq (configurable desde la app)
EVENTO_POR_DEFECTO = {"limite": 100.0, "ventana_min": 60}


def criterio(clave):
    try:
        return CRITERIOS[clave]
    except KeyError:
        raise ValueError(f"Criterio desconocido: {clave}") from None


def listar(_datos=None):
    """Lista para la pantalla de selección."""
    return [
        {"id": k, **{c: v[c] for c in ("nombre", "corto", "lc", "q", "umbral", "nota")}}
        for k, v in CRITERIOS.items()
    ]
