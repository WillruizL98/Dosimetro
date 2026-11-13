"""Informe PDF de la medición con reportlab (todo se ejecuta en el teléfono)."""

from datetime import datetime
from xml.sax.saxutils import escape

from reportlab.graphics.shapes import Drawing, Line, PolyLine, Rect, String
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import KeepTogether, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

import dosis
import protector

GRIS = colors.HexColor("#9E9E9E")
GUIA = colors.HexColor("#D0D0D0")
CABECERA = colors.HexColor("#EEEEEE")
ANCHO = letter[0] - 3.6 * cm

MODOS = {
    "jornada": "Dosimetría de jornada laboral",
    "bandas": "Medición por bandas de octava y protector auditivo",
    "evento": "Monitoreo de exposición en evento en vivo",
    "audifonos": "Dosis de escucha con audífonos",
}


def _t(v, sufijo=""):
    if v in (None, ""):
        return "—"
    if isinstance(v, float):
        return f"{v:.1f}{sufijo}".replace(".", ",")
    return escape(f"{v}{sufijo}")


def _fecha(iso):
    try:
        return datetime.fromisoformat(iso).strftime("%d/%m/%Y %H:%M")
    except (TypeError, ValueError):
        return iso or "—"


def _tabla(filas, anchos, cabecera=True, primera_col=False):
    t = Table(filas, colWidths=anchos, repeatRows=1 if cabecera else 0)
    estilo = [
        ("FONT", (0, 0), (-1, -1), "Helvetica", 8.5),
        ("GRID", (0, 0), (-1, -1), 0.4, GUIA),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
    ]
    if cabecera:
        estilo += [("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 8.5), ("BACKGROUND", (0, 0), (-1, 0), CABECERA)]
    if primera_col:
        estilo += [("FONT", (0, 0), (0, -1), "Helvetica-Bold", 8.5), ("BACKGROUND", (0, 0), (0, -1), CABECERA)]
    t.setStyle(TableStyle(estilo))
    return t


def _pares(pares):
    """Tabla de dos pares etiqueta/valor por fila."""
    filas = []
    for i in range(0, len(pares), 2):
        a = pares[i]
        b = pares[i + 1] if i + 1 < len(pares) else ("", "")
        filas.append([a[0], a[1], b[0], b[1]])
    t = _tabla(filas, [3.4 * cm, ANCHO / 2 - 3.4 * cm] * 2, cabecera=False)
    t.setStyle(TableStyle([
        ("FONT", (0, 0), (0, -1), "Helvetica-Bold", 8.5), ("FONT", (2, 0), (2, -1), "Helvetica-Bold", 8.5),
        ("BACKGROUND", (0, 0), (0, -1), CABECERA), ("BACKGROUND", (2, 0), (2, -1), CABECERA),
    ]))
    return t


def grafica_linea(valores, limite=None, etiqueta_y="dBA", etiqueta_x="minutos", alto=6 * cm, marcas=()):
    """Serie temporal (un punto por minuto) con línea de límite opcional."""
    d = Drawing(ANCHO, alto)
    izq, der, arriba, abajo = 1.3 * cm, 0.3 * cm, 0.4 * cm, 0.8 * cm
    x0, x1, y0, y1 = izq, ANCHO - der, abajo, alto - arriba
    puntos = [v for v in valores if v is not None]
    if not puntos:
        return d
    vmin = int(min(puntos + ([limite] if limite else [])) // 10 * 10)
    vmax = int(-(-max(puntos + ([limite] if limite else [])) // 10) * 10)
    if vmax - vmin < 20:
        vmax = vmin + 20
    n = max(1, len(valores) - 1)

    def x(i):
        return x0 + (x1 - x0) * i / n

    def y(v):
        return y0 + (y1 - y0) * (v - vmin) / (vmax - vmin)

    for v in range(vmin, vmax + 1, 10):
        d.add(Line(x0, y(v), x1, y(v), strokeColor=GUIA, strokeWidth=0.4))
        d.add(String(x0 - 4, y(v) - 3, str(v), fontSize=7, fontName="Helvetica", textAnchor="end"))
    paso = max(1, round(len(valores) / 8 / 5) * 5) if len(valores) > 10 else 1
    for i in range(0, len(valores), paso):
        d.add(String(x(i), y0 - 10, str(i), fontSize=7, fontName="Helvetica", textAnchor="middle"))
    d.add(String(x1, y0 - 20, etiqueta_x, fontSize=7, fontName="Helvetica", textAnchor="end"))
    d.add(String(2, y1 + 2, etiqueta_y, fontSize=7, fontName="Helvetica"))
    if limite is not None:
        d.add(Line(x0, y(limite), x1, y(limite), strokeColor=colors.black, strokeWidth=0.8, strokeDashArray=[4, 3]))
        d.add(String(x1, y(limite) + 3, f"límite {limite:g}", fontSize=7, fontName="Helvetica", textAnchor="end"))
    for m in marcas:
        xm = x(min(m["min"], n))
        d.add(Line(xm, y0, xm, y1, strokeColor=GRIS, strokeWidth=0.5))
        d.add(String(xm + 2, y1 - 8, m["texto"][:18], fontSize=6, fontName="Helvetica", fillColor=GRIS))
    linea = []
    for i, v in enumerate(valores):
        if v is not None:
            linea += [x(i), y(v)]
    if len(linea) >= 4:
        d.add(PolyLine(linea, strokeColor=colors.black, strokeWidth=1))
    d.add(Rect(x0, y0, x1 - x0, y1 - y0, fillColor=None, strokeColor=colors.black, strokeWidth=0.6))
    return d


def grafica_barras(etiquetas, valores, etiqueta_y, alto=5 * cm, limite=None):
    d = Drawing(ANCHO, alto)
    izq, der, arriba, abajo = 1.3 * cm, 0.3 * cm, 0.4 * cm, 0.8 * cm
    x0, x1, y0, y1 = izq, ANCHO - der, abajo, alto - arriba
    vals = [v or 0 for v in valores]
    tope = max(vals + ([limite] if limite else []) + [1])
    vmin = 0 if etiqueta_y == "%" or not any(vals) else int((min(v for v in vals if v) - 5) // 10 * 10)
    vmax = int(-(-tope // 10) * 10)

    def y(v):
        return y0 + (y1 - y0) * (max(v, vmin) - vmin) / max(1, vmax - vmin)

    for v in range(vmin, vmax + 1, max(10, (vmax - vmin) // 5 // 10 * 10)):
        d.add(Line(x0, y(v), x1, y(v), strokeColor=GUIA, strokeWidth=0.4))
        d.add(String(x0 - 4, y(v) - 3, str(v), fontSize=7, fontName="Helvetica", textAnchor="end"))
    ancho = (x1 - x0) / len(vals)
    for i, (e, v) in enumerate(zip(etiquetas, vals)):
        xb = x0 + i * ancho + ancho * 0.15
        d.add(Rect(xb, y0, ancho * 0.7, y(v) - y0, fillColor=GRIS, strokeColor=colors.black, strokeWidth=0.4))
        d.add(String(xb + ancho * 0.35, y0 - 10, str(e), fontSize=7, fontName="Helvetica", textAnchor="middle"))
        if v:
            d.add(String(xb + ancho * 0.35, y(v) + 2, f"{v:.0f}", fontSize=6.5, fontName="Helvetica",
                         textAnchor="middle"))
    if limite is not None:
        d.add(Line(x0, y(limite), x1, y(limite), strokeColor=colors.black, strokeWidth=0.8, strokeDashArray=[4, 3]))
    d.add(String(2, y1 + 2, etiqueta_y, fontSize=7, fontName="Helvetica"))
    d.add(Rect(x0, y0, x1 - x0, y1 - y0, fillColor=None, strokeColor=colors.black, strokeWidth=0.6))
    return d


def _pie(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(colors.grey)
    canvas.drawString(doc.leftMargin, 1.2 * cm,
                      "Trabajo académico. Medición con celular: no reemplaza un dosímetro IEC 61252 calibrado.")
    canvas.drawRightString(doc.pagesize[0] - doc.rightMargin, 1.2 * cm,
                           f"Generado {datetime.now().strftime('%d/%m/%Y %H:%M')} · Página {doc.page}")
    canvas.restoreState()


def generar_pdf(datos):
    sesion = datos["sesion"]
    modo = sesion.get("modo", "jornada")
    estilos = getSampleStyleSheet()
    titulo = ParagraphStyle("titulo", parent=estilos["Title"], fontSize=16, spaceAfter=2)
    subtitulo = ParagraphStyle("sub", parent=estilos["Normal"], fontSize=9, textColor=colors.grey, alignment=1)
    seccion = ParagraphStyle("sec", parent=estilos["Heading3"], fontSize=11, spaceBefore=8, spaceAfter=3)
    normal = ParagraphStyle("normal", parent=estilos["Normal"], fontSize=9, leading=12)

    parametros = {"ruta": sesion["ruta_datos"], "modo": modo, "criterio": sesion.get("criterio", "res1792"),
                  "limite": sesion.get("limite", 100.0), "ventana_min": sesion.get("ventana_min", 60),
                  "perfil": sesion.get("perfil", "adulto")}
    r = dosis.resumen(parametros)

    e = [Paragraph("Informe de medición de ruido", titulo), Paragraph(MODOS.get(modo, modo), subtitulo)]

    e.append(Paragraph("Datos de la medición", seccion))
    eq = r.get("equipo", {})
    cal = sesion.get("calibracion", {})
    e.append(_pares([
        ("Lugar", Paragraph(_t(sesion.get("lugar")), normal)),
        ("Persona / puesto", Paragraph(_t(sesion.get("persona")), normal)),
        ("Actividad", Paragraph(_t(sesion.get("actividad")), normal)),
        ("Responsable", Paragraph(_t(sesion.get("responsable")), normal)),
        ("Inicio", _fecha(r.get("inicio"))),
        ("Duración", _t(r.get("duracion_texto"))),
        ("Celular", Paragraph(_t(eq.get("dispositivo")), normal)),
        ("Micrófono" if modo != "audifonos" else "Fuente", _t(eq.get("fuente") or "Visualizer (salida)")),
        ("Calibración", Paragraph(_t(cal.get("nombre")), normal)),
        ("Offset", _t(eq.get("offset"), " dB") if eq.get("offset") is not None else "—"),
    ]))

    if not r.get("segundos"):
        e.append(Paragraph("Resultados", seccion))
        e.append(Paragraph(
            "Esta medición no registró ningún segundo de datos: se detuvo antes de completar el primer segundo "
            "o el micrófono no entregó audio. No hay niveles ni dosis que evaluar; repita la medición.", normal))
    elif modo == "audifonos":
        _cuerpo_audifonos(e, r, datos, seccion, normal)
    else:
        _cuerpo_microfono(e, r, sesion, modo, seccion, normal)

    if sesion.get("notas"):
        e.append(Paragraph("Observaciones del evaluador", seccion))
        e.append(Paragraph(_t(sesion["notas"]), normal))

    e.append(Paragraph("Método y limitaciones", seccion))
    for nota in (
        "El celular registra el nivel con ponderación A y C cada segundo (filtros IEC 61672-1 por transformación "
        "bilineal), la constante Fast de 125 ms y el pico C; las bandas de octava usan filtros Butterworth de 4.º orden.",
        "El micrófono de un celular no cumple IEC 61252 ni IEC 61672. Calibrado contra un sonómetro, el error típico "
        "es de ±2 dB; satura cerca de 110–120 dB y pierde sensibilidad en graves.",
    ):
        e.append(Paragraph(f"• {escape(nota)}", normal))
    e.append(Paragraph("• Dosis = 100 % · Σ t<sub>i</sub> / T(L<sub>i</sub>), con T(L) = 8 h / 2<super>(L − Lc)/Q</super>. "
                       "LEX,8h = LAeq,T + 10·log<sub>10</sub>(T / 8 h).", normal))

    doc = SimpleDocTemplate(datos["ruta"], pagesize=letter, leftMargin=1.8 * cm, rightMargin=1.8 * cm,
                            topMargin=1.1 * cm, bottomMargin=1.8 * cm, title="Informe de medición de ruido",
                            author=str(sesion.get("responsable") or ""))
    doc.build(e, onFirstPage=_pie, onLaterPages=_pie)
    return datos["ruta"]


def _cuerpo_microfono(e, r, sesion, modo, seccion, normal):
    crit = r["criterio"]
    e.append(Paragraph("Criterio de evaluación", seccion))
    e.append(Paragraph(
        f"<b>{escape(crit['nombre'])}</b>: nivel de criterio {crit['lc']} dBA en {crit['horas']} h, tasa de "
        f"intercambio {crit['q']} dB, umbral {crit['umbral'] if crit['umbral'] is not None else 'ninguno'}"
        f"{' dBA' if crit['umbral'] is not None else ''}. {escape(crit['nota'])}", normal))

    e.append(Paragraph("Resultados", seccion))
    filas = [
        ["Parámetro", "Valor", "Parámetro", "Valor"],
        ["LAeq,T", _t(r["laeq"], " dBA"), "Dosis medida", _t(r["dosis"], " %")],
        ["LCeq,T", _t(r["lceq"], " dBC"), f"Dosis proyectada {crit['horas']} h", _t(r["dosis_proyectada"], " %")],
        ["LCpico máx.", _t(r["lcpk"], " dBC"), "TWA (8 h)", _t(r["twa"], " dBA")],
        ["LAFmáx / LAFmín", f"{_t(r['lafmax'])} / {_t(r['lafmin'])} dBA", "LEX,8h", _t(r["lex8h"], " dBA")],
        ["L10 / L50 / L90", f"{_t(r['l10'])} / {_t(r['l50'])} / {_t(r['l90'])} dBA", "Lavg (medición)",
         _t(r.get("lavg"), " dBA")],
    ]
    e.append(_tabla(filas, [3.6 * cm, ANCHO / 2 - 3.6 * cm, 4.2 * cm, ANCHO / 2 - 4.2 * cm]))
    e.append(Spacer(1, 4))
    for nota in r["evaluacion"]:
        e.append(Paragraph(f"• {escape(nota)}", normal))

    if modo == "evento":
        e.append(Paragraph(f"LAeq móvil de {r['ventana_min']} min (minuto a minuto)", seccion))
        e.append(grafica_linea(r["movil_por_minuto"], limite=r["limite"], marcas=r.get("marcas", ())))
        e.append(Paragraph(
            f"Máximo del promedio móvil: <b>{_t(r['movil_max'], ' dBA')}</b> · minutos sobre el límite de "
            f"{r['limite']:g} dBA: <b>{r['minutos_sobre_limite']}</b>.", normal))

    e.append(KeepTogether([Paragraph("LAeq por minuto", seccion),
                           grafica_linea([m["laeq"] for m in r["por_minuto"]], limite=crit["lc"],
                                         marcas=r.get("marcas", ()))]))

    if modo == "bandas" and r.get("bandas"):
        centros = [63, 125, 250, 500, "1k", "2k", "4k", "8k"]
        e.append(KeepTogether([
            Paragraph("Espectro por bandas de octava (Leq, sin ponderar)", seccion),
            grafica_barras(centros, r["bandas"], "dB"),
            _tabla([["Hz"] + [str(c) for c in centros], ["Leq dB"] + [_t(v) for v in r["bandas"]]],
                   [2.2 * cm] + [(ANCHO - 2.2 * cm) / 8] * 8),
        ]))
        p = sesion.get("protector") or {}
        if any(p.get(k) not in (None, "") for k in ("snr", "h", "nrr")):
            res = protector.calcular({**p, "la": r["laeq"], "lc": r["lceq"]})
            filas = [["Método", "Cálculo", "Nivel protegido", "EN 458"]]
            for x in res["resultados"]:
                filas.append([Paragraph(escape(x["metodo"]), normal), Paragraph(escape(x["formula"]), normal), _t(x["protegido"], " dBA"),
                              x["clase"]])
            e.append(KeepTogether([
                Paragraph(f"Protector auditivo: {escape(p.get('nombre') or 'sin nombre')}", seccion),
                _tabla(filas, [3.4 * cm, ANCHO - 9.4 * cm, 3 * cm, 3 * cm]),
            ]))

    if len(r["por_hora"]) > 0:
        filas = [["Hora", "Minutos", "LAeq dBA", "LAFmáx dBA", "Dosis %"]]
        for h in r["por_hora"]:
            filas.append([h["hora"], str(h["minutos"]), _t(h["laeq"]), _t(h["lafmax"]), _t(h["dosis"])])
        e.append(KeepTogether([Paragraph("Resultados por hora", seccion), _tabla(filas, [ANCHO / 5] * 5)]))

    if r.get("histograma"):
        hist = r["histograma"]
        total = sum(v for _, v in hist)
        e.append(KeepTogether([
            Paragraph("Distribución de niveles (% del tiempo en cada dB de LA)", seccion),
            grafica_barras([k for k, _ in hist], [100 * v / total for _, v in hist], "%"),
        ]))

    if r.get("marcas"):
        filas = [["Minuto", "Marca"]] + [[_t(m["min"]), Paragraph(escape(m["texto"]), normal)] for m in r["marcas"]]
        e.append(KeepTogether([Paragraph("Marcas", seccion), _tabla(filas, [2.5 * cm, ANCHO - 2.5 * cm])]))


def _cuerpo_audifonos(e, r, datos, seccion, normal):
    ref = r["perfil"]
    e.append(Paragraph("Criterio de evaluación", seccion))
    e.append(Paragraph(
        f"<b>{escape(ref['nombre'])}</b>: {ref['nivel']} dBA durante 40 h a la semana, equivalente a "
        f"{ref['pa2h']} Pa²·h en 7 días (tasa de intercambio 3 dB).", normal))
    e.append(Paragraph("Resultados de esta sesión", seccion))
    e.append(_tabla([
        ["LAeq en el oído", "Nivel máximo (1 s)", "Tiempo escuchando", "Exposición", "% de la semana"],
        [_t(r["laeq"], " dBA"), _t(r["lafmax"], " dBA"), _t(r["duracion_texto"]), f"{r['pa2h']} Pa²·h",
         _t(r["dosis_semanal"], " %")],
    ], [ANCHO / 5] * 5))
    # la semana que termina con esta sesión (así un informe viejo muestra su propia semana)
    sem = dosis.semana({"rutas": datos.get("rutas_semana", []), "perfil": datos["sesion"].get("perfil", "adulto"),
                        "ahora": r.get("fin_t")})
    e.append(Paragraph(f"Últimos 7 días: {_t(sem['dosis'], ' %')} de la dosis semanal", seccion))
    e.append(grafica_barras([d["letra"] for d in sem["dias"]], [d["dosis"] for d in sem["dias"]], "%"))
    if r.get("equipo", {}).get("fuente") == "Salud (iPhone)":
        explicacion = ("El nivel lo calcula el iPhone para cada audífono y lo guarda en la app Salud; la app lee "
                       "esas muestras (llegan con unos minutos de retraso).")
    else:
        explicacion = ("El nivel se estima: RMS digital de la salida de audio más la calibración del audífono medida "
                       "con sonómetro. Solo cuenta el tiempo en que sonó algo por los audífonos.")
    e.append(Paragraph(explicacion, normal))
