package co.dnk.glucosebar

import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

/** Everything fetched from the server, and what's worked out from it. */
data class Data(
    val state: ServerState? = null,
    val stats: StatsResponse? = null,
    val meals: List<Meal> = emptyList(),
    /** Meals, insulin and exercise from the last 30 days (and exercise planned ahead), oldest first. */
    val entries: List<GlucoseEvent> = emptyList(),
    val sessions: List<Exercise> = emptyList(),
    val summary: Summary? = null,
    val aiAvailable: Boolean = false,
    val fetchError: String? = null,
    val lastSuccess: Instant = Instant.now(),
    val launched: Instant = Instant.now(),
) {
    val reading get() = state?.reading
    val events get() = state?.events ?: emptyList()

    /** When data stopped arriving: the last reading, or the last successful server contact if earlier. */
    val staleSince: Instant
        get() {
            val last = reading?.timestamp ?: launched
            return if (fetchError == null) last else minOf(last, lastSuccess)
        }

    fun isStale(settings: Settings, now: Instant = Instant.now()) =
        Duration.between(staleSince, now) > Duration.ofMinutes(settings.staleMinutes.toLong())

    fun range(settings: Settings): Range {
        val r = reading ?: return Range.None
        if (isStale(settings)) return Range.None
        return Range.of(r.mgdl, settings)
    }

    fun title(settings: Settings): String {
        val r = reading ?: return "– –"
        var t = "${settings.format(r.mgdl)} ${r.arrow}"
        if (settings.showDelta && r.delta != null) t += " ${formatDelta(r.delta, settings.useMmol)}"
        return t + if (isStale(settings)) " ⚠︎" else ""
    }

    /** Set while low alerts come earlier after exercise. */
    val postExercise get() = state?.postExercise?.takeIf { it.until > Instant.now() }

    /** When and where the forecast crosses the low alert (raised after exercise), within 30 minutes. */
    fun headingLow(settings: Settings) = state?.forecast?.crossingBelow(settings.alertLow + (postExercise?.raise ?: 0))

    /** Where glucose is heading in 30 minutes, when it's clearly moving. */
    val in30: Int? get() = state?.forecast?.takeIf { abs(it.slope) >= 1 }?.in30

    fun sensorEnds(settings: Settings): Instant? = state?.sensor?.activated?.plus(Duration.ofDays(settings.sensorDays.toLong()))

    fun history(lastHours: Double): List<Point> {
        val since = Instant.now().minusSeconds((lastHours * 3600).toLong())
        return state?.history.orEmpty().filter { it.timestamp >= since }
    }

    private fun startOfToday() = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant()

    fun insulinToday(): Pair<Double, Double> {
        val start = startOfToday()
        val today = entries.filter { it.isInsulin && it.timestamp >= start }
        return today.filter { it.isRapid }.sumOf { it.units ?: 0.0 } to today.filter { it.isLong }.sumOf { it.units ?: 0.0 }
    }

    /** Minutes of exercise done today, and the next planned session. */
    fun exerciseToday(): Pair<Double, GlucoseEvent?> {
        val start = startOfToday()
        val done = entries.filter { it.isExercise && !it.isPlanned && it.timestamp >= start }.sumOf { it.minutes ?: 0.0 }
        return done to entries.firstOrNull { it.isPlanned }
    }

    /** The exercise closest to `time` that ended up to 3 hours before it or starts up to 2 hours after it. */
    fun exerciseNear(time: Instant): GlucoseEvent? {
        fun gap(e: GlucoseEvent) = maxOf(0L, Duration.between(time, e.timestamp).seconds, Duration.between(e.end, time).seconds)
        return entries.filter { it.isExercise && gap(it) <= (if (it.end < time) 3 else 2) * 3600 }.minByOrNull { gap(it) }
    }

    /** Meals from the last 30 days to log again, newest first, one per description. */
    val previousMeals: List<GlucoseEvent>
        get() {
            val seen = mutableSetOf<String>()
            return entries.reversed().filter { e ->
                val note = e.note?.trim().orEmpty()
                e.isMeal && note.isNotEmpty() && seen.add(note.lowercase())
            }
        }

    fun entry(id: Int) = entries.firstOrNull { it.id == id }
    fun meal(id: Int) = meals.firstOrNull { it.id == id }
    fun exerciseImpact(id: Int) = sessions.firstOrNull { it.id == id }?.impact
}

enum class Range {
    None, Low, InRange, High;

    companion object {
        fun of(mgdl: Int, settings: Settings) = when {
            mgdl < settings.targetLow -> Low
            mgdl > settings.targetHigh -> High
            else -> InRange
        }
    }
}

class ServerError(message: String) : IOException(message)

/** The app's one copy of the server data and settings, shared by the screens, the service, the widget and alerts. */
object Store {
    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences

    private val _data = MutableStateFlow(Data())
    val data: StateFlow<Data> = _data
    private val _settings = MutableStateFlow(Settings())
    val settings: StateFlow<Settings> = _settings
    private val _generatingSummary = MutableStateFlow(false)
    val generatingSummary: StateFlow<Boolean> = _generatingSummary

    /** True while a screen is showing, so refreshes also fetch what the screens need. */
    @Volatile var uiVisible = false
    private var lastSummaryFetch = Instant.EPOCH
    private val refreshing = Mutex()
    private val photos = LruCache<String, ImageBitmap>(40)

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** For work that should finish even if the screen that started it closes. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)
        _settings.value = loadSettings()
    }

    // MARK: settings

    private fun loadSettings(): Settings {
        val d = Settings()
        fun int(key: String, default: Int) = prefs.getInt(key, default)
        fun bool(key: String, default: Boolean) = prefs.getBoolean(key, default)
        return Settings(
            serverURL = prefs.getString("serverURL", null)?.trim()?.takeIf { it.isNotEmpty() } ?: d.serverURL,
            useMmol = bool("useMmol", d.useMmol),
            targetLow = int("targetLow", d.targetLow),
            targetHigh = int("targetHigh", d.targetHigh),
            showDelta = bool("showDelta", d.showDelta),
            showSparkline = bool("showSparkline", d.showSparkline),
            sparklineHours = int("sparklineHours", d.sparklineHours),
            chartHours = int("chartHours", d.chartHours),
            alertsEnabled = bool("alertsEnabled", d.alertsEnabled),
            alertLow = int("alertLow", d.alertLow),
            alertHigh = int("alertHigh", d.alertHigh),
            alertFastDrop = bool("alertFastDrop", d.alertFastDrop),
            alertPredictedLow = bool("alertPredictedLow", d.alertPredictedLow),
            staleMinutes = int("staleMinutes", d.staleMinutes),
            sensorDays = int("sensorDays", d.sensorDays),
            doseTarget = int("doseTarget", d.doseTarget),
        )
    }

    fun updateSettings(change: (Settings) -> Settings) {
        val s = change(_settings.value)
        _settings.value = s
        prefs.edit()
            .putString("serverURL", s.serverURL)
            .putBoolean("useMmol", s.useMmol)
            .putInt("targetLow", s.targetLow)
            .putInt("targetHigh", s.targetHigh)
            .putBoolean("showDelta", s.showDelta)
            .putBoolean("showSparkline", s.showSparkline)
            .putInt("sparklineHours", s.sparklineHours)
            .putInt("chartHours", s.chartHours)
            .putBoolean("alertsEnabled", s.alertsEnabled)
            .putInt("alertLow", s.alertLow)
            .putInt("alertHigh", s.alertHigh)
            .putBoolean("alertFastDrop", s.alertFastDrop)
            .putBoolean("alertPredictedLow", s.alertPredictedLow)
            .putInt("staleMinutes", s.staleMinutes)
            .putInt("sensorDays", s.sensorDays)
            .putInt("doseTarget", s.doseTarget)
            .apply()
        GlucoseService.update(app)
    }

    fun pref(key: String): Long = prefs.getLong(key, 0)
    fun setPref(key: String, value: Long) = prefs.edit().putLong(key, value).apply()

    // MARK: refresh

    /**
     * Fetches the latest reading, and with `full` (a screen is showing) the stats, meals, journal and exercise too.
     * Then posts any alerts and updates the notification and widget.
     */
    suspend fun refresh(full: Boolean = uiVisible) {
        refreshing.withLock {
            val s = settings.value
            try {
                val hours = if (full) maxOf(s.chartHours, 3) else maxOf(s.sparklineHours, 3)
                val state: ServerState = get("/glucose?hours=$hours")
                _data.update { it.copy(state = state, aiAvailable = state.aiAvailable) }
                if (full) {
                    val stats: StatsResponse = get("/stats?low=${s.targetLow}&high=${s.targetHigh}")
                    val meals: List<Meal> = get("/meals?days=30&low=${s.targetLow}&high=${s.targetHigh}")
                    val entries: List<GlucoseEvent> = get("/events?hours=720")
                    val sessions: List<Exercise> = runCatching { get<List<Exercise>>("/exercise?days=30&low=${s.targetLow}") }
                        .getOrDefault(emptyList())
                    _data.update { it.copy(stats = stats, meals = meals, entries = entries, sessions = sessions) }
                }
                if (Duration.between(lastSummaryFetch, Instant.now()) > Duration.ofMinutes(10)) refreshSummary()
                _data.update { it.copy(fetchError = null, lastSuccess = Instant.now()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _data.update { it.copy(fetchError = "Server unreachable") }
            }
        }
        Alerts.evaluate(app, data.value, settings.value)
        GlucoseService.update(app)
        Widget.update(app)
    }

    suspend fun refreshSummary() {
        val r = runCatching { get<SummaryResponse>("/summary") }.getOrNull() ?: return
        lastSummaryFetch = Instant.now()
        val seen = pref("lastSummarySeen")
        val s = r.summary
        if (s != null && s.id.toLong() != seen) {
            if (seen != 0L) Alerts.summaryReady(app)
            setPref("lastSummarySeen", s.id.toLong())
        }
        _data.update { it.copy(summary = s, aiAvailable = r.aiAvailable) }
    }

    suspend fun generateSummary(): String? {
        _generatingSummary.value = true
        try {
            val s = settings.value
            val summary: Summary = send("POST", "/summary/generate?low=${s.targetLow}&high=${s.targetHigh}", "{}")
            setPref("lastSummarySeen", summary.id.toLong())
            _data.update { it.copy(summary = summary) }
            return null
        } catch (e: IOException) {
            return e.message
        } finally {
            _generatingSummary.value = false
        }
    }

    // MARK: entries

    suspend fun addEvent(event: EventBody) {
        send<GlucoseEvent>("POST", "/events", json.encodeToString(EventBody.serializer(), event))
        refresh(full = true)
    }

    suspend fun updateEvent(id: Int, change: EventBody) {
        var body = json.encodeToJsonElement(change).jsonObject
        if (change.clearCarbs) body = JsonObject(body + ("carbs" to JsonNull))
        send<GlucoseEvent>("PATCH", "/events/$id", body.toString())
        refresh(full = true)
    }

    /** Deletes in the background, so it finishes after the screen closes; a failure shows as the error on the home screen. */
    fun deleteEvent(id: Int) = scope.launch {
        try {
            request("DELETE", "/events/$id")
            refresh(full = true)
        } catch (e: IOException) {
            _data.update { it.copy(fetchError = "Couldn't delete the entry: ${e.message}") }
        }
    }

    suspend fun doseSuggestion(carbs: Double): DoseSuggestion {
        val s = settings.value
        return get("/dose?carbs=$carbs&target=${s.doseTarget}&low=${s.targetLow}")
    }

    /** The dose suggestion adjusted by Claude for how the same food went before; slow, so asked after doseSuggestion. */
    suspend fun doseFromHistory(carbs: Double, note: String?, description: String?): DoseSuggestion {
        val s = settings.value
        val body = DoseHistoryRequest(carbs, note, description, s.doseTarget, s.targetLow, s.targetHigh)
        return send("POST", "/dose/history", json.encodeToString(DoseHistoryRequest.serializer(), body))
    }

    suspend fun readings(start: Instant, end: Instant): List<Point> =
        runCatching { get<List<Point>>("/readings?start=${start.epochSecond}&end=${end.epochSecond}") }.getOrDefault(emptyList())

    suspend fun estimateMeal(photoJPEG: String?, text: String?): MealEstimate =
        send("POST", "/meals/estimate", json.encodeToString(EstimateRequest.serializer(), EstimateRequest(photoJPEG, "image/jpeg", text)))

    /** A photo saved with an entry (its server path), cached. */
    suspend fun photo(path: String): ImageBitmap? {
        photos.get(path)?.let { return it }
        val bytes = photoData(path) ?: return null
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()?.also { photos.put(path, it) }
    }

    fun cachedPhoto(path: String): ImageBitmap? = photos.get(path)

    suspend fun photoData(path: String): ByteArray? = runCatching {
        withContext(Dispatchers.IO) { connection("GET", path, 20_000).inputStream.use { it.readBytes() } }
    }.getOrNull()

    suspend fun exportCSV(dest: Uri): String? = runCatching {
        withContext(Dispatchers.IO) {
            val csv = connection("GET", "/export.csv", 60_000).inputStream.use { it.readBytes() }
            app.contentResolver.openOutputStream(dest)?.use { it.write(csv) } ?: throw IOException("Can't write the file")
        }
    }.exceptionOrNull()?.let { "Export failed: ${it.message}" }

    fun url(path: String) = settings.value.serverURL.trimEnd('/') + path

    // MARK: HTTP

    private suspend inline fun <reified T> get(path: String): T = json.decodeFromString(request("GET", path))

    private suspend inline fun <reified T> send(method: String, path: String, body: String): T =
        json.decodeFromString(request(method, path, body, timeout = 180_000))

    private fun connection(method: String, path: String, timeout: Int) =
        (URL(url(path)).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 10_000
            readTimeout = timeout
        }

    /** Sends a request; the server's `{"error": ...}` replies (and other failures) become a ServerError. */
    private suspend fun request(method: String, path: String, body: String? = null, timeout: Int = 20_000): String =
        withContext(Dispatchers.IO) {
            val c = connection(method, path, timeout)
            try {
                if (body != null) {
                    c.doOutput = true
                    c.setRequestProperty("content-type", "application/json")
                    c.outputStream.use { it.write(body.toByteArray()) }
                }
                val code = c.responseCode
                if (code >= 400) {
                    val text = c.errorStream?.use { it.readBytes().decodeToString() }.orEmpty()
                    val message = runCatching { json.decodeFromString(ErrorBody.serializer(), text).error }.getOrNull()
                    throw ServerError(message ?: "Server error $code")
                }
                c.inputStream.use { it.readBytes().decodeToString() }
            } finally {
                c.disconnect()
            }
        }
}
