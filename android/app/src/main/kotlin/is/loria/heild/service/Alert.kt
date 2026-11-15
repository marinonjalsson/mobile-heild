package `is`.loria.heild.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import `is`.loria.heild.MainActivity
import `is`.loria.heild.R

/**
 * The one notification that asks for the wearer's attention: the sensor is not recording and
 * the app could not put that right by itself. Its own channel (default importance, so it is
 * heard), apart from the quiet foreground-service one. Dart shows and clears it (`alert`,
 * `alertClear`); a tap opens the app.
 */
object Alert {
    private const val CHANNEL_ID = "heild.alert"
    private const val NOTIFICATION_ID = 4212

    fun show(context: Context, title: String, text: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Sensor not recording", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val open = PendingIntent.getActivity(
            context,
            1,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        nm.notify(
            NOTIFICATION_ID,
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
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
