package com.dosimetro.dosimetro

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.Visualizer
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/** Mediciones cortas para calibrar el micrófono y los audífonos. */
class Calibrador(private val contexto: Context) {
    private val audio = contexto.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    @Volatile private var sonando = false
    private var hiloTono: Thread? = null

    /** LAeq y LZeq en dBFS (sin offset) durante [segundos]. Bloquea: llamar fuera del hilo principal. */
    @SuppressLint("MissingPermission")
    fun medirMicrofono(segundos: Int): Map<String, Double> {
        val fs = 48000
        val sinProcesar = audio.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        val fuente = if (sinProcesar) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        val minimo = AudioRecord.getMinBufferSize(fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val grabador = AudioRecord(fuente, fs, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT, max(minimo, fs) * 4)
        check(grabador.state == AudioRecord.STATE_INITIALIZED) { "El micrófono está ocupado por otra app" }
        val filtroA = Filtros.ponderacionA(fs.toDouble())
        val bloque = FloatArray(fs / 8)
        var sA = 0.0; var sZ = 0.0; var n = 0
        grabador.startRecording()
        try {
            repeat(4) { grabador.read(bloque, 0, bloque.size, AudioRecord.READ_BLOCKING) } // asentamiento
            repeat(segundos * 8) {
                val leidos = grabador.read(bloque, 0, bloque.size, AudioRecord.READ_BLOCKING)
                for (i in 0 until leidos) {
                    val x = bloque[i].toDouble(); val a = filtroA.procesar(x)
                    sA += a * a; sZ += x * x
                }
                n += max(leidos, 0)
            }
        } finally {
            grabador.stop(); grabador.release()
        }
        return mapOf("la_dbfs" to db(sA / n), "lz_dbfs" to db(sZ / n))
    }

    /** Tono de 1 kHz a −20 dBFS RMS por los audífonos, hasta llamar a [detenerTono]. */
    fun tono() {
        detenerTono()
        val fs = 48000
        val amplitud = 0.1 * sqrt(2.0) // −20 dBFS RMS
        val pista = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(fs).setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        sonando = true
        hiloTono = thread(name = "tono") {
            // 48 ciclos exactos de 1 kHz por bloque: el bloque se repite sin saltos
            val bloque = FloatArray(fs / 1000 * 48 * 2)
            for (i in 0 until bloque.size / 2) {
                val v = (amplitud * sin(2 * PI * 1000 * i / fs)).toFloat()
                bloque[2 * i] = v; bloque[2 * i + 1] = v
            }
            pista.play()
            while (sonando) pista.write(bloque, 0, bloque.size, AudioTrack.WRITE_BLOCKING)
            pista.stop(); pista.release()
        }
    }

    fun detenerTono() {
        sonando = false
        hiloTono?.join(500)
        hiloTono = null
    }

    /**
     * Con el tono sonando: lee el RMS del Visualizer al volumen actual y comprueba si
     * el Visualizer sigue el volumen (bajando 3 pasos un momento).
     */
    fun medirAudifono(): Map<String, Any?> {
        val vis = Visualizer(0).apply {
            measurementMode = Visualizer.MEASUREMENT_MODE_PEAK_RMS
            scalingMode = Visualizer.SCALING_MODE_AS_PLAYED
            enabled = true
        }
        val medida = Visualizer.MeasurementPeakRms()
        fun promedio(): Double {
            Thread.sleep(400)
            var suma = 0.0
            repeat(8) { Thread.sleep(125); vis.getMeasurementPeakRms(medida); suma += medida.mRms / 100.0 }
            return suma / 8
        }
        val volumen = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        try {
            val referencia = promedio()
            check(referencia > -70) { "No se detecta el tono. ¿Está sonando por los audífonos?" }
            var sigue = true
            if (volumen >= 4) {
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, volumen - 3, 0)
                val bajo = promedio()
                sigue = referencia - bajo > 2
            }
            return mapOf("rms_dbfs" to referencia, "sigue_volumen" to sigue, "volumen" to volumen,
                "audifono" to salidaAudifonos(audio))
        } finally {
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, volumen, 0)
            vis.enabled = false; vis.release()
        }
    }
}
