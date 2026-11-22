package `is`.loria.heild.walk

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.IBinder
import android.os.Looper
import `is`.loria.heild.EngineHolder
import `is`.loria.heild.MainActivity
import `is`.loria.heild.R

/**
 * `location` foreground service that runs from Start to Stop on the Walks tab and hands
 * every GPS fix to [onFix] (the [WalkBridge]), so a walk is recorded with the screen off.
 *
 * Separate from [is.loria.heild.service.HeildService] on purpose: that one is stopped by
 * Dart after every sensor sync (`serviceIdle`), and a walk must outlive any number of them.
 *
 * Uses Android's own [LocationManager] with the GPS provider, one fix a second; no Google
 * Play Services. Always started from the visible app, so the while-in-use location
 * permission is enough.
 */
class WalkService : Service(), LocationListener {

    companion object {
        const val CHANNEL_ID = "heild.walk"
        const val NOTIFICATION_ID = 2
        const val INTERVAL_MS = 1000L

        @Volatile
        var instance: WalkService? = null
            private set

        /** Receives every fix on the main thread. */
        @Volatile
        var onFix: ((Location) -> Unit)? = null

        /**
         * A walk is being recorded. Cleared by [stop], also when the service has not been
         * created yet: it then stops itself as soon as it has started.
         */
        @Volatile
        var wanted = false
            private set

        fun start(context: Context) {
            wanted = true
            context.startForegroundService(Intent(context, WalkService::class.java))
        }

        fun stop() {
            wanted = false
            instance?.end()
        }
    }

    private var listening = false

    override fun onCreate() {
        super.onCreate()
        instance = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Walk recording", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while heild records a walk with GPS"
                setShowBadge(false)
            },
        )
    }

    @SuppressLint("MissingPermission") // WalkBridge checks it before starting the service.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        EngineHolder.ensure(this)
        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
            if (!wanted) {
                end()
            } else if (!listening) {
                getSystemService(LocationManager::class.java).requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    INTERVAL_MS,
                    0f,
                    this,
                    Looper.getMainLooper(),
                )
                listening = true
            }
        } catch (e: SecurityException) {
            // The permission was taken away between the check and here.
            end()
        }
        return START_NOT_STICKY
    }

    override fun onLocationChanged(location: Location) {
        onFix?.invoke(location)
    }

    private fun end() {
        if (listening) {
            getSystemService(LocationManager::class.java).removeUpdates(this)
            listening = false
        }
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
            .setContentTitle("heild · recording walk")
            .setContentText("Open heild and press Stop when the walk is over")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    override fun onDestroy() {
        if (listening) {
            getSystemService(LocationManager::class.java).removeUpdates(this)
            listening = false
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
