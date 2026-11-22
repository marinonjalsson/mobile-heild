package `is`.loria.heild.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import `is`.loria.heild.MainActivity
import `is`.loria.heild.R
import java.time.LocalTime

/**
 * The one notification that asks for the wearer's attention: the sensor is not recording and
 * the app could not put that right by itself. Two channels of its own, apart from the
 * foreground-service one: by day the audible one, at night ([NIGHT_FROM]–[NIGHT_TO], phone
 * time) a silent one, so it waits in the shade until morning without waking anyone. Dart shows
 * and clears it (`alert`, `alertClear`); a tap opens the app.
 */
object Alert {
    private const val CHANNEL_ID = "heild.alert"
    private const val QUIET_CHANNEL_ID = "heild.alert.quiet"

    /** Night hours (hour of day, phone time): from 22:00 until 08:00. */
    private const val NIGHT_FROM = 22
    private const val NIGHT_TO = 8

    private fun isNight(): Boolean {
        val h = LocalTime.now().hour
        return h >= NIGHT_FROM || h < NIGHT_TO
    }
    private const val NOTIFICATION_ID = 4212

    fun show(context: Context, title: String, text: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Sensor not recording", NotificationManager.IMPORTANCE_DEFAULT),
        )
        nm.createNotificationChannel(
            NotificationChannel(QUIET_CHANNEL_ID, "Sensor not recording (night)", NotificationManager.IMPORTANCE_LOW),
        )
        val channel = if (isNight()) QUIET_CHANNEL_ID else CHANNEL_ID
        val open = PendingIntent.getActivity(
            context,
            1,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        nm.notify(
            NOTIFICATION_ID,
            Notification.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_stat_heild)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_ERROR)
                .build(),
        )
    }

    fun clear(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }
}
