package com.piedemove.fosslocation;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Location for the F-Droid build, on Android's own LocationManager: GPS at
 * 1 Hz, the network provider (Wi-Fi / cell) only while GPS is silent, so a
 * first fix indoors still comes. Permission, settings and the foreground
 * service for screen-off tracking. No Google Play Services.
 */
public class FossLocationPlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
        PluginRegistry.RequestPermissionsResultListener {

    private static final int PERMISSION_REQUEST = 34211;
    /** A network fix is dropped while GPS answered this recently (ms). */
    private static final long GPS_FRESH_MS = 10_000;

    private Context context;
    private Activity activity;
    private ActivityPluginBinding activityBinding;
    private MethodChannel methods;
    private EventChannel updates;
    private EventChannel.EventSink sink;
    private MethodChannel.Result pendingPermission;
    private long lastGpsAt = -GPS_FRESH_MS;

    private final LocationListener listener = new LocationListener() {
        @Override
        public void onLocationChanged(Location l) {
            onFix(l);
        }

        @Override
        public void onProviderEnabled(String provider) {}

        @Override
        public void onProviderDisabled(String provider) {
            if (sink != null && !servicesEnabled()) {
                sink.error("LOCATION_SERVICES_DISABLED", "Location services are disabled", null);
            }
        }

        @Override
        public void onStatusChanged(String provider, int status, Bundle extras) {}
    };

    // --- FlutterPlugin / ActivityAware ---

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        methods = new MethodChannel(binding.getBinaryMessenger(), "piedemove/foss_location");
        methods.setMethodCallHandler(this);
        updates = new EventChannel(binding.getBinaryMessenger(), "piedemove/foss_location/updates");
        updates.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        stopUpdates();
        methods.setMethodCallHandler(null);
        updates.setStreamHandler(null);
    }

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) activityBinding.removeRequestPermissionsResultListener(this);
        activityBinding = null;
        activity = null;
    }

    // --- Methods ---

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "checkPermission":
                result.success(permission());
                break;
            case "requestPermission":
                requestPermission(result);
                break;
            case "isLocationServiceEnabled":
                result.success(servicesEnabled());
                break;
            case "getLastKnownPosition": {
                Location l = lastKnown();
                result.success(l == null ? null : toMap(l));
                break;
            }
            case "openAppSettings":
                result.success(open(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + context.getPackageName()))));
                break;
            case "openLocationSettings":
                result.success(open(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));
                break;
            case "startForeground": {
                Intent i = new Intent(context, FossLocationService.class);
                i.putExtra("title", (String) call.argument("title"));
                i.putExtra("text", (String) call.argument("text"));
                i.putExtra("channelName", (String) call.argument("channelName"));
                i.putExtra("iconName", (String) call.argument("iconName"));
                i.putExtra("iconType", (String) call.argument("iconType"));
                Boolean wake = call.argument("wakeLock");
                i.putExtra("wakeLock", wake != null && wake);
                try {
                    if (Build.VERSION.SDK_INT >= 26) {
                        context.startForegroundService(i);
                    } else {
                        context.startService(i);
                    }
                    result.success(true);
                } catch (Exception e) {
                    result.error("FOREGROUND", e.toString(), null);
                }
                break;
            }
            case "stopForeground":
                context.stopService(new Intent(context, FossLocationService.class));
                result.success(true);
                break;
            default:
                result.notImplemented();
        }
    }

    private boolean granted(String p) {
        return context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean hasLocation() {
        return granted(Manifest.permission.ACCESS_FINE_LOCATION)
                || granted(Manifest.permission.ACCESS_COARSE_LOCATION);
    }

    private SharedPreferences prefs() {
        return context.getSharedPreferences("piedemove_foss_location", Context.MODE_PRIVATE);
    }

    /** 0 denied, 1 denied forever, 2 while in use, 3 always. */
    private int permission() {
        if (hasLocation()) {
            if (Build.VERSION.SDK_INT >= 29
                    && granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)) {
                return 3;
            }
            return 2;
        }
        // Asked before, and Android no longer shows the dialog: "forever".
        boolean asked = prefs().getBoolean("asked", false);
        if (asked && activity != null
                && !activity.shouldShowRequestPermissionRationale(
                        Manifest.permission.ACCESS_FINE_LOCATION)) {
            return 1;
        }
        return 0;
    }

    private void requestPermission(MethodChannel.Result result) {
        if (hasLocation()) {
            result.success(permission());
            return;
        }
        if (activity == null || pendingPermission != null) {
            result.success(permission());
            return;
        }
        pendingPermission = result;
        prefs().edit().putBoolean("asked", true).apply();
        activity.requestPermissions(new String[] {
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
        }, PERMISSION_REQUEST);
    }

    @Override
    public boolean onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (code != PERMISSION_REQUEST || pendingPermission == null) return false;
        MethodChannel.Result r = pendingPermission;
        pendingPermission = null;
        r.success(permission());
        return true;
    }

    private boolean open(Intent i) {
        try {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(i);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private LocationManager lm() {
        return (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
    }

    private boolean servicesEnabled() {
        LocationManager m = lm();
        if (m == null) return false;
        if (Build.VERSION.SDK_INT >= 28) return m.isLocationEnabled();
        return m.isProviderEnabled(LocationManager.GPS_PROVIDER)
                || m.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
    }

    @SuppressWarnings("MissingPermission")
    private Location lastKnown() {
        if (!hasLocation()) return null;
        LocationManager m = lm();
        Location best = null;
        for (String p : m.getProviders(true)) {
            Location l;
            try {
                l = m.getLastKnownLocation(p);
            } catch (Exception e) {
                continue;
            }
            if (l == null) continue;
            if (best == null || l.getTime() > best.getTime()) best = l;
        }
        return best;
    }

    // --- Updates ---

    @Override
    @SuppressWarnings("MissingPermission")
    public void onListen(Object arguments, EventChannel.EventSink events) {
        sink = events;
        if (!hasLocation()) {
            events.error("PERMISSION_DENIED", "Location permission not granted", null);
            return;
        }
        if (!servicesEnabled()) {
            events.error("LOCATION_SERVICES_DISABLED", "Location services are disabled", null);
            return;
        }
        LocationManager m = lm();
        try {
            if (m.getAllProviders().contains(LocationManager.GPS_PROVIDER)) {
                m.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0f, listener,
                        Looper.getMainLooper());
            }
            if (m.getAllProviders().contains(LocationManager.NETWORK_PROVIDER)) {
                m.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 1000, 0f, listener,
                        Looper.getMainLooper());
            }
        } catch (Exception e) {
            events.error("LOCATION_UNAVAILABLE", e.toString(), null);
            return;
        }
        // A recent last fix at once, so the dot appears before GPS warms up.
        Location last = lastKnown();
        if (last != null && System.currentTimeMillis() - last.getTime() < 120_000) {
            events.success(toMap(last));
        }
    }

    @Override
    public void onCancel(Object arguments) {
        stopUpdates();
    }

    private void stopUpdates() {
        try {
            lm().removeUpdates(listener);
        } catch (Exception ignored) {
        }
        sink = null;
    }

    private void onFix(Location l) {
        if (sink == null) return;
        long now = SystemClock.elapsedRealtime();
        if (LocationManager.GPS_PROVIDER.equals(l.getProvider())) {
            lastGpsAt = now;
        } else if (now - lastGpsAt < GPS_FRESH_MS) {
            return; // GPS is live: a coarse network fix would only blur it
        }
        sink.success(toMap(l));
    }

    private static Map<String, Object> toMap(Location l) {
        Map<String, Object> m = new HashMap<>();
        m.put("latitude", l.getLatitude());
        m.put("longitude", l.getLongitude());
        m.put("timestamp", l.getTime());
        m.put("accuracy", l.hasAccuracy() ? (double) l.getAccuracy() : 0.0);
        m.put("altitude", l.hasAltitude() ? l.getAltitude() : 0.0);
        m.put("heading", l.hasBearing() ? (double) l.getBearing() : -1.0);
        m.put("speed", l.hasSpeed() ? (double) l.getSpeed() : 0.0);
        if (Build.VERSION.SDK_INT >= 26) {
            m.put("altitude_accuracy",
                    l.hasVerticalAccuracy() ? (double) l.getVerticalAccuracyMeters() : 0.0);
            m.put("heading_accuracy",
                    l.hasBearingAccuracy() ? (double) l.getBearingAccuracyDegrees() : 0.0);
            m.put("speed_accuracy",
                    l.hasSpeedAccuracy() ? (double) l.getSpeedAccuracyMetersPerSecond() : 0.0);
        }
        m.put("is_mocked", Build.VERSION.SDK_INT >= 31 ? l.isMock() : l.isFromMockProvider());
        return m;
    }
}
