package com.example.thrid_party_printer_app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PrintAttributes
import android.print.PrinterCapabilitiesInfo
import android.print.PrinterId
import android.print.PrinterInfo
import android.printservice.PrintJob
import android.printservice.PrintService
import android.printservice.PrinterDiscoverySession
import java.io.Closeable
import java.io.File
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.roundToInt

class ReceiptPrintService : PrintService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val keptConnections = ConcurrentHashMap<String, PrinterConnection>()
    private val connectionLocks = ConcurrentHashMap<String, Any>()

    override fun onConnected() {
        super.onConnected()
        ServiceDiagnostics(this).record("Android connected to ReceiptPrintService", connected = true)
    }

    override fun onDisconnected() {
        keptConnections.values.forEach { connection ->
            try { connection.close() } catch (_: Exception) { }
        }
        keptConnections.clear()
        connectionLocks.clear()
        ServiceDiagnostics(this).record("Android disconnected from ReceiptPrintService", connected = false)
        super.onDisconnected()
    }

    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession {
        ServiceDiagnostics(this).record("Printer discovery session created")
        return ReceiptDiscoverySession(this)
    }

    override fun onPrintJobQueued(printJob: PrintJob) {
        // Android requires every PrintJob method to be invoked on this main callback thread.
        val diagnostics = ServiceDiagnostics(this)
        val jobId = printJob.id.toString()
        val localId = printJob.info.printerId?.localId
        val copies = printJob.info.copies.coerceAtLeast(1)
        val descriptor = printJob.document.data
        diagnostics.record("Chrome job queued: $jobId, printer=$localId")
        if (localId == null) {
            diagnostics.record("Job $jobId failed: no destination printer")
            printJob.fail("Print job has no destination printer")
            descriptor?.close()
            return
        }
        val printer = PrinterStore(this).find(localId)
        if (printer == null) {
            diagnostics.record("Job $jobId failed: printer configuration missing")
            printJob.fail("Printer configuration was removed")
            descriptor?.close()
            return
        }
        if (descriptor == null) {
            diagnostics.record("Job $jobId failed: document data unavailable")
            printJob.fail("Print document is unavailable")
            return
        }
        if (!printJob.start()) {
            diagnostics.record("Job $jobId could not transition from queued to started")
            descriptor.close()
            return
        }
        diagnostics.record("Job $jobId started on main thread")
        val cancelled = AtomicBoolean(false)
        cancellations[jobId] = cancelled

        thread(name = "receipt-print-$jobId") {
            val cache = PrintJobCache(this)
            var cachedDocument: File? = null
            try {
                val document = cache.store(jobId, descriptor)
                cachedDocument = document
                withPrinterConnection(printer) { connection ->
                    connection.write(byteArrayOf(0x1b, 0x40)) // ESC @ initialize
                    if (printer.alarm == "before") soundAlarm(connection)
                    renderDocument(document, cancelled, printer, connection, copies)
                    pulseCashDrawer(printer, connection)
                    if (printer.feedAtEnd && printer.feedLines > 0) {
                        connection.write(byteArrayOf(0x1b, 0x64, printer.feedLines.toByte()))
                    }
                    if (printer.cut) connection.write(byteArrayOf(0x1d, 0x56, 0x00))
                    if (printer.alarm == "after") soundAlarm(connection)
                }
                mainHandler.post {
                    cancellations.remove(jobId)
                    if (!cancelled.get()) {
                        printJob.complete()
                        cache.delete(document)
                        diagnostics.record("Job $jobId completed")
                    } else {
                        cache.delete(document)
                        diagnostics.record("Job $jobId cancelled")
                    }
                }
            } catch (error: Exception) {
                val message = error.message ?: "Printer connection failed"
                mainHandler.post {
                    cancellations.remove(jobId)
                    if (cancelled.get()) {
                        cachedDocument?.let { cache.delete(it) }
                        diagnostics.record("Job $jobId cancelled")
                    } else {
                        printJob.fail(message)
                        diagnostics.record("Job $jobId failed: $message")
                    }
                }
            }
        }
    }

    override fun onRequestCancelPrintJob(printJob: PrintJob) {
        val jobId = printJob.id.toString()
        cancellations[jobId]?.set(true)
        printJob.cancel()
        ServiceDiagnostics(this).record("Cancellation requested for job $jobId")
    }

    private fun renderDocument(
        document: File,
        cancelled: AtomicBoolean,
        printer: PrinterConfig,
        connection: PrinterConnection,
        copies: Int,
    ) {
        val descriptor = ParcelFileDescriptor.open(document, ParcelFileDescriptor.MODE_READ_ONLY)
        PdfRenderer(descriptor).use { renderer ->
            repeat(copies) {
                for (index in 0 until renderer.pageCount) {
                    if (cancelled.get()) return
                    renderer.openPage(index).use { page ->
                        val dots = ((printer.printableWidth / 25.4 * printer.dpi).roundToInt() / 8 * 8)
                            .coerceIn(384, 1200)
                        val height = (dots.toFloat() * page.height / page.width).roundToInt().coerceIn(1, 24000)
                        val bitmap = Bitmap.createBitmap(dots, height, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        val scale = dots.toFloat() / page.width
                        page.render(bitmap, null, Matrix().apply { postScale(scale, scale) }, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        EscPosRaster.write(
                            bitmap,
                            connection,
                            density = printer.density,
                            compact = printer.paperSaving == "compact",
                            fitWidth = printer.fitWidth,
                            contentScale = printer.contentScale,
                            sideMarginMm = printer.sideMarginMm,
                        )
                        bitmap.recycle()
                    }
                }
            }
        }
    }

    private fun withPrinterConnection(
        printer: PrinterConfig,
        block: (PrinterConnection) -> Unit,
    ) {
        if (!printer.keepAlive) {
            openPrinterConnection(this, printer).use(block)
            return
        }
        val key = "${printer.id}|${printer.type}|${printer.address}|${printer.port}"
        keptConnections.keys.filter { it.startsWith("${printer.id}|") && it != key }.forEach { staleKey ->
            keptConnections.remove(staleKey)?.let { stale ->
                try { stale.close() } catch (_: Exception) { }
            }
            connectionLocks.remove(staleKey)
        }
        val lock = connectionLocks.getOrPut(key) { Any() }
        synchronized(lock) {
            val connection = keptConnections[key] ?: openPrinterConnection(this, printer).also {
                keptConnections[key] = it
            }
            try {
                block(connection)
            } catch (error: Exception) {
                keptConnections.remove(key)
                try { connection.close() } catch (_: Exception) { }
                throw error
            }
        }
    }

    private fun soundAlarm(connection: PrinterConnection) {
        // Common ESC/POS buzzer command: three short beeps.
        connection.write(byteArrayOf(0x1b, 0x42, 0x03, 0x02))
    }

    private fun pulseCashDrawer(printer: PrinterConfig, connection: PrinterConnection) {
        val pin = when (printer.cashDrawer) {
            "drawer1" -> 0x00
            "drawer2" -> 0x01
            else -> return
        }
        connection.write(byteArrayOf(0x1b, 0x70, pin.toByte(), 0x32, 0xfa.toByte()))
    }

}

private class ReceiptDiscoverySession(private val service: ReceiptPrintService) : PrinterDiscoverySession() {
    override fun onStartPrinterDiscovery(priorityList: MutableList<PrinterId>) = publish()
    override fun onValidatePrinters(printerIds: MutableList<PrinterId>) = publish()
    override fun onStopPrinterDiscovery() = Unit
    override fun onStartPrinterStateTracking(printerId: PrinterId) = publish()
    override fun onStopPrinterStateTracking(printerId: PrinterId) = Unit
    override fun onDestroy() = Unit

    private fun publish() {
        val printers = PrinterStore(service).all().map { config ->
            val id = service.generatePrinterId(config.id)
            val capabilities = PrinterCapabilitiesInfo.Builder(id)
                .addMediaSize(media(80, 200), config.paperWidth == 80)
                .addMediaSize(media(80, 500), false)
                .addMediaSize(media(80, 1000), false)
                .addMediaSize(media(72, 200), config.paperWidth == 72)
                .addMediaSize(media(72, 500), false)
                .addMediaSize(media(72, 1000), false)
                .addMediaSize(media(100, 200), config.paperWidth == 100)
                .addMediaSize(media(100, 500), false)
                .addMediaSize(media(100, 1000), false)
                .addResolution(
                    PrintAttributes.Resolution("${config.dpi}dpi", "${config.dpi} dpi", config.dpi, config.dpi),
                    true,
                )
                .setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
                .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                .build()
            PrinterInfo.Builder(id, config.name, PrinterInfo.STATUS_IDLE)
                .setDescription("${config.type.uppercase()} • 80 mm ESC/POS")
                .setCapabilities(capabilities)
                .build()
        }
        if (printers.isNotEmpty()) addPrinters(printers)
    }

    private fun media(widthMm: Int, heightMm: Int) = PrintAttributes.MediaSize(
        "${widthMm}mm_$heightMm",
        "$widthMm mm Roll – $heightMm mm",
        mmToMils(widthMm),
        mmToMils(heightMm),
    )

    private fun mmToMils(mm: Int) = (mm / 25.4 * 1000).roundToInt()
}

internal fun openPrinterConnection(context: Context, printer: PrinterConfig): PrinterConnection = when (printer.type) {
    "ethernet" -> SocketPrinterConnection(printer.address, printer.port)
    "bluetooth" -> BluetoothPrinterConnection(context, printer.address)
    "usb" -> UsbPrinterConnection(context, printer.address)
    else -> error("Unsupported connection ${printer.type}")
}

internal interface PrinterConnection : Closeable {
    fun write(bytes: ByteArray)
}

private class SocketPrinterConnection(host: String, port: Int) : PrinterConnection {
    private val socket = Socket().apply { connect(InetSocketAddress(host, port), 7000) }
    private val output: OutputStream = socket.getOutputStream()
    override fun write(bytes: ByteArray) { output.write(bytes) }
    override fun close() { output.flush(); socket.close() }
}

@SuppressLint("MissingPermission")
private class BluetoothPrinterConnection(context: Context, address: String) : PrinterConnection {
    private val socket = run {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) error("Nearby devices permission is required; open Receipt Bridge and scan Bluetooth first")
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            ?: error("Bluetooth is not available")
        if (!adapter.isEnabled) error("Bluetooth is turned off")
        adapter.cancelDiscovery()
        val device = adapter.getRemoteDevice(address)
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            error("Pair this printer in Android Bluetooth settings first")
        }
        connectWithFallback(device)
    }
    private val output = socket.outputStream
    override fun write(bytes: ByteArray) { output.write(bytes) }
    override fun close() { output.flush(); socket.close() }

    private fun connectWithFallback(device: BluetoothDevice): BluetoothSocket {
        val spp = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        val uuids = linkedSetOf(spp)
        device.uuids?.forEach { uuids.add(it.uuid) }
        val attempts = mutableListOf<Pair<String, () -> BluetoothSocket>>()
        uuids.forEach { uuid ->
            attempts += "insecure SPP $uuid" to {
                device.createInsecureRfcommSocketToServiceRecord(uuid)
            }
            attempts += "secure SPP $uuid" to {
                device.createRfcommSocketToServiceRecord(uuid)
            }
        }
        attempts += "RFCOMM channel 1" to {
            val method = device.javaClass.getMethod(
                "createRfcommSocket",
                Int::class.javaPrimitiveType,
            )
            method.invoke(device, 1) as BluetoothSocket
        }

        val failures = mutableListOf<String>()
        attempts.forEach { (name, factory) ->
            var candidate: BluetoothSocket? = null
            try {
                candidate = factory()
                candidate.connect()
                Thread.sleep(250)
                return candidate
            } catch (error: Exception) {
                failures += "$name: ${error.message ?: error.javaClass.simpleName}"
                try { candidate?.close() } catch (_: Exception) { }
                Thread.sleep(150)
            }
        }
        val summary = failures.takeLast(3).joinToString("; ")
        error("Bluetooth SPP connection failed. Restart and re-pair the printer. $summary")
    }
}

private class UsbPrinterConnection(context: Context, address: String) : PrinterConnection {
    private val connection: UsbDeviceConnection
    private val usbInterface: UsbInterface
    private val endpoint: UsbEndpoint

    init {
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        val device = manager.deviceList[address] ?: error("USB printer is disconnected")
        if (!manager.hasPermission(device)) error("USB permission is required; reconnect it from Receipt Bridge")
        var selectedInterface: UsbInterface? = null
        var selectedEndpoint: UsbEndpoint? = null
        search@ for (interfaceIndex in 0 until device.interfaceCount) {
            val candidate = device.getInterface(interfaceIndex)
            for (endpointIndex in 0 until candidate.endpointCount) {
                val possible = candidate.getEndpoint(endpointIndex)
                if (possible.direction == UsbConstants.USB_DIR_OUT && possible.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                    selectedInterface = candidate
                    selectedEndpoint = possible
                    break@search
                }
            }
        }
        usbInterface = selectedInterface ?: error("USB device has no printer output endpoint")
        endpoint = selectedEndpoint ?: error("USB device has no bulk output endpoint")
        connection = manager.openDevice(device) ?: error("Could not open USB printer")
        if (!connection.claimInterface(usbInterface, true)) {
            connection.close()
            error("Could not claim USB printer interface")
        }
    }

    override fun write(bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val length = minOf(16_384, bytes.size - offset)
            val chunk = bytes.copyOfRange(offset, offset + length)
            val sent = connection.bulkTransfer(endpoint, chunk, chunk.size, 7000)
            if (sent <= 0) error("USB printer stopped responding")
            offset += sent
        }
    }

    override fun close() { connection.releaseInterface(usbInterface); connection.close() }
}

private object EscPosRaster {
    fun write(
        bitmap: Bitmap,
        connection: PrinterConnection,
        density: Int,
        compact: Boolean,
        fitWidth: Boolean,
        contentScale: Int,
        sideMarginMm: Int,
    ) {
        val scanPixels = IntArray(bitmap.width)
        val content = if (compact || fitWidth) {
            contentBounds(bitmap, scanPixels)
        } else {
            Rect(0, 0, bitmap.width, bitmap.height)
        }
        var working = bitmap
        var ownsWorking = false
        var startRow = if (compact) content.top else 0
        var endRow = if (compact) content.bottom else bitmap.height
        if (fitWidth && content.width() < bitmap.width - 8) {
            val cropTop = if (compact) content.top else 0
            val cropBottom = if (compact) content.bottom else bitmap.height
            val cropped = Bitmap.createBitmap(
                bitmap,
                content.left,
                cropTop,
                content.width().coerceAtLeast(1),
                (cropBottom - cropTop).coerceAtLeast(1),
            )
            // Horizontal width and vertical text size are independent: this permits
            // small text with narrow physical margins, as receipt users expect.
            val widthFraction = 1f - (2f * sideMarginMm.coerceIn(0, 6) / 72f)
            val targetWidth = (bitmap.width * widthFraction)
                .roundToInt() / 8 * 8
            val verticalWidth = bitmap.width * (contentScale.coerceIn(65, 95) / 100f)
            val scaledHeight = (cropped.height.toFloat() * verticalWidth / cropped.width)
                .roundToInt()
                .coerceIn(1, 24000)
            val scaled = Bitmap.createScaledBitmap(cropped, targetWidth, scaledHeight, true)
            cropped.recycle()
            working = Bitmap.createBitmap(bitmap.width, scaledHeight, Bitmap.Config.ARGB_8888)
            working.eraseColor(Color.WHITE)
            val left = (bitmap.width - targetWidth) / 2f
            Canvas(working).drawBitmap(scaled, left, 0f, null)
            scaled.recycle()
            ownsWorking = true
            startRow = 0
            endRow = working.height
        } else if (!fitWidth && content.width() < bitmap.width - 8) {
            // Preserve the webpage's content size but remove its asymmetric side
            // margins, then center it on the physical print head.
            val cropTop = if (compact) content.top else 0
            val cropBottom = if (compact) content.bottom else bitmap.height
            val cropped = Bitmap.createBitmap(
                bitmap,
                content.left,
                cropTop,
                content.width().coerceAtLeast(1),
                (cropBottom - cropTop).coerceAtLeast(1),
            )
            working = Bitmap.createBitmap(bitmap.width, cropped.height, Bitmap.Config.ARGB_8888)
            working.eraseColor(Color.WHITE)
            val left = (bitmap.width - cropped.width) / 2f
            Canvas(working).drawBitmap(cropped, left, 0f, null)
            cropped.recycle()
            ownsWorking = true
            startRow = 0
            endRow = working.height
        }
        val widthBytes = (working.width + 7) / 8
        val pixels = IntArray(working.width)
        // Reset alignment, left margin and print-area width before raster output.
        connection.write(byteArrayOf(0x1b, 0x61, 0x00))
        connection.write(byteArrayOf(0x1d, 0x4c, 0x00, 0x00))
        connection.write(
            byteArrayOf(
                0x1d, 0x57,
                (working.width and 0xff).toByte(),
                ((working.width shr 8) and 0xff).toByte(),
            ),
        )
        val threshold = when (density.coerceIn(1, 5)) {
            1 -> 115
            2 -> 138
            3 -> 160
            4 -> 185
            else -> 210
        }
        var top = startRow
        while (top < endRow) {
            val rows = minOf(512, endRow - top)
            val data = ByteArray(widthBytes * rows)
            for (row in 0 until rows) {
                working.getPixels(pixels, 0, working.width, 0, top + row, working.width, 1)
                for (x in pixels.indices) {
                    val color = pixels[x]
                    val luminance = (Color.red(color) * 30 + Color.green(color) * 59 + Color.blue(color) * 11) / 100
                    if (luminance < threshold) {
                        val index = row * widthBytes + x / 8
                        data[index] = (data[index].toInt() or (0x80 shr (x % 8))).toByte()
                    }
                }
            }
            val command = byteArrayOf(
                0x1d, 0x76, 0x30, 0x00,
                (widthBytes and 0xff).toByte(), ((widthBytes shr 8) and 0xff).toByte(),
                (rows and 0xff).toByte(), ((rows shr 8) and 0xff).toByte(),
            )
            connection.write(command)
            connection.write(data)
            top += rows
        }
        if (ownsWorking) working.recycle()
    }

    private fun contentBounds(bitmap: Bitmap, pixels: IntArray): Rect {
        var firstRow = -1
        var lastRow = -1
        var firstColumn = bitmap.width
        var lastColumn = -1
        val columnInk = IntArray(bitmap.width)
        for (row in 0 until bitmap.height) {
            bitmap.getPixels(pixels, 0, bitmap.width, 0, row, bitmap.width, 1)
            var rowHasInk = false
            pixels.forEachIndexed { column, color ->
                val luminance = (Color.red(color) * 30 + Color.green(color) * 59 + Color.blue(color) * 11) / 100
                if (luminance < 225) {
                    rowHasInk = true
                    columnInk[column]++
                    if (column < firstColumn) firstColumn = column
                    if (column > lastColumn) lastColumn = column
                }
            }
            if (rowHasInk) {
                if (firstRow < 0) firstRow = row
                lastRow = row
            }
        }
        if (firstRow < 0) return Rect(0, 0, bitmap.width, 1)
        // A single border or artifact can span the PDF page. Require repeated ink
        // in a column so the bounds follow the actual receipt text instead.
        val robustFirst = columnInk.indexOfFirst { it >= 6 }
        val robustLast = columnInk.indexOfLast { it >= 6 }
        if (robustFirst >= 0 && robustLast >= robustFirst) {
            firstColumn = robustFirst
            lastColumn = robustLast
        }
        return Rect(
            (firstColumn - 8).coerceAtLeast(0),
            (firstRow - 16).coerceAtLeast(0),
            (lastColumn + 9).coerceAtMost(bitmap.width),
            (lastRow + 33).coerceAtMost(bitmap.height),
        )
    }
}
