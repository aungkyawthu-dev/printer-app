package com.example.thrid_party_printer_app

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.print.PrintManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val channelName = "receipt_bridge/printers"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getPrinters" -> result.success(PrinterStore(this).all().map { it.toMap() })
                        "savePrinter" -> {
                            @Suppress("UNCHECKED_CAST")
                            val values = call.arguments as Map<String, Any?>
                            PrinterStore(this).save(PrinterConfig.fromMap(values))
                            result.success(null)
                        }
                        "deletePrinter" -> {
                            val id = call.argument<String>("id") ?: error("Missing printer id")
                            PrinterStore(this).delete(id)
                            result.success(null)
                        }
                        "getBluetoothDevices" -> listBluetooth(result)
                        "getUsbDevices" -> result.success(listUsb())
                        "requestUsbPermission" -> {
                            requestUsb(call.argument<String>("address") ?: error("Missing USB address"))
                            result.success(null)
                        }
                        "openPrintSettings" -> {
                            startActivity(Intent(Settings.ACTION_PRINT_SETTINGS))
                            result.success(null)
                        }
                        "isPrintServiceEnabled" -> result.success(isPrintServiceEnabled())
                        "getCacheInfo" -> result.success(PrintJobCache(this).info())
                        "getServiceDiagnostics" -> result.success(ServiceDiagnostics(this).info())
                        "clearPrintCache" -> {
                            PrintJobCache(this).clear()
                            result.success(null)
                        }
                        "testPrinter" -> {
                            val id = call.argument<String>("id") ?: error("Missing printer id")
                            runTestPrint(id, result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("PRINTER_ERROR", error.message ?: error.javaClass.simpleName, null)
                }
            }
    }

    private fun runTestPrint(id: String, result: MethodChannel.Result) {
        val printer = PrinterStore(this).find(id)
        if (printer == null) {
            result.error("PRINTER_ERROR", "Printer configuration was removed", null)
            return
        }
        thread(name = "printer-test-$id") {
            try {
                openPrinterConnection(this, printer).use { connection ->
                    connection.write(byteArrayOf(0x1b, 0x40))
                    if (printer.alarm == "before") {
                        connection.write(byteArrayOf(0x1b, 0x42, 0x03, 0x02))
                    }
                    connection.write(byteArrayOf(0x1b, 0x61, 0x01))
                    connection.write(byteArrayOf(0x1b, 0x45, 0x01))
                    connection.write(byteArrayOf(0x1d, 0x21, 0x11))
                    connection.write("RECEIPT BRIDGE\n".toByteArray(Charsets.US_ASCII))
                    connection.write(byteArrayOf(0x1d, 0x21, 0x00, 0x1b, 0x45, 0x00))
                    connection.write("TEST PRINT\n\n".toByteArray(Charsets.US_ASCII))
                    connection.write(byteArrayOf(0x1b, 0x61, 0x00))
                    val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
                    val receipt = buildString {
                        appendLine("==========================================")
                        appendLine("Printer: ${printer.name}")
                        appendLine("Type: ${printer.type.uppercase(Locale.US)}")
                        appendLine("Address: ${printer.address}")
                        appendLine("Paper: 80 mm")
                        appendLine("Resolution: ${printer.dpi} dpi")
                        appendLine("Time: $time")
                        appendLine("------------------------------------------")
                        appendLine("ITEM                    QTY          AMOUNT")
                        appendLine("Test product              1          100.00")
                        appendLine("Receipt paper             1           20.00")
                        appendLine("------------------------------------------")
                        appendLine("TOTAL                                 120.00")
                        appendLine("------------------------------------------")
                        appendLine("Normal text: ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                        appendLine("Numbers: 0123456789")
                    }
                    connection.write(receipt.toByteArray(Charsets.US_ASCII))
                    connection.write(byteArrayOf(0x1b, 0x45, 0x01))
                    connection.write("BOLD TEXT TEST\n".toByteArray(Charsets.US_ASCII))
                    connection.write(byteArrayOf(0x1b, 0x45, 0x00, 0x1b, 0x61, 0x01))
                    connection.write("\nCONNECTION TEST SUCCESS\n".toByteArray(Charsets.US_ASCII))
                    connection.write("Feed and cutter test follows\n".toByteArray(Charsets.US_ASCII))
                    val drawerPin = when (printer.cashDrawer) {
                        "drawer1" -> 0x00
                        "drawer2" -> 0x01
                        else -> null
                    }
                    if (drawerPin != null) {
                        connection.write(byteArrayOf(0x1b, 0x70, drawerPin.toByte(), 0x32, 0xfa.toByte()))
                    }
                    if (printer.feedAtEnd && printer.feedLines > 0) {
                        connection.write(byteArrayOf(0x1b, 0x64, printer.feedLines.toByte()))
                    }
                    if (printer.cut) connection.write(byteArrayOf(0x1d, 0x56, 0x00))
                    if (printer.alarm == "after") {
                        connection.write(byteArrayOf(0x1b, 0x42, 0x03, 0x02))
                    }
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "TEST_PRINT_FAILED",
                        error.message ?: "Printer connection failed",
                        null,
                    )
                }
            }
        }
    }

    private fun isPrintServiceEnabled(): Boolean {
        val expected = ComponentName(this, ReceiptPrintService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
            return printManager.isPrintServiceEnabled(expected)
        }
        val enabled = Settings.Secure.getString(
            contentResolver,
            "enabled_print_services",
        ).orEmpty()
        return enabled.split(':').any { component ->
            ComponentName.unflattenFromString(component) == expected
        }
    }

    private fun listBluetooth(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), 701)
            result.error("PERMISSION", "Allow Nearby devices, then tap search again.", null)
            return
        }
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        @Suppress("MissingPermission")
        val devices = adapter?.bondedDevices?.sortedBy { it.name ?: it.address }?.map {
            mapOf("name" to (it.name ?: "Bluetooth device"), "address" to it.address)
        } ?: emptyList()
        result.success(devices)
    }

    private fun listUsb(): List<Map<String, Any>> {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        return manager.deviceList.values.sortedBy { it.deviceName }.map {
            mapOf(
                "name" to (it.productName ?: "USB ${it.vendorId}:${it.productId}"),
                "address" to it.deviceName,
                "permission" to manager.hasPermission(it),
            )
        }
    }

    private fun requestUsb(address: String) {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device = manager.deviceList[address] ?: error("USB device disconnected")
        val intent = Intent("${packageName}.USB_PERMISSION").setPackage(packageName)
        val pending = PendingIntent.getBroadcast(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.requestPermission(device, pending)
    }
}
