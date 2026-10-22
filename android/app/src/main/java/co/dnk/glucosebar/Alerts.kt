package co.dnk.glucosebar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import kotlinx.coroutines.flow.MutableStateFlow
import java.time.Instant

/**
 * Posts notifications for low/high/fast-drop/heading-low/no-data, repeating every 20 minutes while a condition lasts
 * (rules in AlertRules.kt). Lows go to a channel that can break through Do Not Disturb.
 */
object Alerts {
    const val READING_CHANNEL = "glucose"
    private const val ALERT_CHANNEL = "alerts"
    private const val URGENT_CHANNEL = "urgent"
    /** Channels can't be changed after they're created, so the one made after Do Not Disturb access is granted is separate. */
    private const val URGENT_DND_CHANNEL = "urgent_dnd"
    const val UPDATE_CHANNEL = "updates"
    private const val SNOOZE_MINUTES = 30L

    /** Remembered in the settings, so a restart of the app doesn't post an alert again within 20 minutes. */
    private val throttle by lazy {
        AlertThrottle(Condition.entries.associateWith { Instant.ofEpochSecond(Store.pref("notified.${it.name}")) }
            .filterValues { it.epochSecond > 0 }.toMutableMap())
    }

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    fun createChannels(context: Context) {
        val m = manager(context)
        // Default importance (but silent), because Android leaves low-importance icons out of the status bar.
        m.createNotificationChannel(NotificationChannel(READING_CHANNEL, "Current glucose", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "The latest reading, always shown while GlucoseBar runs"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        })
        m.createNotificationChannel(NotificationChannel(ALERT_CHANNEL, "High and no data", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "High glucose, no data, and the weekly summary"
        })
        m.createNotificationChannel(NotificationChannel(UPDATE_CHANNEL, "Updates", NotificationManager.IMPORTANCE_DEFAULT))
        urgentChannel(context)
    }

    /** The channel for lows, created with "Override Do Not Disturb" once the app may set it. */
    private fun urgentChannel(context: Context): String {
        val m = manager(context)
        val id = if (m.isNotificationPolicyAccessGranted) URGENT_DND_CHANNEL else URGENT_CHANNEL
        if (m.getNotificationChannel(id) == null) {
            m.createNotificationChannel(NotificationChannel(id, "Low glucose", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Low, dropping fast and heading low"
                setBypassDnd(true)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 400, 200, 400, 200, 400)
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
                )
            })
            if (id == URGENT_DND_CHANNEL) m.deleteNotificationChannel(URGENT_CHANNEL)
        }
        return id
    }

    /** Whether lows will sound in Do Not Disturb. */
    fun lowsBreakThroughDnd(context: Context): Boolean =
        manager(context).getNotificationChannel(urgentChannel(context))?.canBypassDnd() == true

    // MARK: snooze

    val snoozedUntil: Instant?
        get() = Instant.ofEpochSecond(Store.pref("snoozedUntil")).takeIf { it > Instant.now() }

    val isSnoozed get() = snoozedUntil != null

    /** Changes whenever alerts are snoozed or resumed, for screens showing it. */
    val snoozeChanges = MutableStateFlow(0)

    fun snooze(context: Context) {
        Store.setPref("snoozedUntil", Instant.now().plusSeconds(SNOOZE_MINUTES * 60).epochSecond)
        Condition.entries.forEach { manager(context).cancel(it.ordinal + 100) }
        snoozeChanges.value++
        GlucoseService.update(context)
    }

    fun cancelSnooze(context: Context) {
        Store.setPref("snoozedUntil", 0)
        snoozeChanges.value++
        GlucoseService.update(context)
    }

    fun snoozeIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 0, Intent(context, SnoozeReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
    )

    // MARK: posting

    @Synchronized
    fun evaluate(context: Context, data: Data, settings: Settings) {
        val now = Instant.now()
        val active = activeAlerts(
            data.reading, data.state?.forecast, data.postExercise, data.isStale(settings, now), data.staleSince, settings, now,
        )
        for (alert in throttle.due(active, now, settings.alertsEnabled, isSnoozed)) {
            post(context, alert.condition.ordinal + 100, alert.title, alert.body, urgent = alert.condition.urgent)
        }
        Condition.entries.forEach { Store.setPref("notified.${it.name}", throttle.lastNotified[it]?.epochSecond ?: 0) }
    }

    fun summaryReady(context: Context) =
        post(context, 200, "Your weekly glucose summary is ready", "Open GlucoseBar to read it.", snoozable = false, screen = "summary")

    fun sendTest(context: Context) = post(context, 201, "Test alert", "Notifications from GlucoseBar are working.", urgent = true)

    private fun post(
        context: Context, id: Int, title: String, body: String,
        urgent: Boolean = false, snoozable: Boolean = true, screen: String? = null,
    ) {
        val builder = Notification.Builder(context, if (urgent) urgentChannel(context) else ALERT_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(if (urgent) Notification.CATEGORY_ALARM else Notification.CATEGORY_STATUS)
            .setContentIntent(MainActivity.intent(context, screen))
            .setAutoCancel(true)
        if (snoozable) {
            builder.addAction(Notification.Action.Builder(null, "Stop alerting for 30 min", snoozeIntent(context)).build())
        }
        manager(context).notify(id, builder.build())
    }
}

class SnoozeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Store.init(context)
        Alerts.snooze(context)
    }
}
