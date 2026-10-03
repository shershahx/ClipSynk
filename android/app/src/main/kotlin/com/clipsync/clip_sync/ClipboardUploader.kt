package com.clipsync.clip_sync

import android.content.Context
import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Pushes a clipboard string to Supabase without needing the Flutter engine.
 *
 * It reuses the session that supabase_flutter persisted in SharedPreferences,
 * refreshing it (and writing it back) when the access token has expired, so it
 * works even when the app isn't running.
 *
 * Config keys (url, anon key, device id) are written by the Dart side; see
 * `lib/main.dart` and `DeviceIdService`.
 */
object ClipboardUploader {
    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_URL = "flutter.clip_sync_supabase_url"
    private const val KEY_ANON = "flutter.clip_sync_supabase_anon_key"
    private const val KEY_DEVICE = "flutter.clip_sync_device_id"
    private const val TIMEOUT_MS = 8000

    const val MAX_LENGTH = 65536

    /** Blocking. Call from a background thread. Returns a message for the user. */
    fun send(context: Context, text: String): String {
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val baseUrl = prefs.getString(KEY_URL, null)
            val anonKey = prefs.getString(KEY_ANON, null)
            val deviceId = prefs.getString(KEY_DEVICE, null)
            if (baseUrl == null || anonKey == null || deviceId == null) {
                return "Open ClipSync once to finish setup"
            }

            val projectRef = Uri.parse(baseUrl).host?.substringBefore('.') ?: ""
            val sessionKey = "flutter.sb-$projectRef-auth-token"
            val sessionJson = prefs.getString(sessionKey, null)
                ?: return "Sign in to ClipSync first"

            var session = JSONObject(sessionJson)
            val nowSec = System.currentTimeMillis() / 1000
            var expiresAt = session.optLong("expires_at", 0L)
            if (expiresAt == 0L) expiresAt = jwtExpiry(session.optString("access_token"))

            if (expiresAt - 30 < nowSec) {
                val refreshed = refreshSession(baseUrl, anonKey, session.optString("refresh_token"))
                    ?: return "Session expired - open ClipSync to sign in again"
                if (!refreshed.has("expires_at")) {
                    refreshed.put("expires_at", nowSec + refreshed.optLong("expires_in", 3600))
                }
                prefs.edit().putString(sessionKey, refreshed.toString()).commit()
                session = refreshed
            }

            val accessToken = session.getString("access_token")
            val userId = session.getJSONObject("user").getString("id")

            val body = JSONObject()
                .put("user_id", userId)
                .put("device_id", deviceId)
                .put("content", text)
                .toString()

            val conn = open("$baseUrl/rest/v1/clipboard_items", anonKey)
            conn.requestMethod = "POST"
            conn.setRequestProperty("Authorization", "Bearer $accessToken")
            conn.setRequestProperty("Prefer", "return=minimal")
            conn.doOutput = true
            conn.outputStream.use { it.write(body.toByteArray()) }

            val code = conn.responseCode
            conn.disconnect()
            return if (code in 200..299) "Clipboard sent to ClipSync" else "Send failed ($code)"
        } catch (e: Exception) {
            return "Send failed: ${e.javaClass.simpleName}"
        }
    }

    private fun refreshSession(baseUrl: String, anonKey: String, refreshToken: String): JSONObject? {
        if (refreshToken.isEmpty()) return null
        val conn = open("$baseUrl/auth/v1/token?grant_type=refresh_token", anonKey)
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.outputStream.use {
            it.write(JSONObject().put("refresh_token", refreshToken).toString().toByteArray())
        }
        val ok = conn.responseCode in 200..299
        val response = if (ok) conn.inputStream.bufferedReader().use { it.readText() } else null
        conn.disconnect()
        return response?.let { JSONObject(it) }
    }

    private fun open(url: String, anonKey: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = TIMEOUT_MS
        conn.readTimeout = TIMEOUT_MS
        conn.setRequestProperty("apikey", anonKey)
        conn.setRequestProperty("Content-Type", "application/json")
        return conn
    }

    private fun jwtExpiry(jwt: String): Long {
        return try {
            val payload = jwt.split('.')[1]
            val json = String(Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP))
            JSONObject(json).optLong("exp", 0L)
        } catch (e: Exception) {
            0L
        }
    }
}
