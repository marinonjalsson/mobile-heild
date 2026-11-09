package `is`.loria.heild.polar

import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.androidcommunications.api.ble.model.gatt.client.ChargeState
import com.polar.androidcommunications.api.ble.model.gatt.client.PowerSourcesState
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApi.PolarDeviceDataType
import com.polar.sdk.api.PolarBleDisconnectInfo
import com.polar.sdk.api.PolarD2HNotificationData
import com.polar.sdk.api.DeviceTelemetryConfiguration
import com.polar.sdk.api.DeviceTelemetryEvent
import com.polar.sdk.api.DeviceTelemetrySupport
import com.polar.sdk.api.model.CheckFirmwareUpdateStatus
import com.polar.sdk.api.model.FirmwareUpdateStatus
import com.polar.sdk.api.model.LedConfig
import com.polar.sdk.api.model.LogConfig
import com.polar.sdk.api.model.PolarAccelerometerData
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarDeviceLog
import com.polar.sdk.api.model.PolarDiskSpaceData
import com.polar.sdk.api.model.EcgSample
import com.polar.sdk.api.model.FecgSample
import com.polar.sdk.api.model.PolarEcgData
import com.polar.sdk.api.model.PolarFirstTimeUseConfig
import com.polar.sdk.api.model.PolarGyroData
import com.polar.sdk.api.model.PolarHrBroadcastData
import com.polar.sdk.api.model.PolarHrData
import com.polar.sdk.api.model.PolarLocationData
import com.polar.sdk.api.model.PolarMagnetometerData
import com.polar.sdk.api.model.PolarOfflineRecordingData
import com.polar.sdk.api.model.PolarOfflineRecordingEntry
import com.polar.sdk.api.model.PolarOfflineRecordingResult
import com.polar.sdk.api.model.PolarOfflineRecordingTrigger
import com.polar.sdk.api.model.PolarOfflineRecordingTriggerMode
import com.polar.sdk.api.model.PolarPhysicalConfiguration
import com.polar.sdk.api.model.PolarPpgData
import com.polar.sdk.api.model.PolarPpiData
import com.polar.sdk.api.model.PolarPressureData
import com.polar.sdk.api.model.PolarRecordingSecret
import com.polar.sdk.api.model.PolarSensorSetting
import com.polar.sdk.api.model.PolarTemperatureData
import com.polar.sdk.api.model.PolarUserDeviceSettings
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/**
 * Kotlin SDK model <-> Map conversions for the Flutter StandardMessageCodec.
 * Maps use String keys; enums travel as their `name`; times as ISO-8601 strings.
 */
object Mappers {

    // ---- argument helpers -------------------------------------------------

    fun Map<*, *>.str(key: String): String =
        this[key] as? String ?: throw IllegalArgumentException("missing '$key'")

    fun Map<*, *>.strOrNull(key: String): String? = this[key] as? String

    fun Map<*, *>.int(key: String): Int =
        (this[key] as? Number)?.toInt() ?: throw IllegalArgumentException("missing '$key'")

    fun Map<*, *>.intOrNull(key: String): Int? = (this[key] as? Number)?.toInt()

    fun Map<*, *>.bool(key: String): Boolean =
        this[key] as? Boolean ?: throw IllegalArgumentException("missing '$key'")

    fun Map<*, *>.boolOrNull(key: String): Boolean? = this[key] as? Boolean

    fun Map<*, *>.map(key: String): Map<*, *>? = this[key] as? Map<*, *>

    fun dataType(name: String): PolarDeviceDataType = PolarDeviceDataType.valueOf(name)

    fun feature(name: String): PolarBleApi.PolarBleSdkFeature =
        PolarBleApi.PolarBleSdkFeature.valueOf(name)

    fun localDate(s: String?): LocalDate? = s?.let { LocalDate.parse(it) }

    // ---- sensor settings --------------------------------------------------

    fun sensorSettingToMap(s: PolarSensorSetting?): Map<String, List<Int>>? =
        s?.settings?.entries?.associate { (k, v) -> k.name to v.sorted() }

    /** `{ "SAMPLE_RATE": 52, "RANGE": 8, ... }` -> PolarSensorSetting (one value per type). */
    fun sensorSettingFromMap(m: Map<*, *>?): PolarSensorSetting? {
        if (m == null || m.isEmpty()) return null
        val selected = m.entries.associate { (k, v) ->
            PolarSensorSetting.SettingType.valueOf(k as String) to (v as Number).toInt()
        }
        return PolarSensorSetting(selected)
    }

    fun secretFromHex(hex: String?): PolarRecordingSecret? {
        if (hex.isNullOrBlank()) return null
        val clean = hex.trim().removePrefix("0x")
        require(clean.length == 32) { "secret must be 16 bytes (32 hex chars)" }
        val bytes = ByteArray(16) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        return PolarRecordingSecret(bytes)
    }

    // ---- device / events --------------------------------------------------

    fun deviceInfoToMap(d: PolarDeviceInfo): Map<String, Any?> = mapOf(
        "deviceId" to d.deviceId,
        "address" to d.address,
        "rssi" to d.rssi,
        "name" to d.name,
        "isConnectable" to d.isConnectable,
        "hasHeartRateService" to d.hasHeartRateService,
        "hasFileSystemService" to d.hasFileSystemService,
        "hasSAGRFCFileSystem" to d.hasSAGRFCFileSystem,
    )

    fun disconnectInfoToMap(i: PolarBleDisconnectInfo): Map<String, Any?> = mapOf(
        "reason" to i.reason.name,
        "recoveryAction" to i.recoveryAction.name,
        "gattStatus" to i.gattStatus,
        "deviceCommand" to i.deviceCommand?.name,
    )

    fun disInfoToMap(d: DisInfo): Map<String, Any?> = mapOf("key" to d.key, "value" to d.value)

    fun chargeState(c: ChargeState): String = c.name

    fun powerSourcesToMap(p: PowerSourcesState): Map<String, Any?> = mapOf(
        "batteryPresent" to p.batteryPresent.name,
        "wiredExternalPowerConnected" to p.wiredExternalPowerConnected.name,
        "wirelessExternalPowerConnected" to p.wirelessExternalPowerConnected.name,
    )

    fun diskSpaceToMap(d: PolarDiskSpaceData): Map<String, Any?> =
        mapOf("totalSpace" to d.totalSpace, "freeSpace" to d.freeSpace)

    fun zonedToString(z: ZonedDateTime): String = z.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

    fun localDateTimeFromString(s: String): LocalDateTime = LocalDateTime.parse(s.removeSuffix("Z"))

    // ---- streaming samples ------------------------------------------------

    fun hrSampleToMap(s: PolarHrData.PolarHrSample): Map<String, Any?> = mapOf(
        "hr" to s.hr,
        "correctedHr" to s.correctedHr,
        "ppgQuality" to s.ppgQuality,
        "rrsMs" to s.rrsMs,
        "rrAvailable" to s.rrAvailable,
        "contactStatus" to s.contactStatus,
        "contactStatusSupported" to s.contactStatusSupported,
    )

    fun hrDataToMap(d: PolarHrData): Map<String, Any?> =
        mapOf("type" to "HR", "samples" to d.samples.map(::hrSampleToMap))

    fun ppiSampleToMap(s: PolarPpiData.PolarPpiSample): Map<String, Any?> = mapOf(
        "ppi" to s.ppi,
        "errorEstimate" to s.errorEstimate,
        "hr" to s.hr,
        "blockerBit" to s.blockerBit,
        "skinContactStatus" to s.skinContactStatus,
        "skinContactSupported" to s.skinContactSupported,
        "timeStamp" to s.timeStamp.toLong(),
    )

    fun ppiDataToMap(d: PolarPpiData): Map<String, Any?> =
        mapOf("type" to "PPI", "samples" to d.samples.map(::ppiSampleToMap))

    fun ppgSampleToMap(s: PolarPpgData.PolarPpgSample): Map<String, Any?> = mapOf(
        "timeStamp" to s.timeStamp,
        "channelSamples" to s.channelSamples,
        "statusBits" to s.statusBits,
    )

    fun ppgDataToMap(d: PolarPpgData): Map<String, Any?> = mapOf(
        "type" to "PPG",
        "ppgDataType" to d.type.name,
        "samples" to d.samples.map(::ppgSampleToMap),
    )

    fun accSampleToMap(s: PolarAccelerometerData.PolarAccelerometerDataSample): Map<String, Any?> =
        mapOf("timeStamp" to s.timeStamp, "x" to s.x, "y" to s.y, "z" to s.z)

    fun accDataToMap(d: PolarAccelerometerData): Map<String, Any?> =
        mapOf("type" to "ACC", "samples" to d.samples.map(::accSampleToMap))

    fun gyroSampleToMap(s: PolarGyroData.PolarGyroDataSample): Map<String, Any?> =
        mapOf("timeStamp" to s.timeStamp, "x" to s.x.toDouble(), "y" to s.y.toDouble(), "z" to s.z.toDouble())

    fun gyroDataToMap(d: PolarGyroData): Map<String, Any?> =
        mapOf("type" to "GYRO", "samples" to d.samples.map(::gyroSampleToMap))

    fun magSampleToMap(s: PolarMagnetometerData.PolarMagnetometerDataSample): Map<String, Any?> =
        mapOf("timeStamp" to s.timeStamp, "x" to s.x.toDouble(), "y" to s.y.toDouble(), "z" to s.z.toDouble())

    fun magDataToMap(d: PolarMagnetometerData): Map<String, Any?> =
        mapOf("type" to "MAGNETOMETER", "samples" to d.samples.map(::magSampleToMap))

    fun ecgDataToMap(d: PolarEcgData): Map<String, Any?> = mapOf(
        "type" to "ECG",
        "samples" to d.samples.map {
            when (it) {
                is EcgSample -> mapOf("timeStamp" to it.timeStamp, "voltage" to it.voltage)
                is FecgSample -> mapOf("timeStamp" to it.timeStamp, "ecg" to it.ecg, "bioz" to it.bioz)
                else -> mapOf("timeStamp" to it.timeStamp)
            }
        },
    )

    fun temperatureDataToMap(d: PolarTemperatureData, type: String): Map<String, Any?> = mapOf(
        "type" to type,
        "samples" to d.samples.map { mapOf("timeStamp" to it.timeStamp, "temperature" to it.temperature.toDouble()) },
    )

    fun pressureDataToMap(d: PolarPressureData): Map<String, Any?> = mapOf(
        "type" to "PRESSURE",
        "samples" to d.samples.map { mapOf("timeStamp" to it.timeStamp, "pressure" to it.pressure.toDouble()) },
    )

    fun locationDataToMap(d: PolarLocationData): Map<String, Any?> = mapOf(
        "type" to "LOCATION",
        "samples" to d.samples.map { it.toString() },
    )

    fun hrBroadcastToMap(b: PolarHrBroadcastData): Map<String, Any?> = mapOf(
        "device" to deviceInfoToMap(b.polarDeviceInfo),
        "hr" to b.hr,
        "batteryStatus" to b.batteryStatus,
    )

    // ---- offline recording ------------------------------------------------

    fun offlineEntryToMap(e: PolarOfflineRecordingEntry): Map<String, Any?> = mapOf(
        "path" to e.path,
        "size" to e.size,
        "date" to e.date.toString(),
        "type" to e.type.name,
    )

    fun offlineEntryFromMap(m: Map<*, *>): PolarOfflineRecordingEntry = PolarOfflineRecordingEntry(
        path = m.str("path"),
        size = (m["size"] as Number).toLong(),
        date = LocalDateTime.parse(m.str("date")),
        type = dataType(m.str("type")),
    )

    fun triggerToMap(t: PolarOfflineRecordingTrigger): Map<String, Any?> = mapOf(
        "triggerMode" to t.triggerMode.name,
        "triggerFeatures" to t.triggerFeatures.entries.associate { (k, v) -> k.name to sensorSettingToMap(v) },
    )

    fun triggerFromMap(m: Map<*, *>): PolarOfflineRecordingTrigger {
        val features = (m.map("triggerFeatures") ?: emptyMap<Any, Any>()).entries.associate { (k, v) ->
            dataType(k as String) to sensorSettingFromMap(v as? Map<*, *>)
        }
        return PolarOfflineRecordingTrigger(
            triggerMode = PolarOfflineRecordingTriggerMode.valueOf(m.str("triggerMode")),
            triggerFeatures = features,
        )
    }

    /**
     * Summarises a fetched recording: metadata, sample count, first and last sample.
     * Full sample lists can be hundreds of thousands of entries; the UI only shows a summary.
     */
    fun offlineDataToMap(d: PolarOfflineRecordingData): Map<String, Any?> {
        val (type, samples) = when (d) {
            is PolarOfflineRecordingData.AccOfflineRecording -> "ACC" to d.data.samples.map(::accSampleToMap)
            is PolarOfflineRecordingData.GyroOfflineRecording -> "GYRO" to d.data.samples.map(::gyroSampleToMap)
            is PolarOfflineRecordingData.MagOfflineRecording -> "MAGNETOMETER" to d.data.samples.map(::magSampleToMap)
            is PolarOfflineRecordingData.PpgOfflineRecording -> "PPG" to d.data.samples.map(::ppgSampleToMap)
            is PolarOfflineRecordingData.PpiOfflineRecording -> "PPI" to d.data.samples.map(::ppiSampleToMap)
            is PolarOfflineRecordingData.HrOfflineRecording -> "HR" to d.data.samples.map(::hrSampleToMap)
            is PolarOfflineRecordingData.TemperatureOfflineRecording ->
                "TEMPERATURE" to d.data.samples.map { mapOf("timeStamp" to it.timeStamp, "temperature" to it.temperature.toDouble()) }
            is PolarOfflineRecordingData.SkinTemperatureOfflineRecording ->
                "SKIN_TEMPERATURE" to d.data.samples.map { mapOf("timeStamp" to it.timeStamp, "temperature" to it.temperature.toDouble()) }
            else -> d::class.simpleName.orEmpty() to emptyList()
        }
        return mapOf(
            "type" to type,
            "startTime" to d.startTime.toString(),
            "settings" to sensorSettingToMap(d.settings),
            "sampleCount" to samples.size,
            "first" to samples.firstOrNull(),
            "last" to samples.lastOrNull(),
        )
    }

    fun offlineResultToMap(r: PolarOfflineRecordingResult): Map<String, Any?> = when (r) {
        is PolarOfflineRecordingResult.Progress -> mapOf(
            "kind" to "progress",
            "bytesDownloaded" to r.bytesDownloaded,
            "totalBytes" to r.totalBytes,
            "progressPercent" to r.progressPercent,
        )
        is PolarOfflineRecordingResult.Complete -> mapOf("kind" to "complete", "data" to offlineDataToMap(r.data))
    }

    // ---- device configuration --------------------------------------------

    fun ledConfigFromMap(m: Map<*, *>): LedConfig = LedConfig(
        sdkModeLedEnabled = m.boolOrNull("sdkModeLedEnabled") ?: true,
        ppiModeLedEnabled = m.boolOrNull("ppiModeLedEnabled") ?: true,
    )

    fun ftuConfigFromMap(m: Map<*, *>): PolarFirstTimeUseConfig = PolarFirstTimeUseConfig(
        gender = PolarFirstTimeUseConfig.Gender.valueOf(m.str("gender")),
        birthDate = LocalDate.parse(m.str("birthDate")),
        height = (m["height"] as Number).toFloat(),
        weight = (m["weight"] as Number).toFloat(),
        maxHeartRate = m.int("maxHeartRate"),
        vo2Max = m.int("vo2Max"),
        restingHeartRate = m.int("restingHeartRate"),
        trainingBackground = m.int("trainingBackground"),
        deviceTime = m.str("deviceTime"),
        typicalDay = PolarFirstTimeUseConfig.TypicalDay.valueOf(m.str("typicalDay")),
        sleepGoalMinutes = m.int("sleepGoalMinutes"),
    )

    fun physicalConfigToMap(p: PolarPhysicalConfiguration?): Map<String, Any?>? = p?.let {
        mapOf(
            "gender" to it.gender.name,
            "birthDate" to it.birthDate.toString(),
            "height" to it.height.toDouble(),
            "weight" to it.weight.toDouble(),
            "maxHeartRate" to it.maxHeartRate,
            "vo2Max" to it.vo2Max,
            "restingHeartRate" to it.restingHeartRate,
            "trainingBackground" to it.trainingBackground,
            "deviceTime" to it.deviceTime,
            "typicalDay" to it.typicalDay.name,
            "sleepGoalMinutes" to it.sleepGoalMinutes,
        )
    }

    fun userDeviceSettingsToMap(s: PolarUserDeviceSettings): Map<String, Any?> = mapOf(
        "deviceLocation" to s.deviceLocation,
        "deviceLocationName" to s.deviceLocation?.let { (PolarUserDeviceSettings from it)?.name },
        "usbConnectionMode" to s.usbConnectionMode,
        "automaticTrainingDetectionMode" to s.automaticTrainingDetectionMode,
        "automaticTrainingDetectionSensitivity" to s.automaticTrainingDetectionSensitivity,
        "minimumTrainingDurationSeconds" to s.minimumTrainingDurationSeconds,
        "telemetryEnabled" to s.telemetryEnabled,
        "autosFilesEnabled" to s.autosFilesEnabled,
    )

    fun logConfigToMap(c: LogConfig): Map<String, Any?> = mapOf(
        "ohrLogEnabled" to c.ohrLogEnabled,
        "ppiLogEnabled" to c.ppiLogEnabled,
        "accelerationLogEnabled" to c.accelerationLogEnabled,
        "caloriesLogEnabled" to c.caloriesLogEnabled,
        "gpsLogEnabled" to c.gpsLogEnabled,
        "gpsNmeaLogEnabled" to c.gpsNmeaLogEnabled,
        "magnetometerLogEnabled" to c.magnetometerLogEnabled,
        "tapLogEnabled" to c.tapLogEnabled,
        "barometerLogEnabled" to c.barometerLogEnabled,
        "gyroscopeLogEnabled" to c.gyroscopeLogEnabled,
        "sleepLogEnabled" to c.sleepLogEnabled,
        "slopeLogEnabled" to c.slopeLogEnabled,
        "ambientLightLogEnabled" to c.ambientLightLogEnabled,
        "tlrLogEnabled" to c.tlrLogEnabled,
        "ondemandLogEnabled" to c.ondemandLogEnabled,
        "capsenseLogEnabled" to c.capsenseLogEnabled,
        "fusionLogEnabled" to c.fusionLogEnabled,
        "metLogEnabled" to c.metLogEnabled,
        "verticalAccLogEnabled" to c.verticalAccLogEnabled,
        "amdLogEnabled" to c.amdLogEnabled,
        "skinTemperatureLogEnabled" to c.skinTemperatureLogEnabled,
        "compassLogEnabled" to c.compassLogEnabled,
        "speed3DLogEnabled" to c.speed3DLogEnabled,
        "retainSettingsOverBoot" to c.retainSettingsOverBoot,
    )

    fun logConfigFromMap(m: Map<*, *>): LogConfig = LogConfig(
        ohrLogEnabled = m.boolOrNull("ohrLogEnabled"),
        ppiLogEnabled = m.boolOrNull("ppiLogEnabled"),
        accelerationLogEnabled = m.boolOrNull("accelerationLogEnabled"),
        caloriesLogEnabled = m.boolOrNull("caloriesLogEnabled"),
        gpsLogEnabled = m.boolOrNull("gpsLogEnabled"),
        gpsNmeaLogEnabled = m.boolOrNull("gpsNmeaLogEnabled"),
        magnetometerLogEnabled = m.boolOrNull("magnetometerLogEnabled"),
        tapLogEnabled = m.boolOrNull("tapLogEnabled"),
        barometerLogEnabled = m.boolOrNull("barometerLogEnabled"),
        gyroscopeLogEnabled = m.boolOrNull("gyroscopeLogEnabled"),
        sleepLogEnabled = m.boolOrNull("sleepLogEnabled"),
        slopeLogEnabled = m.boolOrNull("slopeLogEnabled"),
        ambientLightLogEnabled = m.boolOrNull("ambientLightLogEnabled"),
        tlrLogEnabled = m.boolOrNull("tlrLogEnabled"),
        ondemandLogEnabled = m.boolOrNull("ondemandLogEnabled"),
        capsenseLogEnabled = m.boolOrNull("capsenseLogEnabled"),
        fusionLogEnabled = m.boolOrNull("fusionLogEnabled"),
        metLogEnabled = m.boolOrNull("metLogEnabled"),
        verticalAccLogEnabled = m.boolOrNull("verticalAccLogEnabled"),
        amdLogEnabled = m.boolOrNull("amdLogEnabled"),
        skinTemperatureLogEnabled = m.boolOrNull("skinTemperatureLogEnabled"),
        compassLogEnabled = m.boolOrNull("compassLogEnabled"),
        speed3DLogEnabled = m.boolOrNull("speed3DLogEnabled"),
        retainSettingsOverBoot = m.boolOrNull("retainSettingsOverBoot"),
    )

    fun deviceLogToMap(l: PolarDeviceLog): Map<String, Any?> =
        mapOf("path" to l.path, "size" to l.data.size, "data" to l.data)

    // ---- firmware ---------------------------------------------------------

    fun checkFwToMap(s: CheckFirmwareUpdateStatus): Map<String, Any?> = when (s) {
        is CheckFirmwareUpdateStatus.CheckFwUpdateAvailable ->
            mapOf("status" to "available", "version" to s.version, "mandatoryUpdate" to s.mandatoryUpdate)
        is CheckFirmwareUpdateStatus.CheckFwUpdateNotAvailable -> mapOf("status" to "notAvailable", "details" to s.details)
        is CheckFirmwareUpdateStatus.CheckFwUpdateFailed -> mapOf("status" to "failed", "details" to s.details)
    }

    fun fwUpdateToMap(s: FirmwareUpdateStatus): Map<String, Any?> =
        mapOf("status" to (s::class.simpleName ?: "Unknown"), "details" to s.details)

    // ---- telemetry / notifications ---------------------------------------

    fun telemetrySupportToMap(s: DeviceTelemetrySupport): Map<String, Any?> = mapOf(
        "deviceId" to s.deviceId,
        "availableTelemetryTypes" to s.availableTelemetryTypes.map { it.name },
    )

    fun telemetryEventToMap(e: DeviceTelemetryEvent): Map<String, Any?> =
        mapOf("type" to e.type.name, "payload" to e.payload)

    fun telemetryConfigToMap(c: DeviceTelemetryConfiguration?): Map<String, Any?>? = c?.let {
        mapOf(
            "deviceIdentifier" to it.deviceIdentifier,
            "dataUri" to it.dataUri,
            "authorization" to it.authorization,
            "supportedFeatures" to it.supportedFeatures,
        )
    }

    fun d2hToMap(n: PolarD2HNotificationData): Map<String, Any?> = mapOf(
        "notificationType" to n.notificationType.name,
        "parameters" to n.parameters,
        "parsedParameters" to n.parsedParameters?.toString(),
    )

    // ---- packed offline recording (typed arrays, see lib/polar/packed_recording.dart) ----

    /**
     * Whole recording as primitive arrays: LongArray -> Int64List, IntArray -> Int32List,
     * FloatArray -> Float32List, ByteArray -> Uint8List on the Dart side. A day of ACC is
     * millions of samples; one Map per sample would not fit in memory on either side.
     */
    fun offlinePackedToMap(d: PolarOfflineRecordingData): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "kind" to "complete",
            "startTime" to d.startTime.toString(),
            "settings" to sensorSettingToMap(d.settings),
        )
        when (d) {
            is PolarOfflineRecordingData.AccOfflineRecording -> {
                val s = d.data.samples
                out["type"] = "ACC"
                out["sampleCount"] = s.size
                out["ts"] = LongArray(s.size) { s[it].timeStamp }
                out["xyz"] = IntArray(s.size * 3).also { a ->
                    for (i in s.indices) { a[i * 3] = s[i].x; a[i * 3 + 1] = s[i].y; a[i * 3 + 2] = s[i].z }
                }
            }
            is PolarOfflineRecordingData.GyroOfflineRecording -> {
                val s = d.data.samples
                out["type"] = "GYRO"
                out["sampleCount"] = s.size
                out["ts"] = LongArray(s.size) { s[it].timeStamp }
                out["xyzF"] = FloatArray(s.size * 3).also { a ->
                    for (i in s.indices) { a[i * 3] = s[i].x; a[i * 3 + 1] = s[i].y; a[i * 3 + 2] = s[i].z }
                }
            }
            is PolarOfflineRecordingData.MagOfflineRecording -> {
                val s = d.data.samples
                out["type"] = "MAGNETOMETER"
                out["sampleCount"] = s.size
                out["ts"] = LongArray(s.size) { s[it].timeStamp }
                out["xyzF"] = FloatArray(s.size * 3).also { a ->
                    for (i in s.indices) { a[i * 3] = s[i].x; a[i * 3 + 1] = s[i].y; a[i * 3 + 2] = s[i].z }
                }
            }
            is PolarOfflineRecordingData.HrOfflineRecording -> {
                val s = d.data.samples
                out["type"] = "HR"
                out["sampleCount"] = s.size
                out["hr"] = IntArray(s.size) { s[it].hr }
                out["flags"] = ByteArray(s.size) {
                    ((if (s[it].contactStatus) 1 else 0) or (if (s[it].contactStatusSupported) 2 else 0)).toByte()
                }
            }
            is PolarOfflineRecordingData.PpiOfflineRecording -> {
                val s = d.data.samples
                out["type"] = "PPI"
                out["sampleCount"] = s.size
                out["ts"] = LongArray(s.size) { s[it].timeStamp.toLong() }
                out["ppi"] = IntArray(s.size) { s[it].ppi }
                out["errorEstimate"] = IntArray(s.size) { s[it].errorEstimate }
                out["hr"] = IntArray(s.size) { s[it].hr }
                out["flags"] = ByteArray(s.size) {
                    ((if (s[it].blockerBit) 1 else 0) or
                        (if (s[it].skinContactStatus) 2 else 0) or
                        (if (s[it].skinContactSupported) 4 else 0)).toByte()
                }
            }
            else -> {
                out["type"] = d::class.simpleName.orEmpty()
                out["sampleCount"] = 0
            }
        }
        return out
    }

    fun offlinePackedResultToMap(r: PolarOfflineRecordingResult): Map<String, Any?> = when (r) {
        is PolarOfflineRecordingResult.Progress -> mapOf(
            "kind" to "progress",
            "bytesDownloaded" to r.bytesDownloaded,
            "totalBytes" to r.totalBytes,
            "progressPercent" to r.progressPercent,
        )
        is PolarOfflineRecordingResult.Complete -> offlinePackedToMap(r.data)
    }
}
