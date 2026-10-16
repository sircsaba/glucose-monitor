package PACKAGE_NAME

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.SystemClock
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.text.DateFormat
import java.util.Date

/**
 * Home-screen widget with the latest glucose. It fetches the reading from your
 * server by itself every few minutes, even when the app is closed. It uses the
 * site address and token entered in the app.
 */
class BgWidget : AppWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action == ACTION_REFRESH || action == AppWidgetManager.ACTION_APPWIDGET_UPDATE ||
            action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val app = context.applicationContext
            val result = goAsync()
            Thread {
                try {
                    update(app)
                } catch (_: Throwable) {
                } finally {
                    schedule(app)
                    result.finish()
                }
            }.start()
        } else {
            super.onReceive(context, intent)
        }
    }

    override fun onDisabled(context: Context) {
        alarms(context).cancel(refreshIntent(context))
    }

    companion object {
        const val ACTION_REFRESH = "com.inforap.glucosemonitor.WIDGET_REFRESH"
        private const val EVERY_MS = 5 * 60 * 1000L
        private const val STALE_MS = 15 * 60 * 1000L

        private fun alarms(c: Context) = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        private fun refreshIntent(c: Context): PendingIntent =
            PendingIntent.getBroadcast(
                c, 0, Intent(c, BgWidget::class.java).setAction(ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

        private fun ids(c: Context): IntArray =
            AppWidgetManager.getInstance(c).getAppWidgetIds(ComponentName(c, BgWidget::class.java))

        fun schedule(c: Context) {
            if (ids(c).isEmpty()) return
            alarms(c).setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + EVERY_MS, refreshIntent(c)
            )
        }

        private class Reading(val mg: Int, val ms: Long, val dir: String, val delta: Int?)

        private fun settings(c: Context): JSONObject? {
            val raw = c.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.settings", null) ?: return null
            return try { JSONObject(raw).optJSONObject("v") } catch (_: Exception) { null }
        }

        private fun fetch(v: JSONObject): Reading? {
            var site = v.optString("nsUrl", "").trim().trimEnd('/')
            if (site.isEmpty()) return null
            if (!site.startsWith("http")) site = "https://$site"
            val token = v.optString("nsToken", "").trim()
            val secret = v.optBoolean("apiSecret", false)
            var u = "$site/api/v1/entries/sgv.json?count=12"
            if (!secret && token.isNotEmpty()) u += "&token=" + URLEncoder.encode(token, "UTF-8")
            val con = URL(u).openConnection() as HttpURLConnection
            con.connectTimeout = 15000
            con.readTimeout = 20000
            con.setRequestProperty("Accept", "application/json")
            if (secret && token.isNotEmpty()) {
                val sha = MessageDigest.getInstance("SHA-1").digest(token.toByteArray())
                con.setRequestProperty("api-secret", sha.joinToString("") { "%02x".format(it) })
            }
            try {
                if (con.responseCode != 200) return null
                val arr = JSONArray(con.inputStream.bufferedReader().readText())
                if (arr.length() == 0) return null
                val first = arr.getJSONObject(0)
                val mg = first.optInt("sgv", 0)
                val ms = first.optLong("date", 0)
                if (mg <= 0 || ms <= 0) return null
                // Change over 5 minutes: the reading closest to 5 minutes before.
                var delta: Int? = null
                var best = Long.MAX_VALUE
                for (i in 1 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val gap = ms - o.optLong("date", 0)
                    if (gap < 150000 || gap > 450000) continue
                    val off = Math.abs(gap - 300000)
                    if (off < best) { best = off; delta = mg - o.optInt("sgv", mg) }
                }
                return Reading(mg, ms, first.optString("direction", ""), delta)
            } finally {
                con.disconnect()
            }
        }

        private fun arrow(d: String) = when (d) {
            "DoubleUp" -> "⇈"; "SingleUp" -> "↑"; "FortyFiveUp" -> "↗"; "Flat" -> "→"
            "FortyFiveDown" -> "↘"; "SingleDown" -> "↓"; "DoubleDown" -> "⇊"; else -> ""
        }

        fun update(c: Context) {
            val ids = ids(c)
            if (ids.isEmpty()) return
            val v = settings(c)
            val cache = c.getSharedPreferences("bg_widget", Context.MODE_PRIVATE)
            val fresh = try { v?.let { fetch(it) } } catch (_: Exception) { null }
            if (fresh != null) {
                cache.edit().putInt("mg", fresh.mg).putLong("ms", fresh.ms).putString("dir", fresh.dir)
                    .putInt("delta", fresh.delta ?: Int.MIN_VALUE).apply()
            }
            val mmol = v?.optBoolean("mmol", true) ?: true
            val mg = cache.getInt("mg", 0)
            val ms = cache.getLong("ms", 0)
            val dir = cache.getString("dir", "") ?: ""
            val delta = cache.getInt("delta", Int.MIN_VALUE).takeIf { it != Int.MIN_VALUE }

            val rv = RemoteViews(c.packageName, R.layout.bg_widget)
            fun id(n: String) = when (n) {
                "bg" -> R.id.bg; "arrow" -> R.id.arrow; "delta" -> R.id.delta; "time" -> R.id.time; else -> R.id.root
            }
            val now = System.currentTimeMillis()
            if (mg <= 0) {
                rv.setTextViewText(id("bg"), "--")
                rv.setTextViewText(id("arrow"), "")
                rv.setTextViewText(id("delta"), "")
                rv.setTextViewText(id("time"), if (v == null) "Open the app" else "No data")
                rv.setTextColor(id("bg"), Color.GRAY)
            } else {
                val stale = now - ms > STALE_MS
                val color = when {
                    stale -> Color.GRAY
                    mg < 70 -> Color.parseColor("#FF5252")
                    mg <= 180 -> Color.parseColor("#4CAF50")
                    mg <= 250 -> Color.parseColor("#FFC107")
                    else -> Color.parseColor("#FF5252")
                }
                rv.setTextViewText(id("bg"), if (mmol) String.format("%.1f", mg / 18.0) else mg.toString())
                rv.setTextColor(id("bg"), color)
                rv.setTextViewText(id("arrow"), if (stale) "⚠" else arrow(dir))
                rv.setTextViewText(id("delta"), when {
                    delta == null || stale -> ""
                    mmol -> String.format("%+.1f", delta / 18.0)
                    else -> String.format("%+d", delta)
                })
                val min = ((now - ms) / 60000).coerceAtLeast(0)
                val at = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))
                rv.setTextViewText(id("time"), if (min < 1) at else "$at · $min min")
            }
            c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
                rv.setOnClickPendingIntent(id("root"),
                    PendingIntent.getActivity(c, 1, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            AppWidgetManager.getInstance(c).updateAppWidget(ids, rv)
        }
    }
}
