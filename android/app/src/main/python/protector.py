"""Nivel efectivo con protector auditivo (EN 458 / ISO 4869-2 y NRR de OSHA)."""

NIVEL_ACCION = 85.0  # EN 458 evalúa la protección respecto al nivel de acción


def hml_pnr(la, lc, h, m, l):
    """Reducción prevista del nivel (PNR) con el método HML."""
    dif = lc - la
    if dif <= 2:
        return m - (h - m) / 4 * (dif - 2)
    return m - (m - l) / 8 * (dif - 2)


def valoracion(protegido, accion=NIVEL_ACCION):
    """Clasificación de la EN 458 según el nivel que queda dentro del protector."""
    if protegido >= accion:
        return "insuficiente", "El nivel protegido sigue por encima del nivel de acción."
    if protegido >= accion - 5:
        return "aceptable", "Protege, pero con poco margen."
    if protegido >= accion - 10:
        return "buena", "Nivel protegido entre 75 y 80 dBA: la zona recomendada."
    if protegido >= accion - 15:
        return "aceptable", "Protege con margen; aún permite oír la comunicación."
    return "sobreprotección", "Atenúa de más: aísla al trabajador y dificulta oír alarmas y voces."


def calcular(datos):
    """datos: la, lc y los valores del empaque (snr, h/m/l y/o nrr). Devuelve cada método disponible."""
    la, lc = float(datos["la"]), float(datos["lc"])
    resultados = []

    def agregar(metodo, formula, protegido):
        clase, texto = valoracion(protegido)
        resultados.append({
            "metodo": metodo, "formula": formula,
            "protegido": round(protegido, 1), "clase": clase, "texto": texto,
        })

    if datos.get("snr") not in (None, ""):
        snr = float(datos["snr"])
        agregar("SNR", f"L'A = LC − SNR = {lc:.1f} − {snr:.0f}", lc - snr)
    if all(datos.get(k) not in (None, "") for k in ("h", "m", "l")):
        h, m, l = float(datos["h"]), float(datos["m"]), float(datos["l"])
        pnr = hml_pnr(la, lc, h, m, l)
        agregar("HML", f"PNR = {pnr:.1f} dB con LC − LA = {lc - la:.1f} → L'A = LA − PNR", la - pnr)
    if datos.get("nrr") not in (None, ""):
        nrr = float(datos["nrr"])
        agregar("NRR (OSHA, con 50 %)", f"L'A = LA − (NRR − 7) / 2 = {la:.1f} − ({nrr:.0f} − 7) / 2",
                la - (nrr - 7) / 2)
    return {"la": la, "lc": lc, "resultados": resultados}
