package `is`.loria.heild.polar

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.launch

/**
 * Turns an SDK [Flow] into a Flutter EventChannel named `heild/polar/stream/<id>`.
 *
 * Dart calls the `openStream` method with a fresh id, then listens on the channel.
 * `onListen` starts collecting; `onCancel` cancels the collecting Job, which is how the
 * SDK stops the underlying measurement on the device.
 */
class StreamChannels(private val messenger: BinaryMessenger, private val scope: CoroutineScope) {

    private val channels = mutableMapOf<String, EventChannel>()
    private val jobs = mutableMapOf<String, Job>()

    fun channelName(id: String) = "heild/polar/stream/$id"

    /** Registers the channel. [flowFactory] runs inside the collecting coroutine, so it may suspend. */
    fun open(id: String, flowFactory: suspend () -> Flow<Any?>) {
        close(id)
        val channel = EventChannel(messenger, channelName(id))
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                jobs[id] = scope.launch {
                    try {
                        flowFactory()
                            .catch { e -> events.error(e::class.simpleName ?: "Error", e.message, null) }
                            .onCompletion { events.endOfStream() }
                            .collect { events.success(it) }
                    } catch (e: Throwable) {
                        if (e !is kotlinx.coroutines.CancellationException) {
                            events.error(e::class.simpleName ?: "Error", e.message, null)
                            events.endOfStream()
                        }
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                jobs.remove(id)?.cancel()
                channels.remove(id)?.setStreamHandler(null)
            }
        })
        channels[id] = channel
    }

    fun close(id: String) {
        jobs.remove(id)?.cancel()
        channels.remove(id)?.setStreamHandler(null)
    }

    fun closeAll() {
        jobs.keys.toList().forEach(::close)
    }
}
