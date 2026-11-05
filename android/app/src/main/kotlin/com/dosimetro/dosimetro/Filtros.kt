package com.dosimetro.dosimetro

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/** Sección de segundo orden (forma directa II transpuesta), en doble precisión. */
class Biquad(
    private val b0: Double, private val b1: Double, private val b2: Double,
    private val a1: Double, private val a2: Double,
) {
    private var z1 = 0.0
    private var z2 = 0.0

    fun procesar(x: Double): Double {
        val y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /** Magnitud de la respuesta a la frecuencia f (Hz). */
    fun magnitud(f: Double, fs: Double): Double {
        val w = 2 * PI * f / fs
        val c1 = cos(w); val s1 = sin(w); val c2 = cos(2 * w); val s2 = sin(2 * w)
        val numRe = b0 + b1 * c1 + b2 * c2
        val numIm = -(b1 * s1 + b2 * s2)
        val denRe = 1 + a1 * c1 + a2 * c2
        val denIm = -(a1 * s1 + a2 * s2)
        return hypot(numRe, numIm) / hypot(denRe, denIm)
    }

    fun escalar(k: Double) = Biquad(b0 * k, b1 * k, b2 * k, a1, a2)
}

/** Varias secciones en cascada. */
class Cascada(secciones: List<Biquad>) {
    private val s = secciones.toTypedArray()

    fun procesar(x: Double): Double {
        var y = x
        for (b in s) y = b.procesar(y)
        return y
    }
}

object Filtros {
    // Polos de las ponderaciones A y C de la IEC 61672-1 (Hz)
    private const val F1 = 20.598997
    private const val F2 = 107.65265
    private const val F3 = 737.86223
    private const val F4 = 12194.217

    /** Polo real analógico en f (Hz) llevado a z con transformación bilineal y prewarp. */
    private fun poloDigital(f: Double, fs: Double): Double {
        val w = 2 * fs * tan(PI * f / fs) // frecuencia prewarpeada (rad/s)
        return (2 * fs - w) / (2 * fs + w)
    }

    /** Biquad con dos polos reales p1, p2 y ceros en z = cero (dos veces). */
    private fun seccion(p1: Double, p2: Double, cero: Double): Biquad =
        Biquad(1.0, -2 * cero, cero * cero, -(p1 + p2), p1 * p2)

    /** Normaliza la cascada para que tenga 0 dB a 1 kHz. */
    private fun normalizar(secciones: List<Biquad>, fs: Double): Cascada {
        val g = secciones.fold(1.0) { acc, b -> acc * b.magnitud(1000.0, fs) }
        return Cascada(listOf(secciones[0].escalar(1 / g)) + secciones.drop(1))
    }

    /** Ponderación A: s⁴ / ((s+ω1)² (s+ω2)(s+ω3)(s+ω4)²). */
    fun ponderacionA(fs: Double): Cascada {
        val p1 = poloDigital(F1, fs); val p2 = poloDigital(F2, fs)
        val p3 = poloDigital(F3, fs); val p4 = poloDigital(F4, fs)
        return normalizar(
            listOf(
                seccion(p1, p1, 1.0),  // pasa-altos doble en 20.6 Hz
                seccion(p2, p3, 1.0),  // pasa-altos en 107.7 y 737.9 Hz
                seccion(p4, p4, -1.0), // pasa-bajos doble en 12.2 kHz
            ),
            fs,
        )
    }

    /** Ponderación C: s² / ((s+ω1)² (s+ω4)²). */
    fun ponderacionC(fs: Double): Cascada {
        val p1 = poloDigital(F1, fs); val p4 = poloDigital(F4, fs)
        return normalizar(listOf(seccion(p1, p1, 1.0), seccion(p4, p4, -1.0)), fs)
    }

    /** Pasa-bajos y pasa-altos de segundo orden (fórmulas RBJ). */
    private fun pasaBajos(f: Double, q: Double, fs: Double): Biquad {
        val w = 2 * PI * f / fs; val al = sin(w) / (2 * q); val c = cos(w); val a0 = 1 + al
        return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    private fun pasaAltos(f: Double, q: Double, fs: Double): Biquad {
        val w = 2 * PI * f / fs; val al = sin(w) / (2 * q); val c = cos(w); val a0 = 1 + al
        return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    /** Centros nominales de las bandas de octava que muestra la app. */
    val CENTROS_OCTAVA = intArrayOf(63, 125, 250, 500, 1000, 2000, 4000, 8000)

    /**
     * Filtro de banda de octava: pasa-altos y pasa-bajos Butterworth de 4.º orden
     * en los bordes fc/√2 y fc·√2 (centros exactos en base 2: 1000·2^k).
     */
    fun bandasOctava(fs: Double): List<Cascada> {
        val qs = doubleArrayOf(0.5411961, 1.3065630) // Butterworth de 4.º orden
        return (-4..3).map { k ->
            val fc = 1000.0 * Math.pow(2.0, k.toDouble())
            val f1 = fc / sqrt(2.0)
            val f2 = minOf(fc * sqrt(2.0), fs * 0.45)
            Cascada(qs.map { pasaAltos(f1, it, fs) } + qs.map { pasaBajos(f2, it, fs) })
        }
    }
}
