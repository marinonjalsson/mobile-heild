package `is`.loria.heild.service

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import `is`.loria.heild.EngineHolder

/**
 * The scheduled sync: an inexact, doze-friendly one-shot alarm that re-arms itself. When it
 * fires, [SyncAlarmReceiver] brings the Flutter engine up, starts the foreground service with
 * the `sync` flag and Dart connects, syncs and disconnects. The interval lives in
 * SharedPreferences so [BootReceiver] can restore the alarm after a reboot (alarms do not
 * survive one). Hours = 0 switches the schedule off.
 */
object SyncSchedule {
    private const val TAG = "heild.schedule"
    private const val PREFS = "heild"
    private const val KEY_HOURS = "sync_hours"
    private const val REQUEST = 4211

    fun set(context: Context, hours: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_HOURS, hours).apply()
        if (hours <= 0) cancel(context) else arm(context, hours * 3600_000L)
    }

    /** Debug: fire once after [seconds]; the normal interval re-arms afterwards. */
    fun fireIn(context: Context, seconds: Int) = arm(context, seconds * 1000L)

    fun restore(context: Context) {
        val hours = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_HOURS, 0)
        if (hours > 0) arm(context, hours * 3600_000L)
    }

    /** Called by the receiver: arm the next one. */
    fun rearm(context: Context) = restore(context)

    private fun arm(context: Context, delayMs: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + delayMs,
            pending(context),
        )
        Log.i(TAG, "next sync alarm in ${delayMs / 1000} s")
    }

    private fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(context))
        Log.i(TAG, "sync alarm cancelled")
    }

    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST,
        Intent(context, SyncAlarmReceiver::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

class SyncAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i("heild.schedule", "sync alarm fired")
        SyncSchedule.rearm(context)
        EngineHolder.ensure(context)
        try {
            HeildService.start(context, sync = true)
        } catch (e: Exception) {
            // Foreground-service start refused from the background (should not happen: the
            // companion permission exempts us). Logged; the next alarm tries again.
            Log.w("heild.schedule", "cannot start the sync service: $e")
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) SyncSchedule.restore(context)
    }
}
