package `is`.loria.heild.polar

import android.content.Context
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApi.PolarBleSdkFeature
import com.polar.sdk.api.PolarBleApiDefaultImpl

/**
 * The one [PolarBleApi] of the process. Created on first use (Application start, the
 * foreground service or the companion-device service), never shut down: the SDK keeps the
 * Companion Device Manager presence listeners and the connection state across Activities.
 */
object PolarHolder {
    @Volatile
    private var api: PolarBleApi? = null

    fun get(context: Context): PolarBleApi =
        api ?: synchronized(this) { api ?: create(context.applicationContext).also { api = it } }

    private fun create(context: Context): PolarBleApi = PolarBleApiDefaultImpl.defaultImplementation(
        context,
        setOf(
            PolarBleSdkFeature.FEATURE_HR,
            PolarBleSdkFeature.FEATURE_DEVICE_INFO,
            PolarBleSdkFeature.FEATURE_BATTERY_INFO,
            PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
            PolarBleSdkFeature.FEATURE_POLAR_OFFLINE_RECORDING,
            PolarBleSdkFeature.FEATURE_POLAR_DEVICE_TIME_SETUP,
            PolarBleSdkFeature.FEATURE_POLAR_SDK_MODE,
            PolarBleSdkFeature.FEATURE_POLAR_FILE_TRANSFER,
            PolarBleSdkFeature.FEATURE_POLAR_LED_ANIMATION,
            PolarBleSdkFeature.FEATURE_POLAR_FIRMWARE_UPDATE,
            PolarBleSdkFeature.FEATURE_POLAR_DEVICE_CONTROL,
            PolarBleSdkFeature.FEATURE_POLAR_FEATURES_CONFIGURATION_SERVICE,
            PolarBleSdkFeature.FEATURE_TELEMETRY,
            // The SDK associates connected devices with Android's Companion Device Manager
            // and reports presence via polarCompanionDeviceAppeared/Disappeared.
            PolarBleSdkFeature.FEATURE_COMPANION_DEVICE_MANAGEMENT,
        ),
    )
}
