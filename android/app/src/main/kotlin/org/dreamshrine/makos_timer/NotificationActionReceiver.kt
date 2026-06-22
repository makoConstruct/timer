package org.dreamshrine.makos_timer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat

/**
 * Receives the completion notification's tap / dismiss / action-button
 * PendingIntents. Cancels the notification and pushes the event into every live
 * Flutter engine (see [PlatformNotificationPlugin.dispatchEvent]), which fans out
 * to the same dismiss handling AWN's setListeners used to drive.
 *
 * If no engine is alive (process killed), the in-process looping alarm is already
 * gone too, so cancelling the notification natively is all that's needed; DB state
 * is reconciled on next launch.
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(PlatformNotificationPlugin.EXTRA_NOTIFICATION_ID, -1)
        val event = intent.getStringExtra(PlatformNotificationPlugin.EXTRA_EVENT)
            ?: PlatformNotificationPlugin.EVENT_ACTION

        if (id != -1) {
            NotificationManagerCompat.from(context).cancel(id)
        }
        PlatformNotificationPlugin.dispatchEvent(event)
    }
}
