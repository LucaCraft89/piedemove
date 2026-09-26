package com.piedemove.piedemove

import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Live trip cues (lib/location/haptics.dart): a full-strength waveform
        // with alarm usage, so "get off now" is felt in a pocket on a bus and
        // is not muted by the touch-feedback setting like a haptic tap is.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piedemove/vibrate")
            .setMethodCallHandler { call, result ->
                if (call.method == "pattern") {
                    val timings = (call.argument<List<Int>>("timings") ?: emptyList())
                        .map { it.toLong() }.toLongArray()
                    val amplitudes = (call.argument<List<Int>>("amplitudes") ?: emptyList())
                        .toIntArray()
                    result.success(vibrate(timings, amplitudes))
                } else if (call.method == "sound") {
                    result.success(playNotificationSound())
                } else {
                    result.notImplemented()
                }
            }
    }

    /// The user's notification sound, once ("scendi ora" with sound on).
    private fun playNotificationSound(): Boolean =
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            RingtoneManager.getRingtone(applicationContext, uri)?.play()
            true
        } catch (e: Exception) {
            false
        }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= 31) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as? Vibrator
        }

    private fun vibrate(timings: LongArray, amplitudes: IntArray): Boolean {
        val v = vibrator() ?: return false
        if (!v.hasVibrator() || timings.isEmpty()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val effect = if (v.hasAmplitudeControl() && amplitudes.size == timings.size) {
                VibrationEffect.createWaveform(timings, amplitudes, -1)
            } else {
                VibrationEffect.createWaveform(timings, -1)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(
                    effect,
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
                )
            }
        } else {
            @Suppress("DEPRECATION")
            v.vibrate(timings, -1)
        }
        return true
    }
}
