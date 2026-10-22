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
import android.widget.RemoteViews
import java.time.Duration
import java.time.Instant

/** Home screen widget: the value and trend, coloured by range, over the last few hours. */
class Widget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        Store.init(context)
        ids.forEach { render(context, manager, it) }
        GlucoseService.start(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        render(context, manager, id)
    }

    companion object {
        private const val HOURS = 3.0

        fun update(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, Widget::class.java)).forEach { render(context, manager, it) }
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val data = Store.data.value
            val settings = Store.settings.value
            val r = data.reading
            val color = rangeColor(data.range(settings))
            val views = RemoteViews(context.packageName, R.layout.widget)
            views.setTextViewText(R.id.value, r?.let { settings.format(it.mgdl) } ?: "– –")
            views.setTextColor(R.id.value, color)
            views.setTextViewText(R.id.arrow, r?.arrow ?: "")
            views.setTextColor(R.id.arrow, color)
            views.setTextViewText(R.id.detail, r?.let {
                val mins = Duration.between(it.timestamp, Instant.now()).toMinutes()
                listOfNotNull(
                    it.delta?.let { d -> formatDelta(d, settings.useMmol) },
                    if (mins < 1) "now" else "$mins min ago",
                ).joinToString(" · ")
            } ?: (data.fetchError ?: "Waiting for the server"))
            views.setOnClickPendingIntent(R.id.root, MainActivity.intent(context))

            val options = manager.getAppWidgetOptions(id)
            val density = context.resources.displayMetrics.density
            val width = (options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 250) * density).toInt()
            val height = (options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110) * density * 0.5f).toInt()
            val points = data.history(HOURS)
            if (points.size > 1 && width > 0 && height > 0) {
                views.setImageViewBitmap(R.id.chart, Sparkline.render(points, width, height, settings, color, density, band = true))
            }
            manager.updateAppWidget(id, views)
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
        val inset = 2 * dp
        fun x(p: Point) = inset + (width - 2 * inset) * Duration.between(first, p.timestamp).seconds / span
        fun y(mgdl: Number) = inset + (height - 2 * inset) * (hi - mgdl.toFloat()) / (hi - lo)

        if (band) {
            canvas.drawRect(0f, y(settings.targetHigh), width.toFloat(), y(settings.targetLow),
                Paint().apply { this.color = 0x1F16A34A })
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
