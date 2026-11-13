"""Medición sin datos (0 segundos): el informe PDF no debe fallar en ningún modo."""
import json, os, sys
AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(AQUI, "..", "android", "app", "src", "main", "python"))
import dosis, informe  # noqa: E402
SALIDA = os.path.join(AQUI, "salida"); os.makedirs(SALIDA, exist_ok=True)
ruta = os.path.join(SALIDA, "vacia.jsonl")
with open(ruta, "w", encoding="utf-8") as f:
    f.write(json.dumps({"tipo": "cabecera", "modo": "bandas", "inicio": 1793000000.0, "offset": 112.35,
                        "fs": 48000, "fuente": "measurement", "dispositivo": "iPhone",
                        "bandas": [63, 125, 250, 500, 1000, 2000, 4000, 8000]}) + "\n")
for modo in ("jornada", "bandas", "evento", "audifonos"):
    sesion = {"modo": modo, "ruta_datos": ruta, "lugar": "Calle", "persona": "Will Ruiz",
              "protector": {"tipo": "tapones", "nrr": 29}}
    pdf = os.path.join(SALIDA, f"vacia_{modo}.pdf")
    informe.generar_pdf({"sesion": sesion, "ruta": pdf, "rutas_semana": [ruta]})
    print(modo, "OK", os.path.getsize(pdf), "bytes")
    dosis.exportar_csv({"ruta": ruta, "destino": os.path.join(SALIDA, f"vacia_{modo}.csv")})
print("CSV OK")
