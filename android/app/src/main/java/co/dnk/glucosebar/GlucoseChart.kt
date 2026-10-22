package co.dnk.glucosebar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.abs
import kotlin.math.roundToInt

private val timeFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())
fun formatTime(t: Instant): String = timeFormat.format(t)

/**
 * Glucose over a time window with the target band, an optional forecast (dotted), meal/insulin/exercise markers and
 * a value under the finger. Used on the home screen and for one entry's response.
 */
@Composable
fun GlucoseChart(
    points: List<Point>,
    start: Instant,
    end: Instant,
    settings: Settings,
    modifier: Modifier = Modifier,
    forecast: List<Point> = emptyList(),
    events: List<GlucoseEvent> = emptyList(),
    /** The entry the chart is about: drawn stronger, with labels on every marker. */
    highlight: Int? = null,
    low: ExerciseImpact.Low? = null,
    height: Dp = 180.dp,
) {
    val measurer = rememberTextMeasurer()
    val colors = MaterialTheme.colorScheme
    val labelStyle = TextStyle(fontSize = 10.sp, color = colors.onSurfaceVariant)
    val maxValue = maxOf(250, ((points + forecast).maxOfOrNull { it.mgdl } ?: 0) + 30)
    val span = Duration.between(start, end).seconds.coerceAtLeast(1).toFloat()
    var touchX by remember { mutableStateOf<Float?>(null) }
    var width by remember { mutableStateOf(1f) }

    fun x(t: Instant, w: Float) = w * Duration.between(start, t).seconds / span
    fun timeAt(px: Float, w: Float): Instant = start.plusSeconds((px / w * span).toLong())

    val touched = touchX?.let { tx ->
        val t = timeAt(tx, width)
        points.minByOrNull { abs(Duration.between(it.timestamp, t).seconds) }?.let { p ->
            val near = events.filter {
                abs(Duration.between(it.timestamp, t).seconds) < span / 40 || (it.isExercise && t >= it.timestamp && t <= it.end)
            }
            p to near
        }
    }

    Box(modifier.fillMaxWidth().height(height)) {
        Canvas(
            Modifier.fillMaxWidth().height(height).pointerInput(points) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    touchX = down.position.x
                    do {
                        val event = awaitPointerEvent()
                        event.changes.firstOrNull()?.let { touchX = it.position.x; it.consume() }
                    } while (event.changes.any { it.pressed })
                    touchX = null
                }
            },
        ) {
            width = size.width
            // Room above the plot for marker labels (one row, or two on an entry's chart).
            val top = (if (highlight != null) 26 else 14).dp.toPx()
            val bottom = size.height - 14.dp.toPx()
            fun y(mgdl: Int) = bottom - (bottom - top) * (mgdl - 40f) / (maxValue - 40f)

            // Grid and labels.
            // Every 50 mg/dL, or every 3 mmol/L.
            val ticks = generateSequence(1) { it + 1 }
                .map { if (settings.useMmol) (it * 3 * 18.0182).roundToInt() else it * 50 }
                .takeWhile { it < maxValue }.filter { it > 45 }
            for (tick in ticks) {
                drawLine(colors.outlineVariant.copy(alpha = 0.5f), Offset(0f, y(tick)), Offset(size.width, y(tick)), 1f)
                drawText(measurer, settings.format(tick), Offset(2f, y(tick) - 13.sp.toPx()), labelStyle)
            }
            var hour = start.atZone(ZoneId.systemDefault()).withMinute(0).withSecond(0).withNano(0).plusHours(1).toInstant()
            val hourStep = maxOf(1L, (span / 3600 / 6).roundToInt().toLong())
            while (hour < end) {
                val label = measurer.measure(formatTime(hour), labelStyle)
                val hx = x(hour, size.width)
                if (hx + label.size.width / 2 < size.width && hx - label.size.width / 2 > 0) {
                    drawText(label, topLeft = Offset(hx - label.size.width / 2, bottom + 1.dp.toPx()))
                }
                hour = hour.plusSeconds(3600 * hourStep)
            }

            // Target band.
            drawRect(Palette.ok.copy(alpha = 0.12f), Offset(0f, y(settings.targetHigh)),
                Size(size.width, y(settings.targetLow) - y(settings.targetHigh)))

            // Exercise spans.
            for (e in events.filter { it.isExercise }) {
                val x0 = x(maxOf(e.timestamp, start), size.width)
                val x1 = x(minOf(e.end, end), size.width)
                val alpha = if (e.id == highlight) 0.2f else if (e.isPlanned) 0.06f else 0.12f
                drawRect(Palette.exercise.copy(alpha = alpha), Offset(x0, top), Size(x1 - x0, bottom - top))
            }

            // Glucose and forecast.
            if (points.size > 1) {
                val path = Path()
                points.forEachIndexed { i, p ->
                    if (i == 0) path.moveTo(x(p.timestamp, size.width), y(p.mgdl)) else path.lineTo(x(p.timestamp, size.width), y(p.mgdl))
                }
                drawPath(path, colors.primary, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            val last = points.lastOrNull()
            if (last != null && forecast.isNotEmpty()) {
                val path = Path().apply { moveTo(x(last.timestamp, size.width), y(last.mgdl)) }
                forecast.forEach { path.lineTo(x(it.timestamp, size.width), y(it.mgdl)) }
                drawPath(path, colors.onSurfaceVariant, style = Stroke(1.5.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))))
            }
            if (last != null && highlight == null) {
                drawCircle(Palette.of(last.mgdl, settings), 4.dp.toPx(), Offset(x(last.timestamp, size.width), y(last.mgdl)))
            }

            // Entry markers; labels that would overlap the one before go on a second row.
            var labelEnd = -1f
            var row = 0
            for (e in events.filter { it.timestamp >= start && it.timestamp <= end }.sortedBy { it.timestamp }) {
                val ex = x(e.timestamp, size.width)
                val tint = e.tint.copy(alpha = if (e.isPlanned) 0.6f else 1f)
                drawLine(tint.copy(alpha = if (e.id == highlight) 0.8f else 0.35f), Offset(ex, top), Offset(ex, bottom), 1.dp.toPx(),
                    pathEffect = if (e.isInsulin) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx())) else null)
                if (highlight != null) {
                    val label = measurer.measure(e.shortLabel, labelStyle.copy(color = e.tint))
                    val lx = (ex - label.size.width / 2).coerceIn(0f, size.width - label.size.width)
                    row = if (lx < labelEnd && row == 0) 1 else 0
                    if (row == 0) labelEnd = lx + label.size.width + 2.dp.toPx()
                    drawText(label, topLeft = Offset(lx, row * (label.size.height + 1f)))
                } else {
                    drawCircle(tint, 4.dp.toPx(), Offset(ex, top))
                }
            }
            low?.let {
                drawCircle(Palette.low, 4.dp.toPx(), Offset(x(it.timestamp, size.width), y(it.mgdl)))
            }

            // Value under the finger.
            touched?.first?.let { p ->
                val px = x(p.timestamp, size.width)
                drawLine(colors.onSurfaceVariant.copy(alpha = 0.6f), Offset(px, top), Offset(px, bottom), 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())))
                drawCircle(Palette.of(p.mgdl, settings), 5.dp.toPx(), Offset(px, y(p.mgdl)))
            }
        }
        touched?.let { (p, near) ->
            val density = LocalDensity.current
            val boxWidth = 150.dp
            val left = with(density) {
                (x(p.timestamp, width) - boxWidth.toPx() / 2).coerceIn(0f, (width - boxWidth.toPx()).coerceAtLeast(0f))
            }
            Column(
                Modifier.offset { IntOffset(left.roundToInt(), 0) }
                    .background(colors.surfaceContainerHighest, RoundedCornerShape(6.dp))
                    .border(1.dp, colors.outlineVariant, RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text("${settings.format(p.mgdl)} ${settings.unit}", style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold))
                Text(formatTime(p.timestamp), style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                near.forEach { Text(it.label, style = MaterialTheme.typography.labelSmall, color = it.tint, maxLines = 1) }
            }
        }
        if (points.isEmpty()) {
            Text("No readings", Modifier.align(Alignment.Center), style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
        }
    }
}
