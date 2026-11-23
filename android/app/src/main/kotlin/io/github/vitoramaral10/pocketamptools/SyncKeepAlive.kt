package io.github.vitoramaral10.pocketamptools

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app awake while it syncs with paired devices and the screen is
 * off. The sync itself runs in Dart; this only holds the process in the
 * foreground (with the notification Android requires), the CPU awake, and a
 * multicast lock: with the screen off, Android drops broadcast packets, the
 * devices' hellos, for apps that hold none. It goes away with the app when
 * it is swiped out of the recent apps (stopWithTask).
 */
class SyncKeepAlive : Service() {
    private var cpu: PowerManager.WakeLock? = null
    private var multicast: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        if (cpu == null) {
            cpu = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PocketAmpTools:sync")
                .apply { setReferenceCounted(false); acquire() }
        }
        if (multicast == null) {
            multicast = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createMulticastLock("PocketAmpTools:sync")
                .apply { setReferenceCounted(false); acquire() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cpu?.release()
        multicast?.release()
        cpu = null
        multicast = null
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Sync with your devices", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Shown while the app keeps your devices in sync." },
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle("Keeping your devices in sync")
            .setContentText("Your library, backups and preset notes follow your paired devices.")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val ID = 4711
        private const val CHANNEL = "sync"

        fun set(context: Context, on: Boolean) {
            val intent = Intent(context, SyncKeepAlive::class.java)
            if (on) {
                context.startForegroundService(intent)
            } else {
                context.stopService(intent)
            }
        }
    }
}
