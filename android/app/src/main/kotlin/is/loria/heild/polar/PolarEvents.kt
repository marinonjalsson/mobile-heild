package `is`.loria.heild.polar

import android.os.Handler
import android.os.Looper
import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.androidcommunications.api.ble.model.gatt.client.ChargeState
import com.polar.androidcommunications.api.ble.model.gatt.client.PowerSourcesState
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiCallbackProvider
import com.polar.sdk.api.PolarBleDisconnectInfo
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarHealthThermometerData
import com.polar.sdk.api.model.PolarHrData
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.util.UUID

/**
 * Forwards every [PolarBleApiCallbackProvider] callback to Flutter on one EventChannel
 * (`heild/polar/events`) as `{ "type": "...", ... }` maps. Events arriving before Dart
 * subscribes are buffered so the first connection state is never lost.
 */
class PolarEvents(messenger: BinaryMessenger) : PolarBleApiCallbackProvider, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val pending = ArrayDeque<Map<String, Any?>>()

    init {
        EventChannel(messenger, "heild/polar/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        while (pending.isNotEmpty()) events.success(pending.removeFirst())
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(type: String, vararg fields: Pair<String, Any?>) {
        val event = mapOf("type" to type, *fields)
        main.post {
            val s = sink
            if (s == null) {
                if (pending.size < 200) pending.addLast(event)
            } else {
                s.success(event)
            }
        }
    }

    override fun blePowerStateChanged(powered: Boolean) = emit("blePowerState", "powered" to powered)

    override fun deviceConnected(polarDeviceInfo: PolarDeviceInfo) =
        emit("deviceConnected", "device" to Mappers.deviceInfoToMap(polarDeviceInfo))

    override fun deviceConnecting(polarDeviceInfo: PolarDeviceInfo) =
        emit("deviceConnecting", "device" to Mappers.deviceInfoToMap(polarDeviceInfo))

    @Deprecated("Use deviceDisconnected(polarDeviceInfo, info) for typed disconnect diagnostics")
    override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo) =
        emit("deviceDisconnected", "device" to Mappers.deviceInfoToMap(polarDeviceInfo), "info" to null)

    override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo, info: PolarBleDisconnectInfo) =
        emit(
            "deviceDisconnected",
            "device" to Mappers.deviceInfoToMap(polarDeviceInfo),
            "info" to Mappers.disconnectInfoToMap(info),
        )

    override fun bleSdkFeatureReady(identifier: String, feature: PolarBleApi.PolarBleSdkFeature) =
        emit("featureReady", "identifier" to identifier, "feature" to feature.name)

    override fun bleSdkFeaturesReadiness(
        identifier: String,
        ready: List<PolarBleApi.PolarBleSdkFeature>,
        unavailable: List<PolarBleApi.PolarBleSdkFeature>,
    ) = emit(
        "featuresReadiness",
        "identifier" to identifier,
        "ready" to ready.map { it.name },
        "unavailable" to unavailable.map { it.name },
    )

    override fun disInformationReceived(identifier: String, uuid: UUID, value: String) =
        emit("disInformation", "identifier" to identifier, "key" to uuid.toString(), "value" to value)

    override fun disInformationReceived(identifier: String, disInfo: DisInfo) =
        emit("disInformation", "identifier" to identifier, "key" to disInfo.key, "value" to disInfo.value)

    override fun batteryLevelReceived(identifier: String, level: Int) =
        emit("batteryLevel", "identifier" to identifier, "level" to level)

    override fun batteryChargingStatusReceived(identifier: String, chargingStatus: ChargeState) =
        emit("batteryChargingStatus", "identifier" to identifier, "chargeState" to chargingStatus.name)

    override fun powerSourcesStateReceived(identifier: String, powerSourcesState: PowerSourcesState) =
        emit("powerSourcesState", "identifier" to identifier, "state" to Mappers.powerSourcesToMap(powerSourcesState))

    override fun hrNotificationReceived(identifier: String, data: PolarHrData.PolarHrSample) =
        emit("hrNotification", "identifier" to identifier, "sample" to Mappers.hrSampleToMap(data))

    override fun htsNotificationReceived(identifier: String, data: PolarHealthThermometerData) =
        emit("htsNotification", "identifier" to identifier, "data" to data.toString())

    override fun polarCompanionDeviceAppeared(identifier: String) =
        emit("companionDeviceAppeared", "identifier" to identifier)

    override fun polarCompanionDeviceDisappeared(identifier: String) =
        emit("companionDeviceDisappeared", "identifier" to identifier)
}
