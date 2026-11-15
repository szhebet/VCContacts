package com.vccontacts.app

import android.app.Application
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Держит FlutterEngine на уровне Application, а не Activity.
 *
 * Благодаря этому при блокировке экрана/уничтожении Activity Flutter-изолят
 * (и фоновая очередь распознавания) продолжает жить, пока жив процесс.
 * Процесс, в свою очередь, удерживает ScanForegroundService.
 */
class VcApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Сами регистрируем плагины ровно один раз.
        val engine = FlutterEngine(this, arrayOf<String>(), false)
        GeneratedPluginRegistrant.registerWith(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)

        // Канал фоновой очереди регистрируем на уровне движка, а не
        // Activity: он должен работать и после уничтожения Activity.
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "vccontacts/scan_service",
        ).setMethodCallHandler { call, result ->
            val text = call.argument<String>("text") ?: "Распознавание визиток…"
            try {
                when (call.method) {
                    "start" -> ScanForegroundService.start(this, text)
                    "update" -> ScanForegroundService.update(this, text)
                    "complete" -> ScanForegroundService.complete(this, text)
                    "stop" -> ScanForegroundService.stop(this)
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                result.error(
                    "scan_service",
                    e.message ?: "foreground service error",
                    null,
                )
            }
        }
        Log.i(TAG, "application-owned FlutterEngine created")
    }

    companion object {
        const val ENGINE_ID = "vc_main_engine"
        const val TAG = "VCContacts"
    }
}
