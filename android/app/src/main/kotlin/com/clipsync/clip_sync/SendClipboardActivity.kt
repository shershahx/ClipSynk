package com.clipsync.clip_sync

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * Invisible activity started by [ClipboardTileService].
 *
 * Android 10+ only lets the app that currently has input focus read the
 * clipboard, so we briefly take focus, read it, upload it and close.
 */
class SendClipboardActivity : Activity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true

        val text = readClipboardText()
        when {
            text.isNullOrEmpty() -> finishWithToast("Clipboard is empty")
            text.length > ClipboardUploader.MAX_LENGTH -> finishWithToast("Clipboard text is too large")
            else -> {
                val appContext = applicationContext
                Thread {
                    val message = ClipboardUploader.send(appContext, text)
                    Handler(Looper.getMainLooper()).post { finishWithToast(message) }
                }.start()
            }
        }
    }

    private fun readClipboardText(): String? {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(this)?.toString()
    }

    private fun finishWithToast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
        finish()
        overridePendingTransition(0, 0)
    }
}
