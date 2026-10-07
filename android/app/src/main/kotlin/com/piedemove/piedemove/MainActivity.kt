package com.piedemove.piedemove

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.content.pm.PackageManager
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.SystemClock
import android.os.Vibrator
import android.os.VibratorManager
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var appChannel: MethodChannel? = null

    /// Taps on the trip notification's buttons, forwarded to the live trip
    /// (lib/location/trip_notification.dart) - screen off, phone locked.
    private val tripActions = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            appChannel?.invokeMethod("notificationAction", intent.getStringExtra("action"))
        }
    }
    private var tripActionsRegistered = false

    /// The widget was tapped: ask Dart for fresh departures (home_page.dart).
    private val widgetRefresh = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            appChannel?.invokeMethod("widgetRefresh", null)
        }
    }

    /// Casa / Lavoro tapped on the home-screen widget, until Dart takes it.
    private var widgetAction: String? = null

    private fun captureWidgetAction(intent: Intent?) {
        intent?.getStringExtra(NextDeparturesWidget.EXTRA_ACTION)?.let {
            widgetAction = it
            intent.removeExtra(NextDeparturesWidget.EXTRA_ACTION)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureWidgetAction(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (tripActionsRegistered) {
            unregisterReceiver(tripActions)
            unregisterReceiver(widgetRefresh)
            tripActionsRegistered = false
        }
        appChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        captureWidgetAction(intent)
        if (!tripActionsRegistered) {
            val filter = IntentFilter(TRIP_ACTION)
            val refresh = IntentFilter(NextDeparturesWidget.APP_REFRESH)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(tripActions, filter, Context.RECEIVER_NOT_EXPORTED)
                registerReceiver(widgetRefresh, refresh, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(tripActions, filter)
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(widgetRefresh, refresh)
            }
            tripActionsRegistered = true
        }
        // Live trip cues (lib/location/haptics.dart): a full-strength waveform
        // with alarm usage, so "get off now" is felt in a pocket on a bus and
        // is not muted by the touch-feedback setting like a haptic tap is.
        // App info and links (lib/app/app_update.dart): the installed version
        // for the update check, and the browser for the APK download.
        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piedemove/app")
        appChannel!!.setMethodCallHandler { call, result ->
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
                            call.argument<Int>("progress") ?: -1,
                            call.argument<String>("primary"),
                        ),
                    )
                    "widget" -> {
                        NextDeparturesWidget.save(this, call.argument<String>("json") ?: "")
                        result.success(true)
                    }
                    "takeWidgetAction" -> {
                        result.success(widgetAction)
                        widgetAction = null
                    }
                    "tripNotificationCancel" -> {
                        notificationManager().cancel(TRIP_NOTIFICATION_ID)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Position dot heading (lib/location/compass.dart): the way the phone
        // points, true north, with an accuracy estimate for the beam width.
        // The sensor only runs while Dart listens (map in the foreground).
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "piedemove/heading")
            .setStreamHandler(compass)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piedemove/heading_cfg")
            .setMethodCallHandler { call, result ->
                if (call.method == "location") {
                    compass.setLocation(
                        call.argument<Double>("lat") ?: 0.0,
                        call.argument<Double>("lon") ?: 0.0,
                        call.argument<Double>("alt") ?: 0.0,
                    )
                    result.success(true)
                } else {
                    result.notImplemented()
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

    override fun onDestroy() {
        compass.onCancel(null)
        super.onDestroy()
    }

    private val compass by lazy { Compass() }

    /// Heading from the fused rotation-vector sensor (gyro + accelerometer +
    /// magnetometer, the source map apps use), else the geomagnetic one,
    /// else raw accelerometer + magnetometer. Emits {deg, acc} at most
    /// ~12 times a second and only on a change of a degree or more.
    private inner class Compass : EventChannel.StreamHandler, SensorEventListener {
        private val sm get() = getSystemService(SENSOR_SERVICE) as SensorManager
        private var sink: EventChannel.EventSink? = null
        private var declination = 0f
        private var status = SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM
        private var rawMode = false
        private val gravity = FloatArray(3)
        private val geomag = FloatArray(3)
        private var haveGravity = false
        private var haveGeomag = false
        private val r = FloatArray(9)

        // Smoothed heading as a unit vector: averaging angles breaks at 0/360.
        private var sx = 0.0
        private var sy = 0.0
        private var primed = false
        private var lastSentDeg = -1000.0
        private var lastSentAcc = -1.0
        private var lastSentAt = 0L

        fun setLocation(lat: Double, lon: Double, alt: Double) {
            declination = GeomagneticField(
                lat.toFloat(), lon.toFloat(), alt.toFloat(), System.currentTimeMillis(),
            ).declination
        }

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
            primed = false
            lastSentDeg = -1000.0
            val fused = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
                ?: sm.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR)
            if (fused != null) {
                rawMode = false
                sm.registerListener(this, fused, SensorManager.SENSOR_DELAY_GAME)
                return
            }
            val acc = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            val mag = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
            if (acc == null || mag == null) {
                events?.error("no_sensor", "no compass on this phone", null)
                return
            }
            rawMode = true
            haveGravity = false
            haveGeomag = false
            sm.registerListener(this, acc, SensorManager.SENSOR_DELAY_GAME)
            sm.registerListener(this, mag, SensorManager.SENSOR_DELAY_GAME)
        }

        override fun onCancel(arguments: Any?) {
            sink = null
            sm.unregisterListener(this)
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
            if (sensor?.type != Sensor.TYPE_ACCELEROMETER) status = accuracy
        }

        override fun onSensorChanged(e: SensorEvent) {
            var accDeg = -1.0
            when (e.sensor.type) {
                Sensor.TYPE_ACCELEROMETER -> {
                    lowPass(e.values, gravity)
                    haveGravity = true
                    return
                }
                Sensor.TYPE_MAGNETIC_FIELD -> {
                    lowPass(e.values, geomag)
                    haveGeomag = true
                    if (!haveGravity ||
                        !SensorManager.getRotationMatrix(r, null, gravity, geomag)
                    ) {
                        return
                    }
                }
                else -> {
                    SensorManager.getRotationMatrixFromVector(r, e.values)
                    // values[4]: estimated heading accuracy, radians (-1 unknown).
                    if (e.values.size > 4 && e.values[4] > 0f) {
                        accDeg = Math.toDegrees(e.values[4].toDouble())
                    }
                }
            }
            if (accDeg < 0) {
                accDeg = when (status) {
                    SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> 15.0
                    SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> 30.0
                    SensorManager.SENSOR_STATUS_ACCURACY_LOW -> 50.0
                    else -> 90.0
                }
            }
            // r maps phone axes to (east, north, up). The way the rider faces
            // is the screen's top edge when the phone lies flat and the back
            // camera when it stands up: summing both horizontal projections
            // is continuous across every tilt in between.
            val (ux, uy) = screenUp()
            val topE = r[0] * ux + r[1] * uy
            val topN = r[3] * ux + r[4] * uy
            val e0 = topE - r[2]
            val n0 = topN - r[5]
            if (e0 * e0 + n0 * n0 < 1e-4) return // pointing straight up/down
            val a = Math.atan2(e0.toDouble(), n0.toDouble())
            val cx = Math.sin(a)
            val cy = Math.cos(a)
            if (!primed) {
                sx = cx
                sy = cy
                primed = true
            } else {
                // Light smoothing: the fused sensor is already steady.
                val k = if (rawMode) 0.15 else 0.35
                sx += (cx - sx) * k
                sy += (cy - sy) * k
            }
            val deg = (Math.toDegrees(Math.atan2(sx, sy)) + declination + 360.0) % 360.0
            val now = SystemClock.elapsedRealtime()
            var d = Math.abs(deg - lastSentDeg) % 360.0
            if (d > 180) d = 360 - d
            if (now - lastSentAt < 80) return
            if (d < 1.0 && Math.abs(accDeg - lastSentAcc) < 5) return
            lastSentAt = now
            lastSentDeg = deg
            lastSentAcc = accDeg
            sink?.success(mapOf("deg" to deg, "acc" to accDeg))
        }

        private fun lowPass(input: FloatArray, out: FloatArray) {
            for (i in 0..2) out[i] += (input[i] - out[i]) * 0.2f
        }

        /// The screen's top edge in phone axes (x right, y top), for the
        /// current display rotation.
        private fun screenUp(): Pair<Float, Float> {
            val rotation = try {
                if (Build.VERSION.SDK_INT >= 30) {
                    display?.rotation ?: Surface.ROTATION_0
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay.rotation
                }
            } catch (e: Exception) {
                Surface.ROTATION_0
            }
            return when (rotation) {
                Surface.ROTATION_90 -> Pair(1f, 0f)
                Surface.ROTATION_180 -> Pair(0f, -1f)
                Surface.ROTATION_270 -> Pair(-1f, 0f)
                else -> Pair(0f, 1f)
            }
        }
    }

    private fun notificationManager() =
        getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    /// Rewrites the location service's foreground notification (same id and
    /// channel as geolocator's GeolocatorLocationService) with the trip's
    /// current instruction; a tap brings the app back. Skipped until the
    /// service has created its channel, so nothing lingers without it.
    private fun tripAction(action: String, code: Int): PendingIntent =
        PendingIntent.getBroadcast(
            this,
            code,
            Intent(TRIP_ACTION).setPackage(packageName).putExtra("action", action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /// [progress] 0..100 of the trip's length, -1 for none; [primary] the
    /// label of the "advance" button (Sono salito / Sono sceso / Sono
    /// arrivato), null for none. "Termina" is always there.
    private fun showTripNotification(
        title: String,
        text: String,
        progress: Int,
        primary: String?,
    ): Boolean {
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
        builder
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_stat_piedemove)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
        if (progress in 0..100) builder.setProgress(100, progress, false)
        val icon = Icon.createWithResource(this, R.drawable.ic_stat_piedemove)
        if (primary != null) {
            builder.addAction(
                Notification.Action.Builder(icon, primary, tripAction("advance", 1)).build(),
            )
        }
        builder.addAction(
            Notification.Action.Builder(icon, "Termina", tripAction("stop", 2)).build(),
        )
        val notification = builder.build()
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
        private const val TRIP_ACTION = "com.piedemove.piedemove.TRIP_ACTION"
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
