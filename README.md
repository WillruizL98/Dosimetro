# Dosímetro de ruido (Flutter + Python)

Proyecto académico de Tecnologías de Audio: un dosímetro de ruido que se ejecuta
**completamente en el teléfono**, sin servidores. Flutter dibuja la interfaz, Kotlin
lee el micrófono y Python (con [Chaquopy](https://chaquo.com/chaquopy/)) calcula la
dosis y genera el informe PDF.

> No reemplaza un dosímetro certificado (IEC 61252) ni un sonómetro (IEC 61672).

## Descargar e instalar (Android)

1. En el celular, abre [**Releases**](https://github.com/WillruizL98/Dosimetro/releases/latest)
   y descarga **`dosimetro.apk`**.
2. Ábrelo y permite *instalar apps de origen desconocido*. Si aparece Play Protect, elige
   *Más detalles → Instalar de todas formas*.
3. Al primer uso, entra a **Calibración** y calibra el micrófono con un sonómetro.

Requisitos: Android 7.0 o superior y celular de 64 bits.

## Los cuatro modos

| Modo | Qué mide | Criterio |
|---|---|---|
| **Jornada laboral** | Dosis %, dosis proyectada a 8 h, TWA, LEX,8h, LAeq, LCpico, L10/L50/L90 | Res. 1792/1990 (Colombia), NIOSH, OSHA PEL, OSHA nivel de acción, ISO 9612 |
| **Escucha con audífonos** | Nivel estimado en el oído y dosis semanal | OMS / UIT-T H.870: 80 dBA × 40 h por semana (75 dBA en modo sensible) |
| **Bandas y protector** | Espectro por bandas de octava (63 Hz–8 kHz), LC − LA y nivel con protector | Métodos SNR y HML (EN 458 / ISO 4869-2) y NRR de OSHA |
| **Evento en vivo** | LAeq móvil de 15 y 60 min, margen al límite, marcas por canción | Límite configurable (ej. 100 dBA en 60 min) |

La medición sigue con la pantalla apagada (servicio en primer plano). Cada medición
genera un **informe PDF** y un **CSV** con un renglón por segundo.

## Cálculo

```
T(L)  = 8 h / 2^((L − Lc) / Q)        tiempo permitido a un nivel L
Dosis = 100 % · Σ tᵢ / T(Lᵢ)           (no suma lo que está bajo el umbral)
TWA   = Lc + (Q / log₁₀2) · log₁₀(Dosis / 100)
LEX,8h = LAeq,T + 10 · log₁₀(T / 8 h)
```

Las ponderaciones A y C se implementan con los polos de la IEC 61672-1 llevados a
digital por transformación bilineal (con prewarp) a 48 kHz, la constante Fast es de
125 ms y las bandas de octava usan filtros Butterworth de 4.º orden.

## Arquitectura

```
Flutter (Dart)                 Kotlin (Android)                 Python (Chaquopy)
lib/pantallas/*  ── canales ─► MainActivity.kt                  puente.py
  inicio, medición en vivo,    ServicioMedicion.kt  8 h          normas.py     criterios
  resultados, calibración      Medicion.kt   micrófono 48 kHz    dosis.py      dosis, TWA, LEX, semana OMS
lib/widgets/graficas.dart      Filtros.kt    A, C, octavas      protector.py  SNR, HML, NRR
                               Calibrador.kt tono 1 kHz          informe.py    PDF (reportlab)
```

Kotlin escribe un registro JSON por segundo (`la`, `lc`, `lz`, `lafmax`, `lafmin`,
`lcpk` y las 8 bandas) en un archivo `.jsonl`; Python lo lee de forma incremental.

## Compilar

Requisitos: Flutter, Android SDK, JDK 17+ y **Python 3.13** (Chaquopy lo usa al compilar).

```bash
python pruebas_python/prueba_backend.py   # pruebas del backend con mediciones simuladas
flutter test
flutter build apk --release
```

GitHub Actions compila el APK en cada cambio y lo publica en *Releases* al crear una
etiqueta `v*`.

## Limitaciones (para la discusión del trabajo)

- El micrófono del celular no está certificado; calibrado contra un sonómetro el error
  típico es de ±2 dB. Satura cerca de 110–120 dB y pierde sensibilidad en graves.
- Sin calibrar se usa la referencia del CDD de Android (90 dB SPL → −22,35 dBFS).
- El modo audífonos estima el nivel con la salida digital (Visualizer) y la calibración
  del audífono; algunos fabricantes no permiten leer esa salida.
- iPhone: pendiente (necesita la captura en Swift y Python embebido para iOS).
