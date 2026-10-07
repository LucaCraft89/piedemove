package com.piedemove.piedemove

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Calendar

/// Home-screen widget: the next three departures at the first favourite
/// stop and Casa / Lavoro buttons. The app writes the departures with their
/// clock times (lib/app/home_widget.dart, via MainActivity "widget"); this
/// shows the ones still ahead, redrawn every 30 min and whenever the app
/// writes, so it stays on the timetable for hours without the app.
class NextDeparturesWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }

    companion object {
        private const val PREFS = "piedemove_widget"
        private const val KEY = "data"
        const val EXTRA_ACTION = "pm_widget_action"

        fun save(context: Context, json: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY, json).apply()
            refresh(context)
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, NextDeparturesWidget::class.java),
            )
            for (id in ids) manager.updateAppWidget(id, views(context))
        }

        private fun open(context: Context, action: String?, code: Int): PendingIntent {
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (action != null) intent.putExtra(EXTRA_ACTION, action)
            return PendingIntent.getActivity(
                context,
                code,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        private fun hhmm(ms: Long): String {
            val c = Calendar.getInstance().apply { timeInMillis = ms }
            return String.format("%02d:%02d", c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE))
        }

        fun views(context: Context): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_departures)
            v.setOnClickPendingIntent(R.id.widget_root, open(context, null, 10))
            v.setOnClickPendingIntent(R.id.widget_home, open(context, "home", 11))
            v.setOnClickPendingIntent(R.id.widget_work, open(context, "work", 12))
            val rows = intArrayOf(R.id.widget_row1, R.id.widget_row2, R.id.widget_row3)
            for (r in rows) v.setTextViewText(r, "")
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY, null)
            if (raw == null) {
                v.setTextViewText(R.id.widget_stop, "PiedeMove")
                v.setTextViewText(R.id.widget_row1, "Apri l'app per le partenze")
                return v
            }
            try {
                val j = JSONObject(raw)
                val stop = j.optString("stop", "")
                if (j.isNull("stop") || stop.isEmpty()) {
                    v.setTextViewText(R.id.widget_stop, "PiedeMove")
                    v.setTextViewText(R.id.widget_row1, "Aggiungi una fermata preferita ★")
                    v.setTextViewText(R.id.widget_row2, "per vederne qui le partenze")
                    return v
                }
                v.setTextViewText(R.id.widget_stop, stop)
                val deps = j.optJSONArray("deps")
                val now = System.currentTimeMillis()
                var shown = 0
                if (deps != null) {
                    for (i in 0 until deps.length()) {
                        if (shown >= rows.size) break
                        val d = deps.getJSONObject(i)
                        val t = d.getLong("t")
                        if (t < now - 30_000) continue
                        val live = if (d.optBoolean("live")) " •" else ""
                        v.setTextViewText(
                            rows[shown],
                            "${d.optString("l")}  ${hhmm(t)}$live  ${d.optString("h")}",
                        )
                        shown++
                    }
                }
                if (shown == 0) {
                    v.setTextViewText(R.id.widget_row1, "Nessuna partenza in vista: apri l'app")
                }
            } catch (e: Exception) {
                v.setTextViewText(R.id.widget_stop, "PiedeMove")
                v.setTextViewText(R.id.widget_row1, "Apri l'app per le partenze")
            }
            return v
        }
    }
}
