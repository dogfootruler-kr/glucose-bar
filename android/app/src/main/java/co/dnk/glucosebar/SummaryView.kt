package co.dnk.glucosebar

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The weekly summary Claude writes on the server every Sunday evening. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SummaryView(nav: Nav) {
    val data by Store.data.collectAsState()
    val generating by Store.generatingSummary.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { Store.refreshSummary() }
    fun generate() = scope.launch { error = Store.generateSummary() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Weekly summary") },
                navigationIcon = { IconButton(nav.back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    if (generating) {
                        CircularProgressIndicator(Modifier.size(20.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                    } else if (data.summary != null) {
                        IconButton(::generate, enabled = data.aiAvailable) { Icon(Icons.Filled.AutoAwesome, "Write a new summary of the past 7 days") }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            error?.let { Text(it, color = Palette.low) }
            val s = data.summary
            if (s == null) {
                Text("No summary yet", style = MaterialTheme.typography.titleMedium)
                Caption("A summary of the past 7 days is written every Sunday evening.")
                Button(::generate, enabled = !generating && data.aiAvailable) { Text("Write one now") }
                if (!data.aiAvailable) Caption("Claude is unavailable: run `claude` once on the server Mac to log in.")
            } else {
                val day = DateTimeFormatter.ofPattern("d MMMM").withZone(ZoneId.systemDefault())
                val dayYear = DateTimeFormatter.ofPattern("d MMMM yyyy").withZone(ZoneId.systemDefault())
                Caption("${day.format(s.periodStart)} – ${dayYear.format(s.periodEnd)}")
                SelectionContainer { MarkdownText(s.text) }
                Caption("Written by Claude ${DateUtils.getRelativeTimeSpanString(s.created.toEpochMilli())}")
            }
        }
    }
}

/** Minimal block Markdown: headings, bullets, paragraphs, with **bold** and *italic*. */
@Composable
fun MarkdownText(text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        text.lines().map { it.trim() }.filter { it.isNotEmpty() }.forEach { line ->
            when {
                line.startsWith("#") -> Text(inline(line.trimStart('#').trim()), style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(top = 8.dp))
                line.startsWith("- ") || line.startsWith("* ") -> Row {
                    Text("•", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(8.dp))
                    Text(inline(line.drop(2)), style = MaterialTheme.typography.bodyLarge)
                }
                else -> Text(inline(line), style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

private val emphasis = Regex("""\*\*(.+?)\*\*|\*(.+?)\*|_(.+?)_""")

private fun inline(text: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    for (m in emphasis.findAll(text)) {
        append(text.substring(i, m.range.first))
        val (bold, italic, underscore) = m.destructured
        if (bold.isNotEmpty()) withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(bold) }
        else withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(italic.ifEmpty { underscore }) }
        i = m.range.last + 1
    }
    append(text.substring(i))
}
