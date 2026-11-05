"""Punto de entrada único entre Kotlin y Python.

Kotlin llama a ``llamar(modulo, funcion, datos_json)``; los datos viajan como
JSON en ambos sentidos para no depender de conversiones de tipos Java/Python.
"""

import importlib
import json
import traceback

MODULOS_PERMITIDOS = {"normas", "dosis", "protector", "informe"}


def llamar(modulo, funcion, datos_json):
    try:
        if modulo not in MODULOS_PERMITIDOS:
            raise ValueError(f"Módulo no permitido: {modulo}")
        funcion_python = getattr(importlib.import_module(modulo), funcion)
        datos = json.loads(datos_json) if datos_json else None
        resultado = funcion_python(datos)
        return json.dumps({"ok": True, "resultado": resultado}, ensure_ascii=False)
    except Exception as error:  # se devuelve el error a Flutter en vez de cerrar la app
        return json.dumps(
            {
                "ok": False,
                "error": f"{type(error).__name__}: {error}",
                "traza": traceback.format_exc(),
            },
            ensure_ascii=False,
        )
