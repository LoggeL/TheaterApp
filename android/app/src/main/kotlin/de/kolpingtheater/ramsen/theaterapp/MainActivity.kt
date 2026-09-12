package de.kolpingtheater.ramsen.theaterapp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

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
}
