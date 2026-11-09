package `is`.loria.heild

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import `is`.loria.heild.polar.PolarBridge

class MainActivity : FlutterActivity() {
    private var polar: PolarBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        polar = PolarBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        polar?.dispose()
        polar = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
