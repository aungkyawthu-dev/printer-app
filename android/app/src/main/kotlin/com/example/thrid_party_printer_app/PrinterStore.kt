package com.example.thrid_party_printer_app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class PrinterConfig(
    val id: String,
    val name: String,
    val type: String,
    val address: String,
    val port: Int = 9100,
    val printableWidth: Int = 72,
    val dpi: Int = 203,
    val cut: Boolean = true,
    val paperSaving: String = "compact",
    val keepAlive: Boolean = true,
    val density: Int = 3,
    val cashDrawer: String = "none",
    val alarm: String = "none",
    val feedAtEnd: Boolean = true,
    val feedLines: Int = 3,
    val paperWidth: Int = 80,
    val fitWidth: Boolean = true,
    val contentScale: Int = 85,
    val sideMarginMm: Int = 1,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "name" to name,
        "type" to type,
        "address" to address,
        "port" to port,
        "printableWidth" to printableWidth,
        "dpi" to dpi,
        "cut" to cut,
        "paperSaving" to paperSaving,
        "keepAlive" to keepAlive,
        "density" to density,
        "cashDrawer" to cashDrawer,
        "alarm" to alarm,
        "feedAtEnd" to feedAtEnd,
        "feedLines" to feedLines,
        "paperWidth" to paperWidth,
        "fitWidth" to fitWidth,
        "contentScale" to contentScale,
        "sideMarginMm" to sideMarginMm,
    )

    fun toJson() = JSONObject(toMap())

    companion object {
        fun fromMap(value: Map<String, Any?>) = PrinterConfig(
            id = value["id"]?.toString() ?: error("Missing printer id"),
            name = value["name"]?.toString()?.trim().orEmpty().ifEmpty { "80 mm Printer" },
            type = value["type"]?.toString() ?: "ethernet",
            address = value["address"]?.toString()?.trim().orEmpty(),
            port = (value["port"] as? Number)?.toInt() ?: 9100,
            // Generic 80 mm printers normally have a 72 mm / 576-dot print head.
            // Older app versions offered 80 mm / 640 dots, which clipped this printer.
            printableWidth = ((value["printableWidth"] as? Number)?.toInt() ?: 72).coerceAtMost(72),
            dpi = (value["dpi"] as? Number)?.toInt() ?: 203,
            cut = value["cut"] as? Boolean ?: true,
            paperSaving = value["paperSaving"]?.toString() ?: "compact",
            keepAlive = value["keepAlive"] as? Boolean ?: true,
            density = ((value["density"] as? Number)?.toInt() ?: 3).coerceIn(1, 5),
            cashDrawer = value["cashDrawer"]?.toString() ?: "none",
            alarm = value["alarm"]?.toString() ?: "none",
            feedAtEnd = value["feedAtEnd"] as? Boolean ?: true,
            feedLines = ((value["feedLines"] as? Number)?.toInt() ?: 3).coerceIn(0, 9),
            paperWidth = (value["paperWidth"] as? Number)?.toInt() ?: 80,
            fitWidth = value["fitWidth"] as? Boolean ?: true,
            contentScale = ((value["contentScale"] as? Number)?.toInt() ?: 85).coerceIn(65, 95),
            sideMarginMm = ((value["sideMarginMm"] as? Number)?.toInt() ?: 1).coerceIn(0, 6),
        ).also {
            require(it.address.isNotEmpty()) { "Printer address is required" }
            require(it.type in setOf("ethernet", "bluetooth", "usb")) { "Unknown connection type" }
            require(it.paperSaving in setOf("none", "compact")) { "Unknown paper-saving mode" }
            require(it.cashDrawer in setOf("none", "drawer1", "drawer2")) { "Unknown cash drawer" }
            require(it.alarm in setOf("none", "before", "after")) { "Unknown alarm mode" }
            require(it.paperWidth in setOf(72, 80, 100)) { "Paper width must be 72, 80 or 100 mm" }
        }

        fun fromJson(value: JSONObject) = fromMap(
            value.keys().asSequence().associateWith { key -> value.get(key) },
        )
    }
}

class PrinterStore(context: Context) {
    private val preferences = context.getSharedPreferences("receipt_bridge", Context.MODE_PRIVATE)

    fun all(): List<PrinterConfig> {
        val array = JSONArray(preferences.getString("printers", "[]"))
        return (0 until array.length()).map { PrinterConfig.fromJson(array.getJSONObject(it)) }
    }

    fun find(id: String): PrinterConfig? = all().firstOrNull { it.id == id }

    fun save(printer: PrinterConfig) {
        val values = all().filterNot { it.id == printer.id } + printer
        write(values)
    }

    fun delete(id: String) = write(all().filterNot { it.id == id })

    private fun write(values: List<PrinterConfig>) {
        val array = JSONArray()
        values.forEach { array.put(it.toJson()) }
        preferences.edit().putString("printers", array.toString()).apply()
    }
}
