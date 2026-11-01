package dev.yourmettings.queue_owner

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.IOException
import java.util.UUID

class QueueOwnerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var root: File
    private val engine = UUID.randomUUID().toString()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        root = binding.applicationContext.filesDir
        channel = MethodChannel(binding.binaryMessenger, "yourmettings/queue_owner", StandardMethodCodec.INSTANCE, binding.binaryMessenger.makeBackgroundTaskQueue())
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        QueueOwnerBroker.releaseEngine(engine)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "captureTicket") {
            try { result.success(QueueOwnerBroker.captureTicket(root)) }
            catch (_: Exception) { result.error("storage_failure", "Capture launch unavailable", null) }
            return
        }
        val scope = call.argument<String>("scope")
        if (scope == null || !scope.matches(Regex("[a-f0-9]{64}"))) {
            result.error("invalid_scope", "Invalid queue scope", null)
            return
        }
        try {
            when (call.method) {
                "acquire" -> result.success(QueueOwnerBroker.acquire(root, scope, engine))
                "publish", "eraseFile", "eraseDraft" -> {
                    val token = call.argument<String>("token") ?: error("Missing token")
                    val path = call.argument<String>("path") ?: error("Missing path")
                    when (call.method) {
                        "publish" -> QueueOwnerBroker.publish(root, scope, engine, token, path, call.argument<String>("temporary") ?: error("Missing temporary path"))
                        "eraseFile" -> QueueOwnerBroker.eraseFile(root, scope, engine, token, path)
                        "eraseDraft" -> QueueOwnerBroker.eraseDraft(root, scope, engine, token, path)
                    }
                    result.success(null)
                }
                "captureTicketWrite", "captureTicketClear" -> {
                    val token = call.argument<String>("token") ?: error("Missing token")
                    val nonce = call.argument<String>("nonce") ?: error("Missing nonce")
                    if (call.method == "captureTicketWrite") QueueOwnerBroker.writeCaptureTicket(root, scope, engine, token,
                        call.argument<String>("local_id") ?: error("Missing local ID"), nonce)
                    else QueueOwnerBroker.clearCaptureTicket(root, scope, engine, token, nonce)
                    result.success(null)
                }
                "availableBytes" -> {
                    val token = call.argument<String>("token") ?: error("Missing token")
                    result.success(QueueOwnerBroker.availableBytes(root, scope, engine, token))
                }
                "appendPcm" -> {
                    val token = call.argument<String>("token") ?: error("Missing token")
                    val path = call.argument<String>("path") ?: error("Missing path")
                    val offset = call.argument<Number>("offset")?.toLong() ?: error("Missing offset")
                    val bytes = call.argument<ByteArray>("bytes") ?: error("Missing PCM")
                    result.success(QueueOwnerBroker.appendPcm(root, scope, engine, token, path, offset, bytes))
                }
                "valid", "release" -> {
                    val token = call.argument<String>("token")
                    if (token == null) { result.success(false); return }
                    result.success(if (call.method == "valid")
                        QueueOwnerBroker.valid(root, scope, engine, token)
                    else QueueOwnerBroker.release(root, scope, engine, token))
                }
                else -> result.notImplemented()
            }
        } catch (_: IOException) {
            result.error("storage_failure", "Local storage operation failed", null)
        } catch (_: Exception) {
            // No paths, secrets, or meeting contents in platform error details.
            result.error("owner_unavailable", "Queue ownership unavailable", null)
        }
    }
}
