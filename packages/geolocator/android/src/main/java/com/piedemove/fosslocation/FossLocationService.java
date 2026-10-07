package com.piedemove.fosslocation;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

/**
 * The live trip's location foreground service: while it runs the process
 * keeps receiving the plugin's LocationManager fixes with the screen off. Same
 * notification id and channel as geolocator's service, so the app's own
 * notification code (MainActivity.showTripNotification) rewrites it unchanged.
 */
public class FossLocationService extends Service {
    static final int NOTIFICATION_ID = 75415;
    static final String CHANNEL_ID = "geolocator_channel_01";

    private PowerManager.WakeLock wakeLock;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = intent != null ? intent.getStringExtra("title") : null;
        String text = intent != null ? intent.getStringExtra("text") : null;
        String channelName = intent != null ? intent.getStringExtra("channelName") : null;
        String iconName = intent != null ? intent.getStringExtra("iconName") : null;
        String iconType = intent != null ? intent.getStringExtra("iconType") : null;
        boolean wake = intent != null && intent.getBooleanExtra("wakeLock", false);

        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    channelName != null ? channelName : "Location",
                    NotificationManager.IMPORTANCE_LOW);
            nm.createNotificationChannel(channel);
        }
        int icon = 0;
        if (iconName != null) {
            icon = getResources().getIdentifier(
                    iconName, iconType != null ? iconType : "drawable", getPackageName());
        }
        if (icon == 0) icon = getApplicationInfo().icon;
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent open = launch == null ? null : PendingIntent.getActivity(
                this, 0, launch,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        b.setContentTitle(title != null ? title : "")
                .setContentText(text != null ? text : "")
                .setSmallIcon(icon)
                .setOngoing(true)
                .setOnlyAlertOnce(true);
        if (open != null) b.setContentIntent(open);
        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        } else {
            startForeground(NOTIFICATION_ID, n);
        }
        if (wake && wakeLock == null) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "piedemove:location");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
        super.onDestroy();
    }
}
