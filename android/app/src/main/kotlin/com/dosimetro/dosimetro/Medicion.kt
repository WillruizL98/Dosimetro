package com.dosimetro.dosimetro

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.Visualizer
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** Nivel en dB de una energía media (presión² relativa a escala completa). */
internal fun db(energia: Double): Double = 10 * log10(max(energia, 1e-20))

/**
 * Estado compartido de la medición en curso. El servicio la mantiene viva;
 * la actividad la consulta y recibe los niveles en vivo.
 */
object Medicion {
    /** Nivel instantáneo para la pantalla (≈8 veces por segundo). */
    var oyente: ((Map<String, Any?>) -> Unit)? = null

    private var motor: Motor? = null
    var config: JSONObject? = null
        private set
    var error: String? = null
        private set

    val activa get() = motor != null

    fun arrancar(contexto: Context, cfg: JSONObject) {
        detener()
        error = null
        config = cfg
        motor = if (cfg.getString("modo") == "audifonos") MotorAudifonos(contexto, cfg) else MotorMicrofono(contexto, cfg)
        motor!!.iniciar()
    }

    fun detener() {
        motor?.terminar()
        motor = null
    }

    fun pausar(pausa: Boolean) { motor?.pausado = pausa }
    fun marcar(texto: String) { motor?.marca(texto) }

    fun estado(): Map<String, Any?> = mapOf(
        "activa" to activa,
        "pausada" to (motor?.pausado ?: false),
        "config" to config?.toString(),
        "segundos" to (motor?.segundos ?: 0),
        "error" to error,
    )

    internal fun fallo(mensaje: String) {
        error = mensaje
        oyente?.invoke(mapOf("error" to mensaje))
    }

    internal fun emitir(datos: Map<String, Any?>) { oyente?.invoke(datos) }
}

/** Base de los dos motores: escribe un registro JSON por línea en el archivo de la sesión. */
abstract class Motor(protected val cfg: JSONObject) {
    @Volatile var pausado = false
    @Volatile protected var corriendo = false
    @Volatile var segundos = 0
        protected set
    private val archivo = File(cfg.getString("ruta"))
    private var escritor: BufferedWriter? = null

    protected fun abrir(cabecera: JSONObject) {
        archivo.parentFile?.mkdirs()
        val nuevo = !archivo.exists() || archivo.length() == 0L
        escritor = BufferedWriter(FileWriter(archivo, true))
        if (nuevo) escribir(cabecera)
    }

    @Synchronized protected fun escribir(o: JSONObject) {
        escritor?.apply { write(o.toString()); newLine(); flush() }
    }

    fun marca(texto: String) {
        escribir(JSONObject().put("t", System.currentTimeMillis() / 1000.0).put("marca", texto))
    }

    protected fun cerrar() {
        synchronized(this) { escritor?.close(); escritor = null }
    }

    abstract fun iniciar()
    open fun terminar() { corriendo = false }
}

/** Mide con el micrófono: LAeq, LCeq, LZeq, LAF máx/mín, LCpico y 8 bandas de octava por segundo. */
class MotorMicrofono(private val contexto: Context, cfg: JSONObject) : Motor(cfg) {
    private val fs = 48000
    private val offset = cfg.optDouble("offset", 112.35)
    private var hilo: Thread? = null

    @SuppressLint("MissingPermission")
    override fun iniciar() {
        val audio = contexto.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val sinProcesar = audio.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        val fuente = if (sinProcesar) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        val minimo = AudioRecord.getMinBufferSize(fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val grabador = try {
            AudioRecord(fuente, fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT, max(minimo, fs) * 4)
        } catch (e: Exception) {
            Medicion.fallo("No se pudo abrir el micrófono: ${e.message}"); return
        }
        if (grabador.state != AudioRecord.STATE_INITIALIZED) {
            grabador.release(); Medicion.fallo("El micrófono está ocupado por otra app"); return
        }
        abrir(
            JSONObject()
                .put("tipo", "cabecera").put("modo", cfg.getString("modo"))
                .put("inicio", System.currentTimeMillis() / 1000.0)
                .put("offset", offset).put("fs", fs)
                .put("fuente", if (sinProcesar) "UNPROCESSED" else "VOICE_RECOGNITION")
                .put("dispositivo", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("bandas", JSONArray(Filtros.CENTROS_OCTAVA.toList()))
        )
        corriendo = true
        hilo = thread(name = "medicion", priority = Thread.MAX_PRIORITY) { bucle(grabador) }
    }

    private fun bucle(grabador: AudioRecord) {
        val filtroA = Filtros.ponderacionA(fs.toDouble())
        val filtroC = Filtros.ponderacionC(fs.toDouble())
        val bandas = Filtros.bandasOctava(fs.toDouble())
        val bloque = FloatArray(fs / 8) // 125 ms
        val alfa = 1 - Math.exp(-1.0 / (0.125 * fs)) // constante Fast (125 ms)
        var rapidoA = 0.0
        // acumuladores del segundo en curso
        var sA = 0.0; var sC = 0.0; var sZ = 0.0; var picoC = 0.0
        var maxF = Double.NEGATIVE_INFINITY; var minF = Double.POSITIVE_INFINITY
        val sB = DoubleArray(bandas.size)
        var n = 0; var bloques = 0
        // descarta el primer medio segundo: el filtro y el micrófono se están asentando
        var descartar = 4

        grabador.startRecording()
        try {
            while (corriendo) {
                val leidos = grabador.read(bloque, 0, bloque.size, AudioRecord.READ_BLOCKING)
                if (leidos <= 0) continue
                for (i in 0 until leidos) {
                    val x = bloque[i].toDouble()
                    val a = filtroA.procesar(x)
                    val c = filtroC.procesar(x)
                    rapidoA += alfa * (a * a - rapidoA)
                    sA += a * a; sC += c * c; sZ += x * x
                    if (abs(c) > picoC) picoC = abs(c)
                    for (b in bandas.indices) { val y = bandas[b].procesar(x); sB[b] += y * y }
                }
                n += leidos
                val laf = db(rapidoA) + offset
                if (descartar > 0) {
                    descartar--
                    sA = 0.0; sC = 0.0; sZ = 0.0; picoC = 0.0; sB.fill(0.0); n = 0
                    continue
                }
                maxF = max(maxF, laf); minF = min(minF, laf)
                bloques++
                Medicion.emitir(mapOf("laf" to laf, "pausada" to pausado, "segundos" to segundos))
                if (bloques == 8) {
                    if (!pausado) {
                        val r = JSONObject()
                            .put("t", System.currentTimeMillis() / 1000.0)
                            .put("la", red(db(sA / n) + offset))
                            .put("lc", red(db(sC / n) + offset))
                            .put("lz", red(db(sZ / n) + offset))
                            .put("lafmax", red(maxF)).put("lafmin", red(minF))
                            .put("lcpk", red(20 * log10(max(picoC, 1e-10)) + offset))
                            .put("b", JSONArray(sB.map { red(db(it / n) + offset) }))
                        escribir(r)
                        segundos++
                        Medicion.emitir(mapOf("registro" to r.toString()))
                    }
                    sA = 0.0; sC = 0.0; sZ = 0.0; picoC = 0.0; sB.fill(0.0); n = 0; bloques = 0
                    maxF = Double.NEGATIVE_INFINITY; minF = Double.POSITIVE_INFINITY
                }
            }
        } catch (e: Exception) {
            Medicion.fallo("La medición se detuvo: ${e.message}")
        } finally {
            grabador.stop(); grabador.release(); cerrar()
        }
    }

    override fun terminar() {
        super.terminar()
        hilo?.join(1000)
    }
}

/**
 * Modo audífonos: lee el nivel RMS de lo que suena en el teléfono (Visualizer de la
 * mezcla de salida) y lo convierte a dB SPL en el oído con la calibración del audífono.
 */
class MotorAudifonos(private val contexto: Context, cfg: JSONObject) : Motor(cfg) {
    private val offset = cfg.optDouble("offset", 100.0)
    private val sigueVolumen = cfg.optBoolean("sigue_volumen", true)
    private val volumenCal = cfg.optInt("volumen_cal", -1)
    private var hilo: Thread? = null
    private var contador = 0

    override fun iniciar() {
        val vis = try {
            Visualizer(0).apply {
                measurementMode = Visualizer.MEASUREMENT_MODE_PEAK_RMS
                scalingMode = Visualizer.SCALING_MODE_AS_PLAYED
                enabled = true
            }
        } catch (e: Exception) {
            Medicion.fallo("Este celular no deja leer el audio de salida (${e.message})."); return
        }
        abrir(
            JSONObject()
                .put("tipo", "cabecera").put("modo", "audifonos")
                .put("inicio", System.currentTimeMillis() / 1000.0)
                .put("offset", offset).put("sigue_volumen", sigueVolumen)
                .put("dispositivo", "${Build.MANUFACTURER} ${Build.MODEL}")
        )
        corriendo = true
        hilo = thread(name = "audifonos") { bucle(vis) }
    }

    private fun bucle(vis: Visualizer) {
        val audio = contexto.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val medida = Visualizer.MeasurementPeakRms()
        var energia = 0.0; var muestras = 0
        try {
            while (corriendo) {
                Thread.sleep(125)
                vis.getMeasurementPeakRms(medida)
                // mRms en milibeles (dBFS × 100); -9600 es silencio
                val rms = medida.mRms / 100.0
                val tipo = salidaAudifonos(audio)
                val nivel = if (tipo != null && rms > -70) rms + offset + correccionVolumen(audio, tipo) else null
                if (nivel != null) { energia += 10.0.pow(nivel / 10); muestras++ }
                Medicion.emitir(mapOf("laf" to nivel, "audifono" to tipo, "segundos" to segundos))
                if (++contador % 8 == 0) {
                    // solo cuenta el tiempo en que de verdad sonó algo por los audífonos
                    if (!pausado && muestras >= 4) {
                        val r = JSONObject()
                            .put("t", System.currentTimeMillis() / 1000.0)
                            .put("la", red(db(energia / muestras)))
                            .put("vol", audio.getStreamVolume(AudioManager.STREAM_MUSIC))
                            .put("aud", tipo ?: "")
                        escribir(r)
                        segundos++
                        Medicion.emitir(mapOf("registro" to r.toString()))
                    }
                    energia = 0.0; muestras = 0
                }
            }
        } catch (e: Exception) {
            Medicion.fallo("La medición se detuvo: ${e.message}")
        } finally {
            vis.enabled = false; vis.release(); cerrar()
        }
    }

    /** Si el Visualizer no refleja el volumen, se suma la diferencia de volumen en dB. */
    private fun correccionVolumen(audio: AudioManager, tipo: String): Double {
        if (sigueVolumen || volumenCal < 0 || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return 0.0
        val dispositivo = if (tipo == "bluetooth") AudioDeviceInfo.TYPE_BLUETOOTH_A2DP else AudioDeviceInfo.TYPE_WIRED_HEADPHONES
        val ahora = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (audio.getStreamVolumeDb(AudioManager.STREAM_MUSIC, ahora, dispositivo) -
            audio.getStreamVolumeDb(AudioManager.STREAM_MUSIC, volumenCal, dispositivo)).toDouble()
    }

    override fun terminar() {
        super.terminar()
        hilo?.join(1000)
    }
}

/** Tipo de audífono por el que sale el sonido ahora, o null si suena por el parlante. */
fun salidaAudifonos(audio: AudioManager): String? {
    val tipos = mutableMapOf(
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES to "cable",
        AudioDeviceInfo.TYPE_WIRED_HEADSET to "cable",
        AudioDeviceInfo.TYPE_USB_HEADSET to "usb",
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP to "bluetooth",
    )
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) tipos[AudioDeviceInfo.TYPE_BLE_HEADSET] = "bluetooth"
    return audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type in tipos }?.let { tipos[it.type] }
}

/** Redondea a 0.1 dB para que el archivo sea liviano. */
internal fun red(v: Double): Double = Math.round(v * 10) / 10.0
