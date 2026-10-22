package co.dnk.glucosebar

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(nav: Nav) {
    val s by Store.settings.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun set(change: (Settings) -> Settings) = Store.updateSettings(change)
    // System settings can change while the app is in the background, so re-read them when it comes back.
    var resumed by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { resumed++; onPauseOrDispose {} }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(nav.back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Section("Glucose")
            Segmented(listOf(false to "mg/dL", true to "mmol/L"), s.useMmol) { mmol -> set { it.copy(useMmol = mmol) } }
            GlucoseStepper("Target low", s.targetLow, 50..s.targetHigh - 10, s) { v -> set { it.copy(targetLow = v) } }
            GlucoseStepper("Target high", s.targetHigh, s.targetLow + 10..300, s) { v -> set { it.copy(targetHigh = v) } }
            Caption("Used for time in range, colours and meal scores.")
            Text("Sensor lifetime")
            Segmented(listOf(14 to "14 days", 15 to "15 days (Libre 3 Plus)"), s.sensorDays) { d -> set { it.copy(sensorDays = d) } }

            Section("Notification")
            Toggle("Show change since 5 min ago", s.showDelta) { v -> set { it.copy(showDelta = v) } }
            Toggle("Show trend line", s.showSparkline) { v -> set { it.copy(showSparkline = v) } }
            if (s.showSparkline) {
                Segmented((1..3).map { it to "$it hour${if (it == 1) "" else "s"}" }, s.sparklineHours) { h -> set { it.copy(sparklineHours = h) } }
            }

            Section("Alerts")
            Toggle("Enable alerts", s.alertsEnabled) { v -> set { it.copy(alertsEnabled = v) } }
            if (s.alertsEnabled) {
                GlucoseStepper("Low alert at or below", s.alertLow, 40..150, s) { v -> set { it.copy(alertLow = v) } }
                GlucoseStepper("High alert at or above", s.alertHigh, 150..400, s) { v -> set { it.copy(alertHigh = v) } }
                Toggle("Dropping fast below ${s.format(100)}", s.alertFastDrop) { v -> set { it.copy(alertFastDrop = v) } }
                Toggle("Heading low within 20 minutes", s.alertPredictedLow) { v -> set { it.copy(alertPredictedLow = v) } }
                Caption("For 4 to 6 hours after moderate or hard exercise (2 hours more after 90 minutes or longer), heading-low and dropping-fast alerts come earlier.")
                Stepper("No data for", "${s.staleMinutes} min",
                    { set { it.copy(staleMinutes = maxOf(10, it.staleMinutes - 5)) } },
                    { set { it.copy(staleMinutes = minOf(60, it.staleMinutes + 5)) } })
                Caption("Alerts repeat every 20 minutes while the condition lasts.")
            }
            key(resumed) {
                val dnd = Alerts.lowsBreakThroughDnd(context)
                Status(
                    "Lows sound in Do Not Disturb",
                    if (dnd) "On" else "Allow GlucoseBar to change Do Not Disturb, so low alerts can break through it.",
                    ok = dnd,
                ) { context.startActivity(Intent(AndroidSettings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
                val exempt = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
                Status(
                    "Checks glucose in battery saving",
                    if (exempt) "On" else "Allow GlucoseBar to run in the background, so alerts come with the screen off.",
                    ok = exempt,
                ) { requestBatteryExemption(context) }
            }
            OutlinedButton({ Alerts.sendTest(context) }) { Text("Send test alert") }

            Section("Dose suggestions")
            GlucoseStepper("Correct towards", s.doseTarget, 80..180, s) { v -> set { it.copy(doseTarget = v) } }
            Caption("Suggestions add or remove insulin to bring glucose to this level. They're estimates from your own logs, not medical advice.")
            Learned(s)

            Section("Server")
            ServerAddress(s.serverURL)
            val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri ->
                uri?.let { scope.launch { Store.exportCSV(it)?.let { msg -> android.widget.Toast.makeText(context, msg, android.widget.Toast.LENGTH_LONG).show() } } }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({ context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Store.url("/")))) }) { Text("Open web page") }
                OutlinedButton({ export.launch("glucose-${LocalDate.now()}.csv") }) { Text("Export CSV") }
            }

            Section("Version")
            Updates()
        }
    }
}

@Composable
private fun Section(title: String) {
    HorizontalDivider(Modifier.padding(top = 8.dp))
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Toggle(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!value) }, verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(value, onChange)
    }
}

/** Steps 5 mg/dL, or 9 mg/dL (about 0.5 mmol/L) in mmol mode. */
@Composable
private fun GlucoseStepper(label: String, value: Int, range: IntRange, s: Settings, onChange: (Int) -> Unit) {
    val step = if (s.useMmol) 9 else 5
    Stepper(label, "${s.format(value)} ${s.unit}",
        { onChange((value - step).coerceIn(range)) }, { onChange((value + step).coerceIn(range)) })
}

@Composable
private fun Status(title: String, detail: String, ok: Boolean, fix: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = if (ok) Palette.ok else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!ok) TextButton(fix) { Text("Allow") }
    }
}

@Composable
private fun ServerAddress(current: String) {
    val scope = rememberCoroutineScope()
    var text by remember(current) { mutableStateOf(current) }
    fun apply() {
        Store.updateSettings { it.copy(serverURL = text.trim().ifEmpty { Settings.DEFAULT_SERVER }) }
        scope.launch { Store.refresh(full = true) }
    }
    OutlinedTextField(
        text, { text = it }, Modifier.fillMaxWidth(), label = { Text("Server address") }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { apply() }),
        trailingIcon = { if (text != current) TextButton(::apply) { Text("Use") } },
    )
    Caption("The computer running the server, over Tailscale, such as ${Settings.DEFAULT_SERVER}")
}

/** The carb ratio and correction factor the server has learned. */
@Composable
private fun Learned(s: Settings) {
    var learned by remember { mutableStateOf<DoseSuggestion?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(s.doseTarget, s.serverURL) {
        try { learned = Store.doseSuggestion(0.0) } catch (e: IOException) { error = e.message }
    }
    Text("Learned from your history", style = MaterialTheme.typography.labelLarge)
    val l = learned
    when {
        l != null -> {
            Value("Carb ratio", "1 u per ${formatUnits(l.carbRatio)} g")
            listOf("morning", "midday", "evening").forEach { period ->
                l.byTime[period]?.let { p ->
                    Value("   ${period.capitalizedFirst()}", "1 u per ${formatUnits(p.carbRatio)} g · ${p.meals} meal${if (p.meals == 1) "" else "s"}")
                }
            }
            Value("Correction", "1 u lowers about ${s.format(l.sensitivity)} ${s.unit}")
            Value("Daily insulin", "${formatUnits(l.dailyDose)} u on average")
            Caption("From ${l.meals} meal${if (l.meals == 1) "" else "s"} and ${l.corrections} correction dose${if (l.corrections == 1) "" else "s"} " +
                "over the last ${Math.round(l.days)} days, blended with the usual rules for your daily dose " +
                "(1 u per ${formatUnits(l.rulesCarbRatio)} g, 1 u per ${s.format(l.rulesSensitivity)}). The more you log, the more it follows your own data.")
        }
        error != null -> Caption(error!!)
        else -> Caption("Loading…")
    }
}

@Composable
private fun Value(label: String, value: String) {
    Row {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Updates() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val status by Updater.status.collectAsState()
    var checking by remember { mutableStateOf(false) }
    var available by remember { mutableStateOf<Updater.Release?>(null) }
    var checkStatus by remember { mutableStateOf<String?>(null) }

    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(Updater.version, Modifier.weight(1f))
        Button({
            checking = true
            available = null
            checkStatus = "Checking…"
            scope.launch {
                val latest = Updater.latest()
                checkStatus = when {
                    latest == null -> "Couldn't reach GitHub. Try again later."
                    !latest.isNewer || latest.apk == null -> "Up to date."
                    else -> { available = latest; "${latest.tag} is available." }
                }
                checking = false
            }
        }, enabled = !Updater.isDev && !checking) { Text("Check for updates") }
    }
    available?.let { release ->
        Text("What's new in ${release.tag}", style = MaterialTheme.typography.titleSmall)
        Text(release.notes.ifEmpty { "No release notes." }.replace(Regex("(?m)^- "), "• "),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button({ scope.launch { Updater.install(context, release) } }) { Text("Install ${release.tag}") }
    }
    Caption(status ?: checkStatus ?: if (Updater.isDev) "Built from a checkout, so it doesn't update." else "New releases install every 6 hours.")
    if (!context.packageManager.canRequestPackageInstalls()) {
        TextButton({
            context.startActivity(Intent(AndroidSettings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
        }) { Text("Allow GlucoseBar to install its updates") }
    }
}
