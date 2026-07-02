package com.example.thrid_party_printer_app

import android.content.Context
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ServiceDiagnostics(context: Context) {
    private val preferences = context.getSharedPreferences("print_service_diagnostics", Context.MODE_PRIVATE)

    @Synchronized
    fun record(message: String, connected: Boolean? = null) {
        val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val entries = entries().toMutableList()
        entries.add(0, "$timestamp  $message")
        while (entries.size > 30) entries.removeLast()
        val editor = preferences.edit()
            .putString("events", JSONArray(entries).toString())
            .putString("lastEvent", entries.first())
        if (connected != null) editor.putBoolean("connected", connected)
        editor.commit()
    }

    fun info(): Map<String, Any> = mapOf(
        "connected" to preferences.getBoolean("connected", false),
        "lastEvent" to preferences.getString("lastEvent", "No print-service event yet").orEmpty(),
        "events" to entries(),
    )

    private fun entries(): List<String> {
        val array = JSONArray(preferences.getString("events", "[]"))
        return (0 until array.length()).map { array.optString(it) }
    }
}
