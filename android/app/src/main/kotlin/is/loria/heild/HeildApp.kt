package `is`.loria.heild

import android.app.Activity
import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import `is`.loria.heild.polar.PolarBridge

/**
 * Creates the one Flutter engine at process start, whoever started the process: the
 * launcher, the companion-device presence service or the foreground service. The Dart
 * side (sync, database) therefore runs with or without a visible Activity.
 */
class HeildApp : Application() {
    override fun onCreate() {
        super.onCreate()
        EngineHolder.ensure(this)
    }
}

/** The cached Flutter engine and its Polar bridge. Main thread only. */
object EngineHolder {
    const val ENGINE_ID = "main"

    @Volatile
    var engine: FlutterEngine? = null
        private set

    var bridge: PolarBridge? = null
        private set

    fun ensure(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        // Plugins (permission_handler, sqflite, path_provider) register automatically.
        val e = FlutterEngine(app)
        bridge = PolarBridge(app, e.dartExecutor.binaryMessenger)
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, e)
        engine = e
        return e
    }
}

/** The resumed Activity, for the few SDK calls that need one (companion privileges). */
object ActivityHolder {
    @Volatile
    var current: Activity? = null
}
