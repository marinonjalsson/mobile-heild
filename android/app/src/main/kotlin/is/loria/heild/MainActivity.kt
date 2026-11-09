package `is`.loria.heild

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /** Attach to the process-wide engine instead of creating one per Activity. */
    override fun provideFlutterEngine(context: Context): FlutterEngine = EngineHolder.ensure(context)

    /** The engine keeps running (sync, BLE connection) after the Activity is gone. */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        ActivityHolder.current = this
    }

    override fun onPause() {
        if (ActivityHolder.current === this) ActivityHolder.current = null
        super.onPause()
    }
}
