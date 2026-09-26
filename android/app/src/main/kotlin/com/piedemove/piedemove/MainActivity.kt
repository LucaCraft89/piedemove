package com.piedemove.piedemove

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
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
        // App info and links (lib/app/app_update.dart): the installed version
        // for the update check, and the browser for the APK download.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piedemove/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> result.success(
                        try {
                            packageManager.getPackageInfo(packageName, 0).versionName
                        } catch (e: Exception) {
                            null
                        },
                    )
                    "openUrl" -> result.success(
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            true
                        } catch (e: Exception) {
                            false
                        },
                    )
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                        }
                        result.success(true)
                    }
                    "tripNotification" -> result.success(
                        showTripNotification(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                        ),
                    )
                    "tripNotificationCancel" -> {
                        notificationManager().cancel(TRIP_NOTIFICATION_ID)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
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

    private fun notificationManager() =
        getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    /// Rewrites the location service's foreground notification (same id and
    /// channel as geolocator's GeolocatorLocationService) with the trip's
    /// current instruction; a tap brings the app back. Skipped until the
    /// service has created its channel, so nothing lingers without it.
    private fun showTripNotification(title: String, text: String): Boolean {
        val nm = notificationManager()
        if (Build.VERSION.SDK_INT >= 26 &&
            nm.getNotificationChannel(TRIP_NOTIFICATION_CHANNEL) == null
        ) {
            return false
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, TRIP_NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
        return try {
            nm.notify(TRIP_NOTIFICATION_ID, notification)
            true
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        // geolocator_android's GeolocatorLocationService constants.
        private const val TRIP_NOTIFICATION_ID = 75415
        private const val TRIP_NOTIFICATION_CHANNEL = "geolocator_channel_01"
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
