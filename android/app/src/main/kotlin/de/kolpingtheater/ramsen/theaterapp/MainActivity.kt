package de.kolpingtheater.ramsen.theaterapp

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val reminders = NotificationChannel(
                "theater_updates",
                getString(R.string.reminder_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = getString(R.string.reminder_channel_description)
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(reminders)
        }
    }

    // Device facts for the anonymous performance telemetry
    // (lib/core/telemetry/perf_platform_io.dart); no extra plugin needed.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "theater/device")
            .setMethodCallHandler { call, result ->
                if (call.method != "info") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val memory = ActivityManager.MemoryInfo()
                getSystemService(ActivityManager::class.java)?.getMemoryInfo(memory)
                result.success(
                    mapOf(
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "sdk" to Build.VERSION.SDK_INT,
                        "release" to Build.VERSION.RELEASE,
                        "memoryMb" to (memory.totalMem / (1024 * 1024)).toInt(),
                        "processAgeMs" to (SystemClock.uptimeMillis() - Process.getStartUptimeMillis()).toInt(),
                    ),
                )
            }
    }
}
