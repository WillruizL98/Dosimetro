import Foundation

// Mismos filtros que Filtros.kt (Android), para que ambas versiones midan igual.

/// Sección de segundo orden (forma directa II transpuesta), en doble precisión.
final class Biquad {
    private let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always) func procesar(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Magnitud de la respuesta a la frecuencia f (Hz).
    func magnitud(_ f: Double, _ fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        return hypot(numRe, numIm) / hypot(denRe, denIm)
    }

    func escalar(_ k: Double) -> Biquad { Biquad(b0 * k, b1 * k, b2 * k, a1, a2) }
}

/// Varias secciones en cascada.
final class Cascada {
    private let s: [Biquad]
    init(_ secciones: [Biquad]) { s = secciones }

    @inline(__always) func procesar(_ x: Double) -> Double {
        var y = x
        for b in s { y = b.procesar(y) }
        return y
    }
}

enum Filtros {
    // Polos de las ponderaciones A y C de la IEC 61672-1 (Hz)
    private static let f1 = 20.598997, f2 = 107.65265, f3 = 737.86223, f4 = 12194.217

    /// Polo real analógico en f (Hz) llevado a z con transformación bilineal y prewarp.
    private static func poloDigital(_ f: Double, _ fs: Double) -> Double {
        let w = 2 * fs * tan(Double.pi * f / fs)
        return (2 * fs - w) / (2 * fs + w)
    }

    /// Biquad con dos polos reales y dos ceros en z = cero.
    private static func seccion(_ p1: Double, _ p2: Double, _ cero: Double) -> Biquad {
        Biquad(1, -2 * cero, cero * cero, -(p1 + p2), p1 * p2)
    }

    /// Normaliza la cascada para que tenga 0 dB a 1 kHz.
    private static func normalizar(_ secciones: [Biquad], _ fs: Double) -> Cascada {
        let g = secciones.reduce(1.0) { $0 * $1.magnitud(1000, fs) }
        return Cascada([secciones[0].escalar(1 / g)] + secciones.dropFirst())
    }

    static func ponderacionA(_ fs: Double) -> Cascada {
        let p1 = poloDigital(f1, fs), p2 = poloDigital(f2, fs)
        let p3 = poloDigital(f3, fs), p4 = poloDigital(f4, fs)
        return normalizar([seccion(p1, p1, 1), seccion(p2, p3, 1), seccion(p4, p4, -1)], fs)
    }

    static func ponderacionC(_ fs: Double) -> Cascada {
        let p1 = poloDigital(f1, fs), p4 = poloDigital(f4, fs)
        return normalizar([seccion(p1, p1, 1), seccion(p4, p4, -1)], fs)
    }

    private static func pasaBajos(_ f: Double, _ q: Double, _ fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    private static func pasaAltos(_ f: Double, _ q: Double, _ fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    static let centrosOctava = [63, 125, 250, 500, 1000, 2000, 4000, 8000]

    /// Bandas de octava: pasa-altos y pasa-bajos Butterworth de 4.º orden en fc/√2 y fc·√2.
    static func bandasOctava(_ fs: Double) -> [Cascada] {
        let qs = [0.5411961, 1.3065630]
        return (-4...3).map { k in
            let fc = 1000 * pow(2, Double(k))
            let bajo = fc / 2.0.squareRoot()
            let alto = min(fc * 2.0.squareRoot(), fs * 0.45)
            return Cascada(qs.map { pasaAltos(bajo, $0, fs) } + qs.map { pasaBajos(alto, $0, fs) })
        }
    }
}
