package `is`.loria.heild.walk

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `heild/walk` (`start`, `stop`, `isRunning`) and EventChannel
 * `heild/walk/points`: every GPS fix of the running walk as a Map
 * (`tsMs`, `lat`, `lon`, and `acc`, `alt`, `speed` when the fix has them).
 *
 * `start` answers with the error code `NoPreciseLocation` when the precise location
 * permission is missing and `LocationOff` when the phone's location (or its GPS) is off.
 */
class WalkBridge(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext: Context = context.applicationContext
    private val methods = MethodChannel(messenger, "heild/walk")
    private val points = EventChannel(messenger, "heild/walk/points")
    private var sink: EventChannel.EventSink? = null

    init {
        methods.setMethodCallHandler(this)
        points.setStreamHandler(this)
        WalkService.onFix = { sink?.success(toMap(it)) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val fine = appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                val lm = appContext.getSystemService(LocationManager::class.java)
                if (fine != PackageManager.PERMISSION_GRANTED) {
                    result.error("NoPreciseLocation", "The precise location permission is not granted", null)
                } else if (!lm.isLocationEnabled || !lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    result.error("LocationOff", "Location is switched off on the phone", null)
                } else {
                    try {
                        WalkService.start(appContext)
                        result.success(null)
                    } catch (e: Throwable) {
                        // E.g. ForegroundServiceStartNotAllowedException when not in the foreground.
                        result.error(e::class.simpleName ?: "Error", e.message ?: e.toString(), null)
                    }
                }
            }
            "stop" -> {
                WalkService.stop()
                result.success(null)
            }
            "isRunning" -> result.success(WalkService.wanted)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /**
     * Altitude is above mean sea level when Android gives that (14 and later), otherwise
     * above the WGS84 ellipsoid, which in Iceland is some 65 m more.
     */
    private fun toMap(l: Location): Map<String, Any?> = mapOf(
        "tsMs" to l.time,
        "lat" to l.latitude,
        "lon" to l.longitude,
        "acc" to if (l.hasAccuracy()) l.accuracy.toDouble() else null,
        "alt" to when {
            Build.VERSION.SDK_INT >= 34 && l.hasMslAltitude() -> l.mslAltitudeMeters
            l.hasAltitude() -> l.altitude
            else -> null
        },
        "speed" to if (l.hasSpeed()) l.speed.toDouble() else null,
    )
}
