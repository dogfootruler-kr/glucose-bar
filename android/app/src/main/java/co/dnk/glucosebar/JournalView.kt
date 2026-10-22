package co.dnk.glucosebar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

val GlucoseEvent.tint: Color
    get() = when {
        isMeal -> Palette.meal
        isExercise -> Palette.exercise
        isRapid -> Palette.insulin
        else -> Palette.longInsulin
    }

val GlucoseEvent.emoji: String get() = if (isMeal) "🍽" else if (isExercise) exerciseActivity.emoji else "💉"

private enum class Filter(val label: String) { All("All"), Meals("Meals"), Insulin("Insulin"), Exercise("Exercise") }
private enum class Order(val label: String) { Date("By date"), Best("Easiest on glucose first"), Worst("Hardest on glucose first") }

/** Every meal, insulin and exercise entry from the last 30 days, by day. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JournalView(nav: Nav) {
    val data by Store.data.collectAsState()
    val settings by Store.settings.collectAsState()
    var filter by rememberSaveable { mutableStateOf(Filter.All) }
    var order by rememberSaveable { mutableStateOf(Order.Date) }
    var sortMenu by remember { mutableStateOf(false) }

    val list = data.entries.filter {
        when (filter) {
            Filter.All -> true
            Filter.Meals -> it.isMeal
            Filter.Insulin -> it.isInsulin
            Filter.Exercise -> it.isExercise
        }
    }
    val visible = when (order) {
        Order.Date -> list.reversed()
        else -> list.mapNotNull { e -> data.meal(e.id)?.score?.let { e to it } }
            .let { scored -> if (order == Order.Best) scored.sortedByDescending { it.second } else scored.sortedBy { it.second } }
            .map { it.first }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Journal") },
                navigationIcon = { IconButton(nav.back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    Box {
                        IconButton({ sortMenu = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort meals by score") }
                        DropdownMenu(sortMenu, { sortMenu = false }) {
                            Order.entries.forEach { o ->
                                DropdownMenuItem(
                                    text = { Text(o.label, fontWeight = if (o == order) FontWeight.Bold else null) },
                                    onClick = {
                                        order = o
                                        if (o != Order.Date) filter = Filter.Meals
                                        sortMenu = false
                                    },
                                )
                            }
                        }
                    }
                    IconButton({ nav.open(Screen.Entry()) }) { Icon(Icons.Filled.Add, "New entry") }
                },
            )
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
            item {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Filter.entries.forEach { f ->
                        FilterChip(filter == f, { filter = f; if (f != Filter.Meals) order = Order.Date }, { Text(f.label) })
                    }
                }
            }
            if (data.entries.isEmpty()) {
                item {
                    Text(
                        "Meals, insulin and exercise you log appear here, with how your glucose responded.",
                        Modifier.padding(32.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (order == Order.Date) {
                val zone = ZoneId.systemDefault()
                visible.groupBy { it.timestamp.atZone(zone).toLocalDate() }.forEach { (day, entries) ->
                    item(key = day.toString()) { DayHeader(day, entries) }
                    items(entries, key = { it.id }) { entry ->
                        EntryRow(data, settings, entry, Modifier.clickable { nav.open(Screen.Detail(entry.id)) }.padding(horizontal = 16.dp, vertical = 6.dp))
                    }
                }
            } else {
                items(visible, key = { it.id }) { entry ->
                    EntryRow(data, settings, entry, Modifier.clickable { nav.open(Screen.Detail(entry.id)) }.padding(horizontal = 16.dp, vertical = 6.dp), showsDay = true)
                }
            }
        }
    }
}

@Composable
private fun DayHeader(day: LocalDate, entries: List<GlucoseEvent>) {
    val today = LocalDate.now()
    val title = when (day) {
        today -> "Today"
        today.plusDays(1) -> "Tomorrow"
        today.minusDays(1) -> "Yesterday"
        else -> DateTimeFormatter.ofPattern("EEEE d MMMM").format(day)
    }
    val carbs = entries.sumOf { it.carbs ?: 0.0 }
    val rapid = entries.filter { it.isRapid }.sumOf { it.units ?: 0.0 }
    val long = entries.filter { it.isLong }.sumOf { it.units ?: 0.0 }
    val exercise = entries.filter { it.isExercise && !it.isPlanned }.sumOf { it.minutes ?: 0.0 }
    val planned = entries.filter { it.isPlanned }.sumOf { it.minutes ?: 0.0 }
    val totals = listOfNotNull(
        if (carbs > 0) "${carbs.toInt()} g carbs" else null,
        if (rapid > 0) "${formatUnits(rapid)} u rapid" else null,
        if (long > 0) "${formatUnits(long)} u long" else null,
        if (exercise > 0) "${formatMinutes(exercise)} exercise" else null,
        if (planned > 0) "${formatMinutes(planned)} planned" else null,
    ).joinToString(" · ")
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 4.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        if (totals.isNotEmpty()) Text(totals, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** One entry, used in the journal and on the home screen. */
@Composable
fun EntryRow(data: Data, settings: Settings, entry: GlucoseEvent, modifier: Modifier = Modifier, compact: Boolean = false, showsDay: Boolean = false) {
    val meal = data.meal(entry.id)
    val time = DateTimeFormatter.ofPattern(if (showsDay) "EEE d MMM HH:mm" else "HH:mm").withZone(ZoneId.systemDefault()).format(entry.timestamp)
    val details = buildList {
        add(time)
        when (entry.kind) {
            "meal" -> {
                entry.carbs?.let { add("${it.toInt()} g carbs") }
                meal?.dose?.takeIf { it.units > 0 }?.let { add("${formatUnits(it.units)} u") }
                if (meal?.exercise != null) add("with exercise")
            }
            "exercise" -> {
                if (entry.isPlanned) add(0, "Planned")
                entry.intensity?.let { add(it.capitalizedFirst()) }
                entry.note?.let { add(it) }
            }
            else -> entry.note?.let { add(it) }
        }
    }.joinToString(" · ")
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        EntryIcon(entry, if (compact) 32.dp else 40.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.title, maxLines = 1, style = MaterialTheme.typography.bodyLarge)
            Text(details, maxLines = 1, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (entry.isExercise && data.exerciseImpact(entry.id)?.lowAfter != null) {
            Icon(Icons.Filled.Warning, "Went low after", Modifier.size(18.dp), tint = Palette.low)
        }
        meal?.score?.let { score ->
            Column(horizontalAlignment = Alignment.End) {
                ScoreBadge(score, meal.impact?.complete ?: true, if (compact) 28.dp else 34.dp)
                val dose = meal.dose
                if (!compact && dose?.verdictLabel != null && dose.verdict != "none") {
                    Text(dose.verdictLabel!!, style = MaterialTheme.typography.labelSmall, color = doseColor(dose.verdict))
                }
            }
        }
    }
}

@Composable
fun doseColor(verdict: String?): Color = when (verdict) {
    "ok" -> Palette.ok
    "tooLittle", "tooMuch" -> Palette.high
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
fun EntryIcon(entry: GlucoseEvent, size: Dp) {
    val shape = RoundedCornerShape(size * 0.22f)
    val photo = entry.photo?.takeIf { entry.isMeal }
    if (photo != null) {
        Photo(photo, Modifier.size(size).clip(shape))
    } else {
        Box(Modifier.size(size).background(entry.tint.copy(alpha = 0.15f), shape), contentAlignment = Alignment.Center) {
            Text(entry.emoji, fontSize = (size.value * 0.45f).sp)
        }
    }
}

/** A photo saved with an entry, loaded from the server. */
@Composable
fun Photo(path: String, modifier: Modifier) {
    val image by produceState(Store.cachedPhoto(path), path) { value = Store.photo(path) }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant)) {
        image?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
    }
}

/** A meal's food score as a ring. */
@Composable
fun ScoreBadge(score: Int, complete: Boolean = true, size: Dp = 32.dp) {
    val color = if (score >= 80) Palette.ok else if (score >= 50) Palette.high else Palette.low
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = size.toPx() * 0.11f
            val inset = stroke / 2
            val arcSize = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke)
            drawArc(color.copy(alpha = 0.2f), 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
            drawArc(color, -90f, 360f * score / 100, false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round,
                pathEffect = if (complete) null else PathEffect.dashPathEffect(floatArrayOf(4f, 4f))))
        }
        Text("$score", fontSize = (size.value * 0.36f).sp, fontWeight = FontWeight.SemiBold)
    }
}

/** A meal's glucose response and dose, an exercise session's, or an insulin entry, with Edit and Delete. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EntryDetailScreen(nav: Nav, id: Int) {
    val data by Store.data.collectAsState()
    val settings by Store.settings.collectAsState()
    val scope = rememberCoroutineScope()
    var deleting by remember { mutableStateOf(false) }
    val entry = data.entry(id)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(entry?.title ?: "Entry", maxLines = 1) },
                navigationIcon = { IconButton(nav.back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    if (entry != null) {
                        TextButton({ nav.open(Screen.Entry(id)) }) { Text("Edit") }
                        TextButton({ deleting = true }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                    }
                },
            )
        },
    ) { padding ->
        if (entry == null) {
            Text("It may have been deleted, or is older than 30 days.", Modifier.padding(padding).padding(24.dp))
            return@Scaffold
        }
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            EntryDetail(data, settings, entry)
        }
    }
    if (deleting && entry != null) {
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text("Delete this entry?") },
            text = { Text("“${entry.title}” will be removed. This can't be undone.") },
            confirmButton = {
                TextButton({
                    deleting = false
                    Store.deleteEvent(entry.id)
                    nav.back()
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton({ deleting = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun EntryDetail(data: Data, settings: Settings, entry: GlucoseEvent) {
    val meal = data.meal(entry.id)
    entry.photo?.takeIf { entry.isMeal }?.let { Photo(it, Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(12.dp))) }
    Text(
        DateTimeFormatter.ofPattern("EEEE d MMMM, HH:mm").withZone(ZoneId.systemDefault()).format(entry.timestamp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    if (entry.isMeal) {
        ResponseChart(data, settings, entry)
        meal?.let { MealFacts(it, settings) }
        entry.estimate?.let { estimate ->
            Facts("Claude's estimate") {
                estimate.items.forEach { Fact(it.name, "${it.carbs.toInt()} g") }
                estimate.note?.let { Caption(it) }
            }
        }
    } else if (entry.isExercise) {
        if (!entry.isPlanned) ResponseChart(data, settings, entry)
        ExerciseFacts(data, settings, entry)
        entry.note?.let { Text(it) }
    } else {
        ResponseChart(data, settings, entry)
        entry.note?.let { Text(it) }
    }
}

/** Glucose around the entry: 4 hours after a meal or dose; for exercise, up to 12 hours after it ends, when delayed lows show up. */
@Composable
private fun ResponseChart(data: Data, settings: Settings, entry: GlucoseEvent) {
    val start = entry.timestamp.minusSeconds(30 * 60)
    val end = if (!entry.isExercise) entry.timestamp.plusSeconds(4 * 3600)
    else minOf(entry.end.plusSeconds(12 * 3600), maxOf(Instant.now(), entry.end.plusSeconds(3600)))
    val readings by produceState(emptyList<Point>(), entry.id, entry.timestamp) { value = Store.readings(start, end) }
    val nearby = data.entries.filter { it.end >= start && it.timestamp <= end }
    GlucoseChart(readings, start, end, settings, events = nearby, highlight = entry.id,
        low = if (entry.isExercise) data.exerciseImpact(entry.id)?.lowAfter else null, height = 170.dp)
}

@Composable
private fun MealFacts(meal: Meal, settings: Settings) {
    meal.impact?.let { i ->
        Facts {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ScoreBadge(meal.score ?: i.score, i.complete, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(if (i.complete) "Food score" else "Food score so far", style = MaterialTheme.typography.titleSmall)
                    Text("Rose ${settings.format(i.earlyRise ?: i.rise)} in the first 90 minutes" +
                        if (i.exerciseEffect != null) ", allowing for exercise" else "",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            HorizontalDivider()
            Fact("Peak", "${settings.format(i.peak)}, ${i.minutesToPeak} min after eating")
            Fact("Above range", if (i.minutesAboveHigh > 0) "${i.minutesAboveHigh} min" else "None")
            i.minutesToBaseline?.let { Fact("Back to start", "after $it min") }
            Fact("Overall response", "${i.score} / 100")
        }
    }
    meal.dose?.let { d ->
        Facts {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(when (d.verdict) {
                    "ok" -> Icons.Filled.CheckCircle
                    "tooLittle" -> Icons.Filled.ArrowCircleUp
                    "tooMuch" -> Icons.Filled.ArrowCircleDown
                    else -> Icons.Filled.Schedule
                }, null, tint = doseColor(d.verdict))
                Spacer(Modifier.width(8.dp))
                Text(d.verdictLabel ?: "Dose: too early to tell", style = MaterialTheme.typography.titleSmall, color = doseColor(d.verdict))
            }
            d.reason?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            HorizontalDivider()
            if (d.units > 0) Fact("Rapid insulin", "${formatUnits(d.units)} u" + timing(d.minutesFromMeal))
            if (d.laterUnits > 0) Fact("Later doses", "${formatUnits(d.laterUnits)} u")
            if (d.sharedWith > 0) Fact("Carbs covered", "${d.carbs.toInt()} g, with ${d.sharedWith} other item${if (d.sharedWith == 1) "" else "s"}")
            d.suggested?.let { Fact("Your usual ratio", "${formatUnits(it)} u for ${d.carbs.toInt()} g") }
        }
        Caption("The food score looks at the first 90 minutes, so a dose that was off doesn't count against the food.")
    }
    meal.exercise?.let { ex ->
        Facts {
            Text(if (ex.items.size == 1) ex.items[0].capitalizedFirst() else "Exercise around this meal",
                style = MaterialTheme.typography.titleSmall, color = Palette.exercise)
            Fact(if (ex.effect >= 0) "Lowered glucose by" else "Raised glucose by", "about ${settings.format(kotlin.math.abs(ex.effect))}")
            Caption("The food score and the dose check allow for this.")
        }
    }
}

@Composable
private fun ExerciseFacts(data: Data, settings: Settings, entry: GlucoseEvent) {
    val impact = data.exerciseImpact(entry.id)
    impact?.lowAfter?.let { low ->
        Row {
            Icon(Icons.Filled.Warning, null, Modifier.size(18.dp), tint = Palette.low)
            Spacer(Modifier.width(8.dp))
            Text("Went down to ${settings.format(low.mgdl)} at ${formatTime(low.timestamp)}, " +
                "${formatMinutes((low.minutesAfter ?: 0).toDouble())} after you finished. Exercise can lower glucose for many hours.",
                color = Palette.low)
        }
    }
    Facts {
        Fact("Intensity", entry.intensity?.capitalizedFirst() ?: "–")
        if (entry.isPlanned) {
            Caption("Planned. Dose suggestions and low alerts allow for it, and how glucose responds shows here once it's done.")
        } else if (impact != null) {
            impact.startGlucose?.let { Fact("At the start", settings.format(it)) }
            impact.endGlucose?.let { Fact(if (impact.inProgress) "Now" else "At the end", settings.format(it)) }
            impact.change?.let { Fact("Change", formatDelta(it, settings.useMmol)) }
            Fact("Typical drop for this activity", settings.format(impact.expectedDrop))
            impact.exerciseDrop?.let { Fact("Drop from the exercise", settings.format(it)) }
            impact.lowest?.let {
                Fact(if (impact.complete) "Lowest in the 12 h after" else "Lowest since", "${settings.format(it.mgdl)} at ${formatTime(it.timestamp)}")
            }
            if (impact.lowDuring) Fact("During", "Went low")
        }
    }
}

@Composable
private fun Facts(title: String? = null, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            title?.let { Text(it, style = MaterialTheme.typography.titleSmall) }
            content()
        }
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Row {
        Text(label, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.width(12.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

private fun timing(minutes: Int?): String = when {
    minutes == null -> ""
    kotlin.math.abs(minutes) < 3 -> ", when eating"
    minutes < 0 -> ", ${-minutes} min before eating"
    else -> ", $minutes min after eating"
}
