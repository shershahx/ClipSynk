package com.clipsync.clip_sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restarts the Flutter background service after device boot.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            // The flutter_background_service plugin handles restarting the service.
            // This receiver ensures we get the boot broadcast.
            // The service auto-starts via SharedPreferences flag set by the plugin.
        }
    }
}
