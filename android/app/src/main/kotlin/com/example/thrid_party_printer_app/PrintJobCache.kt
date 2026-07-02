package com.example.thrid_party_printer_app

import android.content.Context
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileOutputStream

class PrintJobCache(context: Context) {
    private val directory = File(context.filesDir, "print_job_cache").apply { mkdirs() }
    private val maximumBytes = 50L * 1024L * 1024L

    fun store(jobId: String, descriptor: ParcelFileDescriptor): File {
        val safeId = jobId.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val destination = File(directory, "$safeId.pdf")
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            FileOutputStream(destination, false).use { output -> input.copyTo(output) }
        }
        destination.setLastModified(System.currentTimeMillis())
        prune(destination)
        return destination
    }

    fun delete(file: File) {
        if (file.parentFile == directory) file.delete()
    }

    fun clear() {
        directory.listFiles()?.forEach { it.delete() }
    }

    fun info(): Map<String, Any> {
        val files = directory.listFiles()?.filter { it.isFile } ?: emptyList()
        return mapOf(
            "count" to files.size,
            "bytes" to files.sumOf { it.length() },
            "limitBytes" to maximumBytes,
        )
    }

    private fun prune(current: File) {
        val oldFiles = directory.listFiles()
            ?.filter { it.isFile && it != current }
            ?.sortedBy { it.lastModified() }
            ?.toMutableList()
            ?: return
        var total = directory.listFiles()?.sumOf { it.length() } ?: 0L
        while (total > maximumBytes && oldFiles.isNotEmpty()) {
            val oldest = oldFiles.removeAt(0)
            total -= oldest.length()
            oldest.delete()
        }
    }
}
