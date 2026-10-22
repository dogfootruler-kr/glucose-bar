package co.dnk.glucosebar

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.util.Base64
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.abs
import kotlin.math.roundToInt

/** A photo ready to send: shown on screen, and as base64 JPEG for the server. */
private class MealPhoto(val image: ImageBitmap, val jpeg: String)

/** JPEG, longest side at most 1568 px (what the API uses anyway). */
private suspend fun mealPhoto(source: ImageDecoder.Source): MealPhoto? = withContext(Dispatchers.Default) {
    runCatching {
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val scale = minOf(1f, 1568f / maxOf(info.size.width, info.size.height))
            decoder.setTargetSize((info.size.width * scale).roundToInt(), (info.size.height * scale).roundToInt())
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        MealPhoto(bitmap.asImageBitmap(), Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP))
    }.getOrNull()
}

/** Adds a meal, insulin or exercise entry, or changes an existing one. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EntryEditor(nav: Nav, id: Int?) {
    val data by Store.data.collectAsState()
    val settings by Store.settings.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val existing = remember(id) { id?.let { data.entry(it) } }

    var kind by remember { mutableStateOf(existing?.kind ?: "meal") }
    var time by remember { mutableStateOf(existing?.timestamp ?: Instant.now()) }
    var note by remember { mutableStateOf(existing?.note.orEmpty()) }
    // meal
    var photo by remember { mutableStateOf<MealPhoto?>(null) }
    var keepsPhoto by remember { mutableStateOf(existing?.photo != null) }
    var carbs by remember { mutableStateOf(existing?.carbs?.let { formatUnits(it) }.orEmpty()) }
    var estimate by remember { mutableStateOf(existing?.estimate) }
    var estimating by remember { mutableStateOf(false) }
    // insulin
    var units by remember { mutableStateOf(existing?.units ?: 1.0) }
    var insulinType by remember { mutableStateOf(existing?.insulinType ?: "rapid") }
    // exercise
    var activity by remember { mutableStateOf(existing?.exerciseActivity ?: Activity.Walk) }
    var minutes by remember { mutableStateOf(existing?.minutes ?: 30.0) }
    var intensity by remember { mutableStateOf(existing?.intensity ?: "moderate") }
    // insulin logged together with a new meal
    var suggestion by remember { mutableStateOf<DoseSuggestion?>(null) }
    var suggestionError by remember { mutableStateOf<String?>(null) }
    var checkingHistory by remember { mutableStateOf(false) }
    var historyError by remember { mutableStateOf<String?>(null) }
    var logDose by remember { mutableStateOf(false) }
    var doseUnits by remember { mutableStateOf(0.0) }
    var doseEdited by remember { mutableStateOf(false) }

    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    val isMeal = kind == "meal"
    val isExercise = kind == "exercise"
    val carbsValue = carbs.replace(',', '.').toDoubleOrNull()
    // Exercise can be planned a few hours ahead; meals and insulin up to an hour.
    val latest = Instant.now().plusSeconds(if (isExercise) 6 * 3600L else 3600L)
    // Suggestions are for eating now, so they're hidden when logging something from earlier.
    val suggestsDose = existing == null && isMeal && abs(Duration.between(time, Instant.now()).toMinutes()) < 30
    val canSave = !saving && when (kind) {
        "meal" -> carbsValue != null || note.isNotBlank() || photo != null || keepsPhoto
        "exercise" -> minutes > 0
        else -> units > 0
    }

    LaunchedEffect(kind) { if (time > latest) time = Instant.now() }
    LaunchedEffect(suggestsDose, carbsValue, note, estimate?.description) {
        checkingHistory = false
        historyError = null
        if (!suggestsDose || carbsValue == null || carbsValue <= 0) return@LaunchedEffect
        delay(400) // typing
        try {
            val s = Store.doseSuggestion(carbsValue)
            suggestion = s
            suggestionError = null
            if (!doseEdited) doseUnits = s.units
        } catch (e: IOException) {
            suggestion = null
            suggestionError = e.message
            return@LaunchedEffect
        }
        // Then Claude's adjustment for how the same food went before, which needs something to match on.
        val text = note.trim()
        if (text.isEmpty() && estimate == null) return@LaunchedEffect
        checkingHistory = true
        delay(1000) // still typing the description
        try {
            val s = Store.doseFromHistory(carbsValue, text.ifEmpty { null }, estimate?.description)
            suggestion = s
            if (!doseEdited) doseUnits = s.units
        } catch (e: IOException) {
            historyError = "Couldn't compare with past meals: ${e.message}"
        }
        checkingHistory = false
    }

    fun save() {
        saving = true
        error = null
        scope.launch {
            try {
                val body = EventBody(
                    timestamp = time,
                    note = if (existing == null) note.trim().ifEmpty { null } else note.trim(),
                )
                if (existing != null) {
                    Store.updateEvent(existing.id, when (kind) {
                        "meal" -> body.copy(
                            carbs = carbsValue, clearCarbs = carbsValue == null,
                            estimate = estimate.takeIf { it != existing.estimate },
                            photo = photo?.jpeg, mediaType = photo?.let { "image/jpeg" },
                            removePhoto = if (photo == null && existing.photo != null && !keepsPhoto) true else null,
                        )
                        "exercise" -> body.copy(activity = activity.raw, minutes = minutes, intensity = intensity)
                        else -> body.copy(units = units, insulinType = insulinType)
                    })
                } else {
                    Store.addEvent(when (kind) {
                        "meal" -> body.copy(kind = kind, carbs = carbsValue, estimate = estimate,
                            photo = photo?.jpeg, mediaType = photo?.let { "image/jpeg" })
                        "exercise" -> body.copy(kind = kind, activity = activity.raw, minutes = minutes, intensity = intensity)
                        else -> body.copy(kind = kind, units = units, insulinType = insulinType)
                    })
                    if (isMeal && logDose && doseUnits > 0) {
                        // The meal is saved by now, so a failure here mustn't leave the screen open to add it again.
                        try {
                            Store.addEvent(EventBody(kind = "insulin", timestamp = time, units = doseUnits, insulinType = "rapid"))
                        } catch (e: IOException) {
                            Toast.makeText(context, "Meal saved, but the insulin wasn't: ${e.message}", Toast.LENGTH_LONG).show()
                        }
                    }
                }
                nav.back()
            } catch (e: IOException) {
                error = e.message
            } finally {
                saving = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (existing == null) "New entry" else "Edit ${kind}") },
                navigationIcon = { IconButton(nav.back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Cancel") } },
                actions = {
                    if (saving) CircularProgressIndicator(Modifier.size(20.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                    TextButton(::save, enabled = canSave) { Text(if (existing == null) "Add" else "Save") }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (existing == null) {
                Segmented(listOf("meal" to "Meal", "insulin" to "Insulin", "exercise" to "Exercise"), kind) { kind = it }
            }
            when (kind) {
                "meal" -> {
                    if (existing == null && data.previousMeals.isNotEmpty()) {
                        PreviousMeals(data.previousMeals) { meal ->
                            note = meal.note.orEmpty()
                            carbs = meal.carbs?.let { formatUnits(it) }.orEmpty()
                            estimate = meal.estimate
                            photo = null
                            error = null
                            meal.photo?.let { path ->
                                scope.launch {
                                    val bytes = Store.photoData(path) ?: return@launch
                                    val p = mealPhoto(ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes)))
                                    if (note == meal.note.orEmpty() && photo == null) photo = p
                                }
                            }
                        }
                    }
                    PhotoWell(photo?.image, if (keepsPhoto) existing?.photo else null, onPhoto = { photo = it }) {
                        photo = null
                        keepsPhoto = false
                    }
                    OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Description") },
                        placeholder = { Text("e.g. Kimchi jjigae with rice") })
                    OutlinedTextField(carbs, { carbs = it }, Modifier.fillMaxWidth(), label = { Text("Carbs") },
                        suffix = { Text("g") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                    EstimateSection(data.aiAvailable, estimating, estimate, enabled = photo != null || note.isNotBlank()) {
                        estimating = true
                        error = null
                        scope.launch {
                            try {
                                val result = Store.estimateMeal(photo?.jpeg, note.ifBlank { null })
                                estimate = result
                                carbs = "${result.carbs.roundToInt()}"
                                if (note.isBlank()) note = result.description
                            } catch (e: IOException) {
                                error = e.message
                            } finally {
                                estimating = false
                            }
                        }
                    }
                }
                "exercise" -> {
                    ActivityPicker(activity) { activity = it }
                    Stepper("Duration", "${formatUnits(minutes)} min", { minutes = maxOf(0.0, minutes - 5) }, { minutes = minOf(600.0, minutes + 5) })
                    Segmented(intensities.map { it to it.capitalizedFirst() }, intensity) { intensity = it }
                    Caption(listOfNotNull(activity.example(intensity)?.let { "${it.capitalizedFirst()}." }, intensityInfo(intensity)).joinToString(" "))
                    OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Note") }, placeholder = { Text("Optional") })
                }
                else -> {
                    Segmented(listOf("rapid" to "Rapid-acting", "long" to "Long-acting"), insulinType) { insulinType = it }
                    Stepper("Units", "${formatUnits(units)} u", { units = maxOf(0.0, units - 0.5) }, { units = minOf(100.0, units + 0.5) })
                    OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Note") }, placeholder = { Text("Optional") })
                }
            }
            TimeRow(if (isExercise) "Starts" else "Time", time, latest) { time = it }
            if (isExercise && time > Instant.now()) Caption("Planned: dose suggestions and low alerts will allow for it.")

            if (isMeal && existing == null) {
                HorizontalDivider()
                Text("Rapid insulin", style = MaterialTheme.typography.titleSmall)
                data.exerciseNear(time)?.let { ex ->
                    Text(
                        if (ex.isPlanned) "${ex.title}, planned for ${formatTime(ex.timestamp)}"
                        else "${ex.title}, " + if (ex.end > Instant.now()) "in progress"
                        else "ended ${DateUtils.getRelativeTimeSpanString(ex.end.toEpochMilli())}",
                        color = Palette.exercise,
                    )
                }
                if (suggestsDose && (carbsValue ?: 0.0) > 0) {
                    val s = suggestion
                    when {
                        s != null -> DoseSuggestionView(s, carbsValue ?: 0.0, settings, checkingHistory, historyError)
                        suggestionError != null -> Caption(suggestionError!!)
                        else -> Row(verticalAlignment = Alignment.CenterVertically) {
                            Caption("Working out a dose…")
                            Spacer(Modifier.width(8.dp))
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Also log rapid insulin", Modifier.weight(1f))
                    Switch(logDose, { logDose = it })
                }
                if (logDose) {
                    Stepper("Units", "${formatUnits(doseUnits)} u",
                        { doseUnits = maxOf(0.0, doseUnits - 0.5); doseEdited = true },
                        { doseUnits = minOf(50.0, doseUnits + 0.5); doseEdited = true })
                }
                if (suggestsDose && (carbsValue ?: 0.0) > 0 && suggestion != null) {
                    Caption("An estimate from your own logs, not medical advice. Check it against what your diabetes team has told you.")
                }
            }
            error?.let {
                Row {
                    Icon(Icons.Filled.Warning, null, Modifier.size(18.dp), tint = Palette.low)
                    Spacer(Modifier.width(6.dp))
                    Text(it, color = Palette.low)
                }
            }
            if (existing != null) {
                OutlinedButton({ confirmDelete = true }) { Text("Delete…", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    if (confirmDelete && existing != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this entry?") },
            text = { Text("This can't be undone.") },
            confirmButton = {
                TextButton({
                    confirmDelete = false
                    Store.deleteEvent(existing.id)
                    nav.back()
                    nav.back()
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> Segmented(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { i, (value, label) ->
            SegmentedButton(selected == value, { onSelect(value) }, SegmentedButtonDefaults.itemShape(i, options.size), icon = {}) {
                Text(label, maxLines = 1)
            }
        }
    }
}

@Composable
fun Stepper(label: String, value: String, minus: () -> Unit, plus: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        OutlinedButton(minus, Modifier.size(44.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) { Text("−") }
        Text(value, Modifier.width(88.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center, fontWeight = FontWeight.SemiBold)
        OutlinedButton(plus, Modifier.size(44.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) { Text("+") }
    }
}

@Composable
private fun TimeRow(label: String, time: Instant, latest: Instant, onChange: (Instant) -> Unit) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    val local = LocalDateTime.ofInstant(time, zone)
    fun set(t: LocalDateTime) = onChange(minOf(t.atZone(zone).toInstant(), latest))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        TextButton({
            DatePickerDialog(context, { _, y, m, d -> set(local.withYear(y).withMonth(m + 1).withDayOfMonth(d)) },
                local.year, local.monthValue - 1, local.dayOfMonth).apply { datePicker.maxDate = latest.toEpochMilli() }.show()
        }) { Text(DateTimeFormatter.ofPattern("EEE d MMM").format(local)) }
        TextButton({
            TimePickerDialog(context, { _, h, m -> set(local.withHour(h).withMinute(m)) },
                local.hour, local.minute, DateFormat.is24HourFormat(context)).show()
        }) { Text(formatTime(time)) }
    }
}

@Composable
private fun PreviousMeals(meals: List<GlucoseEvent>, onPick: (GlucoseEvent) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        FilledTonalButton({ open = true }) {
            Icon(Icons.Filled.History, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Same as a previous meal")
        }
        DropdownMenu(open, { open = false }) {
            meals.take(25).forEach { meal ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(meal.note ?: "Meal")
                            Caption(listOfNotNull(meal.carbs?.let { "${it.toInt()} g carbs" },
                                DateUtils.getRelativeTimeSpanString(meal.timestamp.toEpochMilli()).toString()).joinToString(" · "))
                        }
                    },
                    onClick = { open = false; onPick(meal) },
                )
            }
        }
    }
}

/** The meal photo: take one, pick one, or remove it. */
@Composable
private fun PhotoWell(image: ImageBitmap?, existing: String?, onPhoto: (MealPhoto?) -> Unit, onRemove: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cameraFile = remember { File(context.cacheDir, "photos/meal.jpg").apply { parentFile?.mkdirs() } }
    val cameraUri = remember { FileProvider.getUriForFile(context, "${context.packageName}.files", cameraFile) }
    fun load(uri: Uri) = scope.launch { onPhoto(mealPhoto(ImageDecoder.createSource(context.contentResolver, uri))) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) load(cameraUri) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let { load(it) } }
    val hasPhoto = image != null || existing != null

    Row(verticalAlignment = Alignment.CenterVertically) {
        val shape = RoundedCornerShape(12.dp)
        Box(
            Modifier.size(88.dp).clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape).clickable { camera.launch(cameraUri) },
            contentAlignment = Alignment.Center,
        ) {
            when {
                image != null -> Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                existing != null -> Photo(existing, Modifier.fillMaxSize())
                else -> Icon(Icons.Filled.PhotoCamera, "Take a photo", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconButton({ camera.launch(cameraUri) }) { Icon(Icons.Filled.PhotoCamera, "Take a photo") }
                IconButton({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Icon(Icons.Filled.PhotoLibrary, "Choose a photo")
                }
                if (hasPhoto) TextButton(onRemove) { Text("Remove") }
            }
            if (!hasPhoto) Caption("Photo of the meal (optional)")
        }
    }
}

@Composable
private fun EstimateSection(aiAvailable: Boolean, estimating: Boolean, estimate: MealEstimate?, enabled: Boolean, onEstimate: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FilledTonalButton(onEstimate, enabled = aiAvailable && enabled && !estimating) {
            if (estimating) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            else Icon(Icons.Filled.AutoAwesome, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Estimate carbs with Claude")
        }
        estimate?.let { e ->
            e.items.forEach { item ->
                Row { Text(item.name, Modifier.weight(1f)); Text("${item.carbs.toInt()} g") }
            }
            Row { Text("Confidence", Modifier.weight(1f)); Text(e.confidence.capitalizedFirst()) }
        }
        Caption(when {
            !aiAvailable -> "Claude is unavailable. Run `claude` once on the server Mac to log in."
            estimate?.note != null -> estimate.note
            else -> "Uses the photo and description."
        })
    }
}

@Composable
private fun ActivityPicker(selected: Activity, onSelect: (Activity) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Activity.entries.forEach { a ->
            FilterChip(a == selected, { onSelect(a) }, { Text("${a.emoji} ${a.label}") })
        }
    }
}

/** The suggested dose with how it was worked out. */
@Composable
private fun DoseSuggestionView(s: DoseSuggestion, carbs: Double, settings: Settings, checkingHistory: Boolean, historyError: String?) {
    var expanded by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Suggested dose")
                    Caption(if (s.meals < 3) "Mostly the usual rules for your ${formatUnits(s.dailyDose)} u a day, until more meals are logged"
                    else "Learned from ${s.meals} meals over ${s.days.roundToInt()} days")
                }
                Text("${formatUnits(s.units)} u", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            }
            listOfNotNull(s.warning, s.exercise?.warning).forEach { warning ->
                Row {
                    Icon(Icons.Filled.Warning, null, Modifier.size(18.dp), tint = Palette.high)
                    Spacer(Modifier.width(6.dp))
                    Text(warning, color = Palette.high, style = MaterialTheme.typography.bodySmall)
                }
            }
            when {
                s.history != null -> Caption(s.history.reason)
                checkingHistory -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Caption("Checking how similar meals went…")
                    Spacer(Modifier.width(8.dp))
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                }
                historyError != null -> Caption(historyError)
            }
            Text(if (expanded) "Hide how it's worked out" else "How it's worked out",
                color = MaterialTheme.colorScheme.primary, modifier = Modifier.clickable { expanded = !expanded })
            if (expanded) {
                Step("${carbs.toInt()} g at 1 u per ${formatUnits(s.periodCarbRatio)} g (${s.period})", s.carbUnits)
                s.glucose?.let {
                    Step("Now ${settings.format(it)}, target ${settings.format(s.target)}, 1 u per ${settings.format(s.sensitivity)}", s.correctionUnits)
                }
                if (s.trendUnits != 0.0) Step("Where the trend is heading in 30 min", s.trendUnits)
                if (s.activeDeducted > 0) {
                    Step("Insulin still active: ${formatUnits(s.activeInsulin)} u, less what ${s.carbsOnBoard} g still digesting needs", -s.activeDeducted)
                }
                s.exercise?.let { Step(it.label, -it.units) }
                s.history?.takeIf { it.units != 0.0 }?.let {
                    Step("How ${it.meals} similar ${if (it.meals == 1) "meal" else "meals"} went, according to Claude", it.units)
                }
                HorizontalDivider()
                Row {
                    Caption("Rounded down to the nearest half unit")
                    Spacer(Modifier.weight(1f))
                    Text("${formatUnits(s.units)} u", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun Step(label: String, units: Double) {
    Row {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(12.dp))
        Text((if (units >= 0) "+" else "−") + formatUnits(abs(units)) + " u", style = MaterialTheme.typography.bodySmall)
    }
}
