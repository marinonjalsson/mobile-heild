package `is`.loria.heild.polar

import android.content.Context
import com.polar.androidcommunications.api.ble.model.gatt.client.pmd.PmdMeasurementType
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApi.PolarBleSdkFeature
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.PolarDeviceTelemetryType
import `is`.loria.heild.polar.Mappers.bool
import `is`.loria.heild.polar.Mappers.boolOrNull
import `is`.loria.heild.polar.Mappers.int
import `is`.loria.heild.polar.Mappers.intOrNull
import `is`.loria.heild.polar.Mappers.map
import `is`.loria.heild.polar.Mappers.str
import `is`.loria.heild.polar.Mappers.strOrNull
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.time.ZonedDateTime

/**
 * Method channel `heild/polar`: one method per Polar BLE SDK call the Verity Sense supports.
 * Suspend functions run in [scope] (main dispatcher) and answer through [MethodChannel.Result].
 * Flow-returning functions are opened with `openStream` and delivered via [StreamChannels].
 */
class PolarBridge(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val events = PolarEvents(messenger)
    private val streams = StreamChannels(messenger, scope)
    private val methods = MethodChannel(messenger, "heild/polar")

    private val api: PolarBleApi = PolarBleApiDefaultImpl.defaultImplementation(
        context.applicationContext,
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
        ),
    ).also { it.setApiCallback(events) }

    init {
        methods.setMethodCallHandler(this)
    }

    fun dispose() {
        streams.closeAll()
        methods.setMethodCallHandler(null)
        api.shutDown()
        scope.cancel()
    }

    /** Runs [block] on the main-dispatcher scope and reports its value or error. */
    private fun run(result: MethodChannel.Result, block: suspend () -> Any?) {
        scope.launch {
            try {
                // Unit is not encodable by the StandardMessageCodec; send null for void calls.
                val value = block()
                result.success(if (value == Unit) null else value)
            } catch (e: Throwable) {
                result.error(e::class.simpleName ?: "Error", e.message ?: e.toString(), null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val a: Map<*, *> = (call.arguments as? Map<*, *>) ?: emptyMap<String, Any?>()
        val id: String by lazy { a.str("identifier") }
        val type by lazy { Mappers.dataType(a.str("dataType")) }

        when (call.method) {
            // ---- core ---------------------------------------------------------
            "versionInfo" -> result.success(PolarBleApiDefaultImpl.versionInfo())
            "connectToDevice" -> run(result) { api.connectToDevice(id) }
            "disconnectFromDevice" -> run(result) { api.disconnectFromDevice(id) }
            "waitForConnection" -> run(result) { api.waitForConnection(id) }
            "setPolarFilter" -> run(result) { api.setPolarFilter(a.bool("enable")) }
            "setAutomaticReconnection" -> run(result) { api.setAutomaticReconnection(a.bool("enable")) }
            "setMtu" -> run(result) { api.setMtu(a.int("mtu")) }
            "cleanup" -> run(result) { api.cleanup() }
            "foregroundEntered" -> run(result) { api.foregroundEntered() }
            "isFeatureReady" -> run(result) { api.isFeatureReady(id, Mappers.feature(a.str("feature"))) }
            "getDeviceName" -> run(result) { api.getDeviceName(id) }
            "getBatteryLevel" -> run(result) { api.getBatteryLevel(id) }
            "getChargerState" -> run(result) { api.getChargerState(id).name }
            "getRSSIValue" -> run(result) { api.getRSSIValue(id) }
            "checkIfDeviceDisconnectedDueRemovedPairing" -> run(result) {
                val (removed, status) = api.checkIfDeviceDisconnectedDueRemovedPairing(id)
                mapOf("removed" to removed, "gattStatus" to status)
            }

            // ---- online streaming ---------------------------------------------
            "getAvailableOnlineStreamDataTypes" -> run(result) {
                api.getAvailableOnlineStreamDataTypes(id).map { it.name }
            }
            "getAvailableHRServiceDataTypes" -> run(result) {
                api.getAvailableHRServiceDataTypes(id).map { it.name }
            }
            "requestStreamSettings" -> run(result) {
                Mappers.sensorSettingToMap(api.requestStreamSettings(id, type))
            }
            "requestFullStreamSettings" -> run(result) {
                Mappers.sensorSettingToMap(api.requestFullStreamSettings(id, type))
            }
            "stopHrStreaming" -> run(result) { api.stopHrStreaming(id) }
            "stopStreaming" -> run(result) {
                api.stopStreaming(id, PmdMeasurementType.valueOf(a.str("pmdType")))
            }

            // ---- offline recording --------------------------------------------
            "getAvailableOfflineRecordingDataTypes" -> run(result) {
                api.getAvailableOfflineRecordingDataTypes(id).map { it.name }
            }
            "requestOfflineRecordingSettings" -> run(result) {
                Mappers.sensorSettingToMap(api.requestOfflineRecordingSettings(id, type))
            }
            "requestFullOfflineRecordingSettings" -> run(result) {
                Mappers.sensorSettingToMap(api.requestFullOfflineRecordingSettings(id, type))
            }
            "getOfflineRecordingStatus" -> run(result) { api.getOfflineRecordingStatus(id).map { it.name } }
            "startOfflineRecording" -> run(result) {
                api.startOfflineRecording(
                    id, type,
                    Mappers.sensorSettingFromMap(a.map("settings")),
                    Mappers.secretFromHex(a.strOrNull("secret")),
                )
            }
            "stopOfflineRecording" -> run(result) { api.stopOfflineRecording(id, type) }
            "removeOfflineRecord" -> run(result) {
                api.removeOfflineRecord(id, Mappers.offlineEntryFromMap(a.map("entry")!!))
            }
            "setOfflineRecordingTrigger" -> run(result) {
                api.setOfflineRecordingTrigger(
                    id,
                    Mappers.triggerFromMap(a.map("trigger")!!),
                    Mappers.secretFromHex(a.strOrNull("secret")),
                )
            }
            "getOfflineRecordingTriggerSetup" -> run(result) {
                Mappers.triggerToMap(api.getOfflineRecordingTriggerSetup(id))
            }

            // ---- SDK mode -----------------------------------------------------
            "enableSDKMode" -> run(result) { api.enableSDKMode(id) }
            "disableSDKMode" -> run(result) { api.disableSDKMode(id) }
            "isSDKModeEnabled" -> run(result) { api.isSDKModeEnabled(id) }

            // ---- device management --------------------------------------------
            "setLocalTime" -> run(result) {
                api.setLocalTime(id, Mappers.localDateTimeFromString(a.str("dateTime")))
            }
            "getLocalTimeWithZone" -> run(result) { Mappers.zonedToString(api.getLocalTimeWithZone(id)) }
            "getDiskSpace" -> run(result) { Mappers.diskSpaceToMap(api.getDiskSpace(id)) }
            "setLedConfig" -> run(result) { api.setLedConfig(id, Mappers.ledConfigFromMap(a.map("config")!!)) }
            "doFactoryReset" -> run(result) { api.doFactoryReset(id) }
            "doRestart" -> run(result) { api.doRestart(id) }
            "setWarehouseSleep" -> run(result) { api.setWarehouseSleep(id) }
            "setHibernateMode" -> run(result) { api.setHibernateMode(id) }
            "turnDeviceOff" -> run(result) { api.turnDeviceOff(id) }
            "doFirstTimeUse" -> run(result) { api.doFirstTimeUse(id, Mappers.ftuConfigFromMap(a.map("config")!!)) }
            "isFtuDone" -> run(result) { api.isFtuDone(id) }
            "getUserPhysicalConfiguration" -> run(result) {
                Mappers.physicalConfigToMap(api.getUserPhysicalConfiguration(id))
            }
            "getUserDeviceSettings" -> run(result) { Mappers.userDeviceSettingsToMap(api.getUserDeviceSettings(id)) }
            "setUserDeviceLocation" -> run(result) { api.setUserDeviceLocation(id, a.int("location")) }
            "setUsbConnectionMode" -> run(result) { api.setUsbConnectionMode(id, a.bool("enabled")) }
            "setAutomaticTrainingDetectionSettings" -> run(result) {
                api.setAutomaticTrainingDetectionSettings(
                    id, a.bool("mode"), a.int("sensitivity"), a.int("minimumDuration"),
                )
            }
            "setDaylightSavingTime" -> run(result) { api.setDaylightSavingTime(id) }
            "deleteStoredDeviceData" -> run(result) {
                api.deleteStoredDeviceData(
                    id,
                    PolarBleApi.PolarStoredDataType.valueOf(a.str("storedDataType")),
                    Mappers.localDate(a.strOrNull("until")),
                )
            }
            "setTelemetryEnabled" -> run(result) { api.setTelemetryEnabled(id, a.bool("enabled")) }
            "deleteDeviceDateFolders" -> run(result) {
                api.deleteDeviceDateFolders(id, Mappers.localDate(a.strOrNull("fromDate")), Mappers.localDate(a.strOrNull("toDate")))
            }
            "deleteTelemetryData" -> run(result) { api.deleteTelemetryData(id) }
            "setMultiBLEConnectionMode" -> run(result) { api.setMultiBLEConnectionMode(id, a.bool("enable")) }
            "getMultiBLEConnectionMode" -> run(result) { api.getMultiBLEConnectionMode(id) }
            "setSensorInitiatedSecurityMode" -> run(result) { api.setSensorInitiatedSecurityMode(id, a.bool("enable")) }
            "getSensorInitiatedSecurityMode" -> run(result) { api.getSensorInitiatedSecurityMode(id) }
            "sendInitializationAndStartSyncNotifications" -> run(result) {
                api.sendInitializationAndStartSyncNotifications(id)
            }
            "sendTerminateAndStopSyncNotifications" -> run(result) {
                api.sendTerminateAndStopSyncNotifications(id)
            }
            "setAutomaticOHRMeasurementEnabled" -> run(result) {
                api.setAutomaticOHRMeasurementEnabled(id, a.bool("enabled"))
            }
            "getFile" -> run(result) { api.getFile(id, a.str("path")) }

            // ---- low level file system ----------------------------------------
            "readFile" -> run(result) { api.readFile(id, a.str("path")) }
            "writeFile" -> run(result) { api.writeFile(id, a.str("path"), a["data"] as ByteArray) }
            "deleteFileOrDirectory" -> run(result) { api.deleteFileOrDirectory(id, a.str("path")) }
            "getFileList" -> run(result) {
                api.getFileList(id, a.str("path"), a.boolOrNull("recurseDeep") ?: false)
            }
            "createFolder" -> run(result) { api.createFolder(id, a.str("path")) }

            // ---- logging / telemetry ------------------------------------------
            "exportDeviceLogs" -> run(result) { api.exportDeviceLogs(id).map(Mappers::deviceLogToMap) }
            "getLogConfig" -> run(result) { Mappers.logConfigToMap(api.getLogConfig(id)) }
            "setLogConfig" -> run(result) { api.setLogConfig(id, Mappers.logConfigFromMap(a.map("config")!!)) }
            "getAvailableTelemetryTypes" -> run(result) {
                Mappers.telemetrySupportToMap(api.getAvailableTelemetryTypes(id))
            }
            "getDeviceTelemetryConfiguration" -> run(result) {
                Mappers.telemetryConfigToMap(
                    api.getDeviceTelemetryConfiguration(id, PolarDeviceTelemetryType.valueOf(a.str("telemetryType"))),
                )
            }
            "stopTelemetry" -> run(result) {
                api.stopTelemetry(id, PolarDeviceTelemetryType.valueOf(a.str("telemetryType")))
            }

            // ---- flows --------------------------------------------------------
            "openStream" -> {
                try {
                    openStream(a.str("id"), a.str("kind"), a)
                    result.success(streams.channelName(a.str("id")))
                } catch (e: Throwable) {
                    result.error(e::class.simpleName ?: "Error", e.message, null)
                }
            }
            "closeStream" -> {
                streams.close(a.str("id"))
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Registers the EventChannel for [kind]; collection starts when Dart listens. */
    private fun openStream(streamId: String, kind: String, a: Map<*, *>) {
        val id: String by lazy { a.str("identifier") }
        val settings by lazy {
            Mappers.sensorSettingFromMap(a.map("settings"))
                ?: throw IllegalArgumentException("'settings' required for $kind")
        }
        streams.open(streamId) {
            when (kind) {
                "search" -> api.searchForDevice(a.strOrNull("namePrefix") ?: "Polar").map(Mappers::deviceInfoToMap)
                "hrBroadcast" -> api.startListenForPolarHrBroadcasts(
                    (a["identifiers"] as? List<*>)?.map { it as String }?.toSet(),
                ).map(Mappers::hrBroadcastToMap)

                "hr" -> api.startHrStreaming(id).map(Mappers::hrDataToMap)
                "ppi" -> api.startPpiStreaming(id).map(Mappers::ppiDataToMap)
                "ppg" -> api.startPpgStreaming(id, settings).map(Mappers::ppgDataToMap)
                "acc" -> api.startAccStreaming(id, settings).map(Mappers::accDataToMap)
                "gyro" -> api.startGyroStreaming(id, settings).map(Mappers::gyroDataToMap)
                "magnetometer" -> api.startMagnetometerStreaming(id, settings).map(Mappers::magDataToMap)
                "ecg" -> api.startEcgStreaming(id, settings).map(Mappers::ecgDataToMap)
                "temperature" -> api.startTemperatureStreaming(id, settings).map { Mappers.temperatureDataToMap(it, "TEMPERATURE") }
                "skinTemperature" -> api.startSkinTemperatureStreaming(id, settings).map { Mappers.temperatureDataToMap(it, "SKIN_TEMPERATURE") }
                "pressure" -> api.startPressureStreaming(id, settings).map(Mappers::pressureDataToMap)
                "location" -> api.startLocationStreaming(id, settings).map(Mappers::locationDataToMap)

                "listOfflineRecordings" -> api.listOfflineRecordings(id).map(Mappers::offlineEntryToMap)
                "offlineRecordWithProgress" -> api.getOfflineRecordWithProgress(
                    id,
                    Mappers.offlineEntryFromMap(a.map("entry")!!),
                    Mappers.secretFromHex(a.strOrNull("secret")),
                ).map(Mappers::offlineResultToMap)

                "checkFirmwareUpdate" -> api.checkFirmwareUpdate(id).map(Mappers::checkFwToMap)
                "updateFirmware" -> {
                    val url = a.strOrNull("firmwareUrl")
                    (if (url.isNullOrBlank()) api.updateFirmware(id) else api.updateFirmware(id, url))
                        .map(Mappers::fwUpdateToMap)
                }

                "d2hNotifications" -> api.observeDeviceToHostNotifications(id).map(Mappers::d2hToMap)
                "telemetry" -> api.startTelemetry(
                    id, PolarDeviceTelemetryType.valueOf(a.str("telemetryType")),
                ).map(Mappers::telemetryEventToMap)

                else -> throw IllegalArgumentException("unknown stream kind '$kind'")
            }
        }
    }
}
