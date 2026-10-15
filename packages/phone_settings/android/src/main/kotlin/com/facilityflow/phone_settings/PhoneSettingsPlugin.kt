package com.facilityflow.phone_settings

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reads the settings that decide whether a ring on this phone is heard.
 *
 * Holding the connection open says the app is running, not that anybody will hear it. These
 * live in the phone's own settings, where the host cannot see them: the alarm volume (the
 * app rings on the alarm stream, so a phone set to silent still rings, which makes this the
 * volume that counts), whether the app may post notifications and take over the lock screen,
 * and whether the battery manager has been told to leave it alone.
 */
class PhoneSettingsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.facilityflow/phone_settings")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> result.success(read())
            else -> result.notImplemented()
        }
    }

    private fun read(): Map<String, Any?> {
        val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        val now = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        return mapOf(
            "notificationsOn" to notifications.areNotificationsEnabled(),
            // Android 14 lets the person, or the phone's maker, take this away. Before that it
            // was granted with the app.
            "fullScreenOn" to
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    notifications.canUseFullScreenIntent()
                } else {
                    null
                },
            "batteryExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
            "alarmVolume" to if (max > 0) (now * 100 + max / 2) / max else null,
        )
    }
}
