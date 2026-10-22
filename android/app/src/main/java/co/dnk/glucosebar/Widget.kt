package co.dnk.glucosebar

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import java.time.Duration
import java.time.Instant

/**
 * Home screen widget in three sizes: just the value when small, with the last 3 hours when medium, and with the
 * last 6 hours and the forecast when tall. Android picks the layout that fits as the widget is resized.
 */
class Widget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        Store.init(context)
        ids.forEach { render(context, manager, it) }
        GlucoseService.start(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        render(context, manager, id)
    }

    /** A layout, the smallest size (dp) it's used from, and how many hours its chart shows. */
    private enum class Layout(val res: Int, val size: SizeF, val hours: Double) {
        Small(R.layout.widget_small, SizeF(50f, 50f), 0.0),
        Medium(R.layout.widget, SizeF(140f, 90f), 3.0),
        Large(R.layout.widget_large, SizeF(140f, 170f), 6.0),
    }

    companion object {
        fun update(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, Widget::class.java)).forEach { render(context, manager, it) }
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            // The sizes the launcher shows the widget at (portrait and landscape), to draw each chart at its real size.
            val sizes = manager.getAppWidgetOptions(id)
                .getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java).orEmpty()
            val views = Layout.entries.associate { layout ->
                val next = Layout.entries.getOrNull(layout.ordinal + 1)
                val actual = sizes.filter { it.width >= layout.size.width && it.height >= layout.size.height }
                    .filter { next == null || it.width < next.size.width || it.height < next.size.height }
                    .maxByOrNull { it.width * it.height } ?: layout.size
                layout.size to views(context, layout, actual)
            }
            manager.updateAppWidget(id, RemoteViews(views))
        }

        private fun views(context: Context, layout: Layout, size: SizeF): RemoteViews {
            val data = Store.data.value
            val settings = Store.settings.value
            val r = data.reading
            val color = rangeColor(data.range(settings))
            val views = RemoteViews(context.packageName, layout.res)
            views.setOnClickPendingIntent(R.id.root, MainActivity.intent(context))
            views.setTextViewText(R.id.value, r?.let { settings.format(it.mgdl) } ?: "– –")
            views.setTextColor(R.id.value, color)
            views.setTextViewText(R.id.arrow, r?.arrow ?: "")
            views.setTextColor(R.id.arrow, color)
            views.setTextViewText(R.id.delta, r?.delta?.let { formatDelta(it, settings.useMmol) } ?: "")
            views.setTextColor(R.id.delta, color)
            views.setTextViewText(R.id.age, when {
                r == null -> data.fetchError ?: "Waiting for the server"
                data.isStale(settings) -> "⚠︎ " + age(r.timestamp)
                else -> age(r.timestamp)
            })
            if (layout == Layout.Large) {
                val hit = data.headingLow(settings)
                val in30 = data.in30
                views.setTextViewText(R.id.forecast, when {
                    hit != null -> "Heading low: ${settings.format(hit.second)} around ${formatTime(hit.first)}"
                    in30 != null -> "About ${settings.format(in30)} in 30 min"
                    else -> ""
                })
                views.setTextColor(R.id.forecast, if (hit != null) rangeColor(Range.Low) else context.getColor(R.color.widget_secondary))
            }
            if (layout.hours > 0) {
                val density = context.resources.displayMetrics.density
                // Header and padding take about 64 dp (84 with the forecast line).
                val chartHeight = size.height - if (layout == Layout.Large) 84 else 64
                val points = data.history(layout.hours)
                if (points.size > 1 && chartHeight > 16) {
                    views.setImageViewBitmap(R.id.chart, Sparkline.render(points, ((size.width - 24) * density).toInt(),
                        (chartHeight * density).toInt(), settings, color, density, band = true))
                }
            }
            return views
        }

        private fun age(t: Instant): String {
            val mins = Duration.between(t, Instant.now()).toMinutes()
            return if (mins < 1) "now" else "$mins min ago"
        }
    }
}

/** A small glucose line, drawn as a bitmap for the notification and the widget. */
object Sparkline {
    fun render(
        points: List<Point>, width: Int, height: Int, settings: Settings, color: Int, dp: Float, band: Boolean = false,
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val first = points.first().timestamp
        val span = Duration.between(first, points.last().timestamp).seconds.coerceAtLeast(1).toFloat()
        val lo = minOf(points.minOf { it.mgdl }, settings.targetLow) - 5f
        val hi = maxOf(points.maxOf { it.mgdl }, settings.targetHigh) + 5f
        val inset = 3.5f * dp  // room for the dot on the last reading
        fun x(p: Point) = inset + (width - 2 * inset) * Duration.between(first, p.timestamp).seconds / span
        fun y(mgdl: Number) = inset + (height - 2 * inset) * (hi - mgdl.toFloat()) / (hi - lo)

        if (band) {
            canvas.drawRect(0f, y(settings.targetHigh), width.toFloat(), y(settings.targetLow),
                Paint().apply { this.color = 0x1416A34A })
            val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                this.color = 0x4016A34A
                strokeWidth = dp
                style = Paint.Style.STROKE
                pathEffect = DashPathEffect(floatArrayOf(4 * dp, 3 * dp), 0f)
            }
            canvas.drawLine(0f, y(settings.targetHigh), width.toFloat(), y(settings.targetHigh), dash)
            canvas.drawLine(0f, y(settings.targetLow), width.toFloat(), y(settings.targetLow), dash)
        }
        val path = Path()
        points.forEachIndexed { i, p -> if (i == 0) path.moveTo(x(p), y(p.mgdl)) else path.lineTo(x(p), y(p.mgdl)) }
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            style = Paint.Style.STROKE
            strokeWidth = 1.6f * dp
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        })
        val last = points.last()
        canvas.drawCircle(x(last), y(last.mgdl), 2.5f * dp, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
        return bitmap
    }
}
