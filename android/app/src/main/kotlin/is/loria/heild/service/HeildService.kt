package `is`.loria.heild.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import `is`.loria.heild.EngineHolder
import `is`.loria.heild.MainActivity
import `is`.loria.heild.R

/**
 * `connectedDevice` foreground service that keeps the process (and so the Dart sync) alive
 * while heild talks to the sensor. Started by [DevicePresenceService] when the sensor comes
 * into range and by Dart (`serviceStart`) when the user connects; Dart stops it
 * (`serviceIdle`) once disconnected with nothing pending. The notification text is set by
 * Dart through `serviceNotification`.
 */
class HeildService : Service() {

    companion object {
        const val CHANNEL_ID = "heild.sync"
        const val NOTIFICATION_ID = 1

        @Volatile
        var instance: HeildService? = null
            private set

        fun start(context: Context) {
            context.startForegroundService(Intent(context, HeildService::class.java))
        }
    }

    private var title = "heild"
    private var text = "Connecting to the sensor…"

    override fun onCreate() {
        super.onCreate()
        instance = this
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Sensor sync", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while heild is connected to the Polar sensor"
                setShowBadge(false)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        EngineHolder.ensure(this)
        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        return START_STICKY
    }

    fun updateNotification(title: String, text: String) {
        this.title = title
        this.text = text
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
    }

    fun stop() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
