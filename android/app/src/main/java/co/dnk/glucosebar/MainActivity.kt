package co.dnk.glucosebar

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The screens, in a simple back stack. */
sealed interface Screen {
    data object Home : Screen
    data class Entry(val id: Int? = null) : Screen
    data object Journal : Screen
    data class Detail(val id: Int) : Screen
    data object Summary : Screen
    data object Settings : Screen
}

class MainActivity : ComponentActivity() {
    private val stack = mutableStateListOf<Screen>(Screen.Home)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) open(intent)
        setContent {
            GlucoseTheme {
                BackHandler(stack.size > 1) { back() }
                val nav = Nav(::push, ::back)
                when (val screen = stack.last()) {
                    Screen.Home -> HomeScreen(nav)
                    is Screen.Entry -> EntryEditor(nav, screen.id)
                    Screen.Journal -> JournalView(nav)
                    is Screen.Detail -> EntryDetailScreen(nav, screen.id)
                    Screen.Summary -> SummaryView(nav)
                    Screen.Settings -> SettingsView(nav)
                }
                FirstRun()
            }
        }
        GlucoseService.start(this)
        // Poll every 30 seconds while a screen is showing, with the stats and journal as well.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                Store.uiVisible = true
                try {
                    while (true) {
                        Store.refresh(full = true)
                        delay(30_000)
                    }
                } finally {
                    Store.uiVisible = false
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        open(intent)
    }

    private fun open(intent: Intent) {
        val screen = when (intent.getStringExtra(EXTRA_SCREEN)) {
            "log" -> Screen.Entry()
            "summary" -> Screen.Summary
            "settings" -> Screen.Settings
            else -> return
        }
        stack.clear()
        stack.addAll(listOf(Screen.Home, screen))
    }

    private fun push(screen: Screen) = stack.add(screen)
    private fun back() { if (stack.size > 1) stack.removeAt(stack.lastIndex) else finish() }

    companion object {
        private const val EXTRA_SCREEN = "screen"
        private val screens = listOf(null, "log", "summary", "settings")

        /** Opens the app, optionally on one screen ("log", "summary" or "settings"). */
        fun intent(context: Context, screen: String? = null): PendingIntent = PendingIntent.getActivity(
            context, screens.indexOf(screen),
            Intent(context, MainActivity::class.java).putExtra(EXTRA_SCREEN, screen).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

/** Moving between screens. */
class Nav(val open: (Screen) -> Unit, val back: () -> Unit)

/** Asks once for notifications and to keep polling in battery saving (Doze), so alerts come through with the screen off. */
@Composable
private fun FirstRun() {
    val context = LocalContext.current as ComponentActivity
    LaunchedEffect(Unit) {
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            context.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        } else if (Store.pref("askedBattery") == 0L &&
            !context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)) {
            Store.setPref("askedBattery", 1)
            requestBatteryExemption(context)
        }
    }
}

fun requestBatteryExemption(context: Context) {
    context.startActivity(Intent(AndroidSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")))
}

/** Range and entry colours, matching the web page. */
object Palette {
    val low = Color(0xFFDC2626)
    val high = Color(0xFFEA580C)
    val ok = Color(0xFF16A34A)
    val meal = Color(0xFFEA580C)
    val insulin = Color(0xFF9333EA)
    val longInsulin = Color(0xFF4F46E5)
    val exercise = Color(0xFF0D9488)

    fun of(range: Range): Color = Color(rangeColor(range))
    fun of(mgdl: Int, settings: Settings): Color = of(Range.of(mgdl, settings))
}

@Composable
fun GlucoseTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context),
        content = content,
    )
}
