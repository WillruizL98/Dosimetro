package com.dosimetro.dosimetro

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import org.json.JSONObject

/** Servicio en primer plano: mantiene el micrófono abierto con la pantalla apagada. */
class ServicioMedicion : Service() {
    private var bloqueo: PowerManager.WakeLock? = null

    companion object {
        private const val CANAL = "medicion"
        private const val ID = 1

        fun iniciar(contexto: Context, cfg: JSONObject) {
            val intencion = Intent(contexto, ServicioMedicion::class.java).putExtra("cfg", cfg.toString())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) contexto.startForegroundService(intencion)
            else contexto.startService(intencion)
        }

        fun detener(contexto: Context) {
            Medicion.detener()
            contexto.stopService(Intent(contexto, ServicioMedicion::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val cfg = JSONObject(intent?.getStringExtra("cfg") ?: return START_NOT_STICKY)
        val notificacion = crearNotificacion(cfg.optString("titulo", "Midiendo ruido"))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // también en modo audífonos: el Visualizer usa el permiso de grabación
            startForeground(ID, notificacion, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(ID, notificacion)
        }
        bloqueo = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dosimetro:medicion")
            .apply { acquire(12 * 60 * 60 * 1000L) } // máximo 12 h
        Medicion.arrancar(applicationContext, cfg)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Medicion.detener()
        bloqueo?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun crearNotificacion(texto: String): Notification {
        val gestor = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            gestor.createNotificationChannel(
                NotificationChannel(CANAL, "Medición en curso", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val abrir = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val constructor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CANAL)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return constructor
            .setContentTitle("Dosímetro")
            .setContentText(texto)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(abrir)
            .build()
    }
}
