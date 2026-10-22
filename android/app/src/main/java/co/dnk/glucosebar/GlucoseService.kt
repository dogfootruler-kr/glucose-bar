package co.dnk.glucosebar

import android.app.AlarmManager
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.ZoneId

class GlucoseApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Alerts.createChannels(this)
    }
}

/**
 * Keeps the reading in the status bar (the Android counterpart of the menu bar label) and polls the server every
 * minute, also in Doze, so alerts arrive with the screen off. Each poll is woken by an exact alarm.
 */
class GlucoseService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        scheduleNext()
        val wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GlucoseBar:poll").apply { acquire(60_000) }
        scope.launch {
            try {
                Store.refresh()
                Updater.checkIfDue(this@GlucoseService)
            } finally {
                if (wakeLock.isHeld) wakeLock.release()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        scope.cancel()
        super.onDestroy()
    }

    private fun scheduleNext() {
        val alarms = getSystemService(AlarmManager::class.java)
        val at = SystemClock.elapsedRealtime() + POLL_SECONDS * 1000
        val tick = PendingIntent.getForegroundService(
            this, 0, Intent(this, GlucoseService::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, tick)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, tick)
        }
    }

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val POLL_SECONDS = 60L
        @Volatile private var running = false

        /** Starts polling; from the background Android only allows it in some cases (boot, an update, battery exemption). */
        fun start(context: Context) {
            runCatching { context.startForegroundService(Intent(context, GlucoseService::class.java)) }
        }

        /** Redraws the status bar notification with the current data. */
        fun update(context: Context) {
            if (running) context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(context))
        }

        private fun notification(context: Context): Notification {
            val data = Store.data.value
            val settings = Store.settings.value
            val r = data.reading
            val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())
            val lines = buildList {
                val hit = data.headingLow(settings)
                val in30 = data.in30
                when {
                    hit != null -> add("Heading low: ${settings.format(hit.second)} around ${time.format(hit.first)}")
                    in30 != null -> add("About ${settings.format(in30)} in 30 min")
                }
                (data.fetchError ?: data.state?.error)?.let { add(it) }
                Alerts.snoozedUntil?.let { add("Alerts off until ${time.format(it)}") }
            }
            val builder = Notification.Builder(context, Alerts.READING_CHANNEL)
                .setSmallIcon(statusIcon(context, r?.let { settings.format(it.mgdl) } ?: "--"))
                .setContentTitle(if (r == null) "No reading yet" else "${data.title(settings)} ${settings.unit}")
                .setContentText(lines.joinToString(" · ").ifEmpty { null })
                .setColor(rangeColor(data.range(settings)))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setContentIntent(MainActivity.intent(context))
                .addAction(Notification.Action.Builder(null, "Log", MainActivity.intent(context, "log")).build())
            if (r != null) builder.setWhen(r.timestamp.toEpochMilli()).setShowWhen(true)
            if (settings.showSparkline) {
                val points = data.history(settings.sparklineHours.toDouble())
                if (points.size > 1) {
                    builder.setLargeIcon(Icon.createWithBitmap(
                        Sparkline.render(points, 192, 96, settings, rangeColor(data.range(settings)), dp = 3f),
                    ))
                }
            }
            builder.addAction(
                if (Alerts.isSnoozed) Notification.Action.Builder(null, "Resume alerts", ResumeReceiver.intent(context)).build()
                else Notification.Action.Builder(null, "Stop alerting for 30 min", Alerts.snoozeIntent(context)).build(),
            )
            return builder.build()
        }

        /** The value as a white number for the status bar, which only shows an icon's shape. */
        private fun statusIcon(context: Context, text: String): Icon {
            val size = (24 * context.resources.displayMetrics.density).toInt()
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD)
                textAlign = Paint.Align.CENTER
                textSize = size * 0.8f
            }
            val width = paint.measureText(text)
            if (width > size) paint.textSize *= size / width
            val y = size / 2f - (paint.descent() + paint.ascent()) / 2
            Canvas(bitmap).drawText(text, size / 2f, y, paint)
            return Icon.createWithBitmap(bitmap)
        }
    }
}

fun rangeColor(range: Range): Int = when (range) {
    Range.Low -> 0xFFDC2626.toInt()
    Range.High -> 0xFFEA580C.toInt()
    Range.InRange -> 0xFF16A34A.toInt()
    Range.None -> 0xFF8B93A3.toInt()
}

class ResumeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Store.init(context)
        Alerts.cancelSnooze(context)
    }

    companion object {
        fun intent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, ResumeReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** Starts polling again after a restart or an update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            GlucoseService.start(context)
        }
    }
}
