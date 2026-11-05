package com.dosimetro.dosimetro

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val hiloPython = Executors.newSingleThreadExecutor()
    private val hiloCalibracion = Executors.newSingleThreadExecutor()
    private val principal = Handler(Looper.getMainLooper())
    private lateinit var calibrador: Calibrador
    private var permisosPendientes: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        calibrador = Calibrador(applicationContext)
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mensajero = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(mensajero, "dosimetro/medicion").setMethodCallHandler { llamada, resultado ->
            when (llamada.method) {
                "iniciar" -> {
                    ServicioMedicion.iniciar(this, JSONObject(llamada.argument<String>("cfg")!!))
                    resultado.success(null)
                }
                "detener" -> {
                    ServicioMedicion.detener(this)
                    resultado.success(null)
                }
                "pausar" -> {
                    Medicion.pausar(llamada.argument<Boolean>("pausa") ?: false)
                    resultado.success(null)
                }
                "marcar" -> {
                    Medicion.marcar(llamada.argument<String>("texto") ?: "")
                    resultado.success(null)
                }
                "estado" -> resultado.success(Medicion.estado())
                "audifono" -> resultado.success(salidaAudifonos(audio))
                "volumen" -> resultado.success(
                    mapOf(
                        "actual" to audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                        "maximo" to audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                    )
                )
                else -> resultado.notImplemented()
            }
        }

        EventChannel(mensajero, "dosimetro/niveles").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(argumentos: Any?, eventos: EventChannel.EventSink) {
                Medicion.oyente = { datos -> principal.post { eventos.success(datos) } }
            }

            override fun onCancel(argumentos: Any?) {
                Medicion.oyente = null
            }
        })

        MethodChannel(mensajero, "dosimetro/calibracion").setMethodCallHandler { llamada, resultado ->
            // Las mediciones de calibración bloquean unos segundos: van en otro hilo.
            fun enHilo(trabajo: () -> Any?) = hiloCalibracion.execute {
                try {
                    val r = trabajo()
                    principal.post { resultado.success(r) }
                } catch (e: Exception) {
                    principal.post { resultado.error("CALIBRACION", e.message, null) }
                }
            }
            when (llamada.method) {
                "medirMicrofono" -> enHilo { calibrador.medirMicrofono(llamada.argument<Int>("segundos") ?: 10) }
                "tono" -> { calibrador.tono(); resultado.success(null) }
                "detenerTono" -> { calibrador.detenerTono(); resultado.success(null) }
                "medirAudifono" -> enHilo { calibrador.medirAudifono() }
                else -> resultado.notImplemented()
            }
        }

        MethodChannel(mensajero, "dosimetro/python").setMethodCallHandler { llamada, resultado ->
            val modulo = llamada.argument<String>("modulo")!!
            val funcion = llamada.argument<String>("funcion")!!
            val datos = llamada.argument<String>("datos") ?: "null"
            // Python corre en un hilo aparte para no congelar la interfaz.
            hiloPython.execute {
                try {
                    if (!Python.isStarted()) Python.start(AndroidPlatform(applicationContext))
                    val respuesta = Python.getInstance().getModule("puente")
                        .callAttr("llamar", modulo, funcion, datos).toString()
                    principal.post { resultado.success(respuesta) }
                } catch (e: Exception) {
                    principal.post { resultado.error("PYTHON", e.message, null) }
                }
            }
        }

        MethodChannel(mensajero, "dosimetro/sistema").setMethodCallHandler { llamada, resultado ->
            when (llamada.method) {
                "directorio" -> resultado.success(filesDir.absolutePath)
                "permisos" -> pedirPermisos(resultado)
                "compartir", "abrir" -> {
                    val archivo = File(llamada.argument<String>("ruta")!!)
                    val tipo = llamada.argument<String>("tipo") ?: "application/octet-stream"
                    val uri = FileProvider.getUriForFile(this, "$packageName.archivos", archivo)
                    val intencion = if (llamada.method == "compartir") {
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND).apply {
                                type = tipo
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            },
                            "Compartir"
                        )
                    } else {
                        Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, tipo)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                    }
                    try {
                        startActivity(intencion)
                        resultado.success(true)
                    } catch (e: ActivityNotFoundException) {
                        resultado.error("SIN_APP", "No hay una aplicación para abrir este archivo", null)
                    }
                }
                else -> resultado.notImplemented()
            }
        }
    }

    /** Micrófono (obligatorio) y notificaciones (para ver la medición en curso). */
    private fun pedirPermisos(resultado: MethodChannel.Result) {
        val faltan = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) faltan += Manifest.permission.POST_NOTIFICATIONS
        faltan.removeAll { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        if (faltan.isEmpty()) {
            resultado.success(true)
            return
        }
        permisosPendientes = resultado
        requestPermissions(faltan.toTypedArray(), 7)
    }

    override fun onRequestPermissionsResult(codigo: Int, permisos: Array<out String>, concedidos: IntArray) {
        super.onRequestPermissionsResult(codigo, permisos, concedidos)
        if (codigo != 7) return
        permisosPendientes?.success(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
        permisosPendientes = null
    }

    override fun onDestroy() {
        calibrador.detenerTono()
        Medicion.oyente = null
        super.onDestroy()
    }
}
