package co.dnk.glucosebar

import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Vaccines
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The main screen, laid out like the Mac menu bar popup: reading, chart, stats, recent entries, then menu rows. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(nav: Nav) {
    val data by Store.data.collectAsState()
    val settings by Store.settings.collectAsState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("GlucoseBar") },
                actions = {
                    IconButton({ nav.open(Screen.Journal) }) { Icon(Icons.AutoMirrored.Filled.List, "Journal") }
                    IconButton({ nav.open(Screen.Settings) }) { Icon(Icons.Filled.Settings, "Settings") }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton({ nav.open(Screen.Entry()) }) { Icon(Icons.Filled.Add, "Log a meal, insulin or exercise") }
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Current(data, settings)
            Chart(data, settings)
            StatTiles(data, settings)
            InfoRows(data, settings)
            Recent(data, settings, nav)
            (data.fetchError ?: data.state?.error)?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Warning, null, Modifier.size(16.dp), tint = Palette.low)
                    Spacer(Modifier.width(6.dp))
                    Text(it, color = Palette.low, style = MaterialTheme.typography.bodySmall)
                }
            }
            HorizontalDivider()
            Menu(data, nav)
            Spacer(Modifier.height(72.dp))
        }
    }
}

@Composable
private fun Current(data: Data, settings: Settings) {
    val r = data.reading
    if (r == null) {
        Text("No reading yet", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 8.dp))
        return
    }
    val color = Palette.of(data.range(settings))
    Column {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(settings.format(r.mgdl), color = color, fontSize = 64.sp, fontWeight = FontWeight.SemiBold, lineHeight = 64.sp)
            Spacer(Modifier.width(8.dp))
            Text(r.arrow, color = color, fontSize = 40.sp, modifier = Modifier.padding(bottom = 6.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.padding(bottom = 10.dp)) {
                r.delta?.let { Text(formatDelta(it, settings.useMmol), color = color, style = MaterialTheme.typography.bodyMedium) }
                Text(settings.unit, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
        Text(
            "Measured ${DateUtils.getRelativeTimeSpanString(r.timestamp.toEpochMilli(), System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)}" +
                if (data.isStale(settings)) " ⚠︎" else "",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val hit = data.headingLow(settings)
        val in30 = data.in30
        if (hit != null) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
                    Icon(Icons.Filled.Warning, null, Modifier.size(16.dp), tint = Palette.low)
                    Spacer(Modifier.width(4.dp))
                    Text("Heading low: ${settings.format(hit.second)} around ${formatTime(hit.first)}",
                        color = Palette.low, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.bodySmall)
                }
        } else if (in30 != null) {
            Text("About ${settings.format(in30)} in 30 min if the trend continues",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp))
        }
    }
}

/** History, 30-minute forecast, meal/insulin/exercise markers (and exercise planned soon). */
@Composable
private fun Chart(data: Data, settings: Settings) {
    val scope = rememberCoroutineScope()
    val hours = settings.chartHours
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val options = listOf(3, 6, 12, 24)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { i, h ->
                SegmentedButton(
                    selected = hours == h,
                    onClick = {
                        Store.updateSettings { it.copy(chartHours = h) }
                        scope.launch { Store.refresh(full = true) }
                    },
                    shape = SegmentedButtonDefaults.itemShape(i, options.size),
                    icon = {},
                ) { Text("${h}h") }
            }
        }
        val now = Instant.now()
        val start = now.minusSeconds(hours * 3600L)
        val points = data.history(hours.toDouble())
        val forecast = data.state?.forecast?.points.orEmpty()
        val events = data.events.filter { it.end >= start }
        val planned = events.filter { it.isPlanned && it.timestamp <= now.plusSeconds(minOf(hours * 900L, 3 * 3600L)) }
        val end = maxOf(forecast.lastOrNull()?.timestamp ?: now, (planned.maxOfOrNull { it.timestamp } ?: Instant.EPOCH).plusSeconds(600))
        GlucoseChart(points, start, end, settings, forecast = forecast, events = events.filter { it.timestamp <= end })
        val first = points.firstOrNull()
        if (hours > 12 && first != null && first.timestamp > start.plusSeconds(1800)) {
            Text("History builds up from the first time the server ran.",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun StatTiles(data: Data, settings: Settings) {
    val today = data.stats?.today
    val week = data.stats?.week
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StatTile("In range", today?.let { "${it.inRange}%" }, week?.let { "${it.inRange}%" }, Modifier.weight(1f))
        StatTile("Average", today?.let { settings.format(it.average) }, week?.let { settings.format(it.average) }, Modifier.weight(1f))
        StatTile("A1c est.", today?.let { "%.1f%%".format(it.gmi) }, week?.let { "%.1f%%".format(it.gmi) }, Modifier.weight(1f))
    }
}

@Composable
private fun StatTile(title: String, today: String?, week: String?, modifier: Modifier) {
    Column(
        modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(12.dp)).padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Text(title, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(today ?: "–", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text("7 days ${week ?: "–"}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun InfoRows(data: Data, settings: Settings) {
    val (rapid, long) = data.insulinToday()
    val (exercised, next) = data.exerciseToday()
    val post = data.postExercise
    val sensorEnds = data.sensorEnds(settings)
    val dayTime = DateTimeFormatter.ofPattern("EEE HH:mm").withZone(ZoneId.systemDefault())
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (rapid + long > 0) InfoRow(Icons.Filled.Vaccines, "Insulin today", "${formatUnits(rapid)} u rapid · ${formatUnits(long)} u long")
        if (exercised > 0) InfoRow(Icons.AutoMirrored.Filled.DirectionsRun, "Exercise today", formatMinutes(exercised))
        next?.let {
            InfoRow(Icons.Filled.CalendarMonth, "Planned ${it.exerciseActivity.label.lowercase()}",
                "${formatTime(it.timestamp)} · ${formatMinutes(it.minutes ?: 0.0)}")
        }
        post?.let { InfoRow(Icons.Filled.NotificationsActive, "Low alerts come earlier", "until ${formatTime(it.until)}") }
        sensorEnds?.let { ends ->
            val left = Duration.between(Instant.now(), ends)
            val text = if (left.isNegative) "Sensor expired" else "Sensor ends in " +
                (if (left.toDays() > 0) "${left.toDays()}d " else "") + "${left.toHoursPart()}h"
            InfoRow(Icons.Filled.Sensors, text, dayTime.format(ends),
                color = if (left < Duration.ofDays(1)) Palette.high else MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun InfoRow(icon: ImageVector, text: String, value: String, color: Color = MaterialTheme.colorScheme.onSurface) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(10.dp))
        Text(text, color = color, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun Recent(data: Data, settings: Settings, nav: Nav) {
    val recent = data.entries.filter { (it.isMeal || it.isExercise) && !it.isPlanned }.takeLast(3).reversed()
    if (recent.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Recent", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        recent.forEach { entry ->
            EntryRow(data, settings, entry, compact = true, modifier = Modifier.clickable { nav.open(Screen.Detail(entry.id)) })
        }
    }
}

@Composable
private fun Menu(data: Data, nav: Nav) {
    val context = LocalContext.current
    Alerts.snoozeChanges.collectAsState().value
    val snoozedUntil = Alerts.snoozedUntil
    Column {
        MenuRow(Icons.AutoMirrored.Filled.List, "Journal") { nav.open(Screen.Journal) }
        if (data.summary != null || data.aiAvailable) {
            MenuRow(Icons.Filled.AutoAwesome, "Weekly summary",
                data.summary?.let { DateTimeFormatter.ofPattern("EEEE").withZone(ZoneId.systemDefault()).format(it.created) }) {
                nav.open(Screen.Summary)
            }
        }
        if (snoozedUntil != null) {
            MenuRow(Icons.Filled.Notifications, "Resume alerts", "Off until ${formatTime(snoozedUntil)}") { Alerts.cancelSnooze(context) }
        } else {
            MenuRow(Icons.Filled.NotificationsOff, "Snooze alerts for 30 minutes") { Alerts.snooze(context) }
        }
        MenuRow(Icons.Filled.Language, "Open web page") {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Store.url("/"))))
        }
    }
}

@Composable
private fun MenuRow(icon: ImageVector, title: String, detail: String? = null, action: () -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        leadingContent = { Icon(icon, null) },
        trailingContent = detail?.let { { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) } },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clickable(onClick = action),
    )
}
