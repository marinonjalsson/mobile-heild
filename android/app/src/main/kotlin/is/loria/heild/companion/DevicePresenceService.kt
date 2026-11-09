package `is`.loria.heild.companion

import android.companion.AssociationInfo
import android.companion.CompanionDeviceManager
import android.companion.DevicePresenceEvent
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import com.polar.androidcommunications.common.ble.companion.PolarCompanionDeviceServiceBase
import `is`.loria.heild.EngineHolder
import `is`.loria.heild.service.HeildService

/**
 * Android binds this service when the associated sensor comes into BLE range (the SDK
 * registered the observation; our manifest replaces the SDK's own service with this one).
 * On "appeared" it makes sure the Flutter engine is up and starts the foreground service,
 * then lets the SDK base class forward the event to Dart through the Polar callback
 * (`companionDeviceAppeared`), where the sync decides what to do.
 */
@RequiresApi(Build.VERSION_CODES.S)
class DevicePresenceService : PolarCompanionDeviceServiceBase() {

    private fun wake() {
        EngineHolder.ensure(this)
        HeildService.start(this)
    }

    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        wake()
        super.onDeviceAppeared(associationInfo)
    }

    @Suppress("DEPRECATION")
    override fun onDeviceAppeared(address: String) {
        wake()
        super.onDeviceAppeared(address)
    }

    /** API 36+ event form; routed into the legacy callbacks the SDK listens to. */
    @RequiresApi(36)
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        super.onDevicePresenceEvent(event)
        val cdm = getSystemService(Context.COMPANION_DEVICE_SERVICE) as CompanionDeviceManager
        val info = cdm.myAssociations.firstOrNull { it.id == event.associationId } ?: return
        when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED, DevicePresenceEvent.EVENT_BT_CONNECTED ->
                onDeviceAppeared(info)
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED, DevicePresenceEvent.EVENT_BT_DISCONNECTED ->
                onDeviceDisappeared(info)
        }
    }
}
