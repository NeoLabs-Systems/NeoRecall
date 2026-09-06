package systems.neolabs.plaud_sdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.tinnotech.penblesdk.entity.BleDevice
import com.tinnotech.penblesdk.entity.BleFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking
import sdk.NiceBuildSdk
import sdk.PlaudDeviceAgent
import sdk.PlaudDeviceAgentListener
import sdk.audio.AudioExportFormat
import sdk.audio.AudioExporter

/// Flutter bridge for Plaud's Android Embedded SDK. Method and event names
/// match the iOS plugin so Dart stays platform-agnostic.
class PlaudSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectExecutor = Executors.newSingleThreadExecutor()
    private val scanned = ConcurrentHashMap<String, BleDevice>()
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private var userId: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "plaud_sdk/methods")
        events = EventChannel(binding.binaryMessenger, "plaud_sdk/events")
        channel?.setMethodCallHandler(this)
        events?.setStreamHandler(this)
        PlaudDeviceAgent.listener = agentListener
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        channel = null
        events = null
        eventSink = null
        PlaudDeviceAgent.listener = null
        connectExecutor.shutdownNow()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initSDK" -> initSdk(call, result)
            "startScan" -> {
                PlaudDeviceAgent.startScan()
                result.success(null)
            }
            "stopScan" -> {
                PlaudDeviceAgent.stopScan()
                result.success(null)
            }
            "connectBleDevice" -> connectBleDevice(call, result)
            "disconnect" -> {
                PlaudDeviceAgent.disconnect()
                result.success(null)
            }
            "depair" -> {
                PlaudDeviceAgent.depair(call.argument<Boolean>("clear") ?: true)
                result.success(null)
            }
            "isConnected" -> result.success(mapOf("connected" to PlaudDeviceAgent.isConnected()))
            "getFileList" -> {
                val start = asLong(call.argument("startSessionId")) ?: 0L
                PlaudDeviceAgent.getFileList(start)
                result.success(null)
            }
            "exportAudio" -> exportAudio(call, result)
            "deleteFile" -> {
                val sessionId = asLong(call.argument("sessionId"))
                if (sessionId == null) {
                    result.error("ERR_PLAUD_ARGS", "sessionId is required", null)
                    return
                }
                PlaudDeviceAgent.deleteFile(sessionId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initSdk(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("userAccessToken").orEmpty()
        val domain = call.argument<String>("customDomain").orEmpty()
        if (token.isEmpty() || domain.isEmpty()) {
            result.error(
                "ERR_PLAUD_ARGS",
                "userAccessToken and customDomain are required",
                null,
            )
            return
        }
        val ctx = appContext
        if (ctx == null) {
            result.error("ERR_PLAUD_INIT", "Android context is not ready", null)
            return
        }
        userId = call.argument("userId")
        val host = domain.removePrefix("https://").removePrefix("http://")
        try {
            NiceBuildSdk.getPartnerApiManager().updateBaseUrl("https://$host")
        } catch (_: Exception) {
            // Handshake still uses the domain passed to initSDK.
        }
        PlaudDeviceAgent.listener = agentListener
        PlaudDeviceAgent.initSDK(ctx, token, host)
        result.success(null)
    }

    private fun connectBleDevice(call: MethodCall, result: MethodChannel.Result) {
        val uuid = call.argument<String>("uuid")
        val serial = call.argument<String>("serialNumber")
        val token = call.argument<String>("deviceToken") ?: userId
        val device = lookup(uuid, serial)
        if (device == null) {
            result.error(
                "ERR_PLAUD_UNKNOWN_DEVICE",
                "Unknown device — scan first, then connect by uuid or serialNumber",
                null,
            )
            return
        }
        result.success(null)
        connectExecutor.execute {
            val sn = device.serialNumber.orEmpty()
            val deadline = System.currentTimeMillis() + 10_000L
            while (!NiceBuildSdk.isPartnerDataReady() && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(200)
                } catch (_: InterruptedException) {
                    return@execute
                }
            }
            if (sn.isNotEmpty()) {
                runBlocking {
                    NiceBuildSdk.signAndStoreDeviceSn(deviceType(sn), sn)
                }
            }
            if (!token.isNullOrEmpty()) {
                PlaudDeviceAgent.connectBleDevice(device, token)
            } else {
                PlaudDeviceAgent.connectBleDevice(device)
            }
        }
    }

    private fun exportAudio(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = asLong(call.argument("sessionId"))
        if (sessionId == null) {
            result.error("ERR_PLAUD_ARGS", "sessionId is required", null)
            return
        }
        val ctx = appContext
        if (ctx == null) {
            result.error("ERR_PLAUD_INIT", "Android context is not ready", null)
            return
        }
        val dir = File(ctx.filesDir, "PlaudExports")
        dir.mkdirs()
        val format = exportFormat(call.argument("format"))
        val channels = call.argument<Int>("channels") ?: 1
        PlaudDeviceAgent.exportAudio(
            sessionId,
            dir,
            format,
            channels,
            object : AudioExporter.ExportCallback {
                override fun onProgress(progress: Int, message: String) {
                    emit(
                        "exportProgress",
                        mapOf(
                            "sessionId" to sessionId,
                            "progress" to progress,
                            "message" to message,
                        ),
                    )
                }

                override fun onComplete(outputFile: File) {
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "sessionId" to sessionId,
                                "outputPath" to outputFile.absolutePath,
                            ),
                        )
                    }
                }

                override fun onError(error: String) {
                    mainHandler.post {
                        result.error("ERR_PLAUD_EXPORT", error, null)
                    }
                }
            },
        )
    }

    private fun lookup(uuid: String?, serial: String?): BleDevice? {
        if (!uuid.isNullOrEmpty()) {
            scanned[uuid]?.let { return it }
            scanned.values.firstOrNull { it.macAddress == uuid }?.let { return it }
        }
        if (!serial.isNullOrEmpty()) {
            return scanned.values.firstOrNull { it.serialNumber == serial }
        }
        return null
    }

    private fun cache(devices: List<BleDevice>) {
        for (device in devices) {
            val key = device.macAddress ?: device.serialNumber ?: continue
            scanned[key] = device
            val sn = device.serialNumber
            if (!sn.isNullOrEmpty()) scanned[sn] = device
        }
    }

    private fun emit(event: String, body: Map<String, Any?>) {
        mainHandler.post {
            val payload = HashMap<String, Any?>(body.size + 1)
            payload["event"] = event
            payload.putAll(body)
            eventSink?.success(payload)
        }
    }

    private val agentListener = object : PlaudDeviceAgentListener {
        override fun bleScanResult(devices: List<BleDevice>) {
            cache(devices)
            emit(
                "scanResult",
                mapOf(
                    "devices" to devices.map { device ->
                        mapOf(
                            "name" to (device.name ?: ""),
                            "uuid" to (device.macAddress ?: device.serialNumber ?: ""),
                            "serialNumber" to (device.serialNumber ?: ""),
                            "rssi" to device.rssi,
                            "supportWiFi" to !device.wiFiName.isNullOrEmpty(),
                        )
                    },
                ),
            )
        }

        override fun bleScanOverTime() {
            emit("scanTimeout", emptyMap())
        }

        override fun bleConnectState(state: Int) {
            val failed = state == 2 || state == -1 || state == -2
            emit(
                "connectState",
                mapOf(
                    "connected" to (state == 1),
                    "failed" to failed,
                    "state" to state,
                ),
            )
        }

        override fun bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
            emit(
                "bind",
                mapOf(
                    "sn" to sn,
                    "status" to status,
                    "protVersion" to protVersion,
                ),
            )
        }

        override fun blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int) {
            emit(
                "penState",
                mapOf(
                    "state" to state,
                    "privacy" to privacy,
                    "keyState" to keyState,
                    "uDisk" to uDisk,
                ),
            )
        }

        override fun bleRecordStart(
            sessionId: Long,
            start: Long,
            status: Int,
            scene: Int,
            startTime: Long,
            reason: Int,
        ) {
            emit(
                "recordStart",
                mapOf(
                    "sessionId" to sessionId,
                    "start" to start,
                    "status" to status,
                    "scene" to scene,
                    "startTime" to startTime,
                    "reason" to reason,
                ),
            )
        }

        override fun bleRecordStop(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
            emit(
                "recordStop",
                mapOf(
                    "sessionId" to sessionId,
                    "reason" to reason,
                    "fileExist" to fileExist,
                    "fileSize" to fileSize,
                ),
            )
        }

        override fun bleRecordPause(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
            emit(
                "recordPause",
                mapOf(
                    "sessionId" to sessionId,
                    "reason" to reason,
                    "fileExist" to fileExist,
                    "fileSize" to fileSize,
                ),
            )
        }

        override fun bleRecordResume(
            sessionId: Long,
            start: Long,
            status: Int,
            scene: Int,
            startTime: Long,
        ) {
            emit(
                "recordResume",
                mapOf(
                    "sessionId" to sessionId,
                    "start" to start,
                    "status" to status,
                    "scene" to scene,
                    "startTime" to startTime,
                ),
            )
        }

        override fun bleDepair(status: Int) {
            emit("depair", mapOf("status" to status))
        }

        override fun bleDeleteFile(sessionId: Long, status: Int) {
            emit("deleteFile", mapOf("sessionId" to sessionId, "status" to status))
        }

        override fun bleChargingState(isCharging: Boolean, level: Int) {
            emit("chargingState", mapOf("isCharging" to isCharging, "level" to level))
        }

        override fun bleFileList(files: List<BleFile>) {
            emit(
                "fileList",
                mapOf(
                    "files" to files.map { file ->
                        mapOf(
                            "sn" to "",
                            "sessionId" to file.sessionId,
                            "size" to file.fileSize,
                            "scenes" to file.scene,
                            "channels" to 1,
                            "isOgg" to false,
                            "isMusic" to file.isMusic,
                            "duration" to 0,
                        )
                    },
                ),
            )
        }
    }

    companion object {
        private fun asLong(value: Any?): Long? = when (value) {
            is Number -> value.toLong()
            is String -> value.toLongOrNull()
            else -> null
        }

        private fun deviceType(sn: String): String = when {
            sn.startsWith("881") -> "notepro"
            sn.startsWith("880") -> "notepin"
            sn.startsWith("882") -> "notepins"
            sn.startsWith("888") -> "note"
            else -> "note"
        }

        private fun exportFormat(raw: String?): AudioExportFormat =
            when ((raw ?: "mp3").lowercase()) {
                "pcm" -> AudioExportFormat.PCM
                "wav" -> AudioExportFormat.WAV
                "opus" -> AudioExportFormat.OPUS
                else -> AudioExportFormat.MP3
            }
    }
}
