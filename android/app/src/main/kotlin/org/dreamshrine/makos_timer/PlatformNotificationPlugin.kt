package org.dreamshrine.makos_timer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.Collections

/**
 * Replaces awesome_notifications for this app's single use case: a timer
 * completion notification (alarm category, ongoing, big-picture) with a
 * "dismiss" action, plus channel setup and cancelAll.
 *
 * Registered into BOTH the main engine (MainActivity) and the foreground-service
 * engine (CustomPluginRegistrant), exactly like PlatformAudioPlugin. Every live
 * engine's channel is kept in [channels] so a notification action (which arrives
 * via [NotificationActionReceiver]) can be pushed back into whichever isolate is
 * alive — mirroring AWN's setListeners callbacks.
 */
class PlatformNotificationPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    companion object {
        const val CHANNEL_NAME = "platform_notifications"

        // Intent extras / actions used by NotificationActionReceiver.
        const val EXTRA_NOTIFICATION_ID = "notification_id"
        const val EXTRA_EVENT = "event"
        const val EVENT_ACTION = "action"
        const val EVENT_DISMISS = "dismiss"

        // Dark green from the logo, used to tint the monochrome small icon's
        // background circle instead of the system's default accent color.
        private const val NOTIFICATION_ACCENT_COLOR = 0xFFB7DEA6.toInt()

        // Every attached engine's channel. native -> Dart pushes fan out to all of
        // them; each isolate then runs its own dismiss handling.
        private val channels =
            Collections.synchronizedSet(mutableSetOf<MethodChannel>())
        private val mainHandler = Handler(Looper.getMainLooper())

        /** Called by NotificationActionReceiver on the main thread. */
        fun dispatchEvent(event: String) {
            mainHandler.post {
                synchronized(channels) {
                    for (ch in channels) {
                        ch.invokeMethod(
                            "notificationEvent",
                            mapOf("event" to event),
                        )
                    }
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        channels.add(channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channels.remove(channel)
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "ensureChannel" -> {
                ensureChannel(
                    call.argument<String>("channelKey")!!,
                    call.argument<String>("channelName") ?: "",
                    call.argument<String>("channelDescription") ?: "",
                    call.argument<Int>("importance") ?: NotificationManager.IMPORTANCE_HIGH,
                )
                result.success(null)
            }
            "showCompletion" -> {
                showCompletion(
                    call.argument<Int>("id")!!,
                    call.argument<String>("channelKey")!!,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                )
                result.success(null)
            }
            "cancelAll" -> {
                NotificationManagerCompat.from(context).cancelAll()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureChannel(
        channelKey: String,
        channelName: String,
        channelDescription: String,
        importance: Int,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val nc = NotificationChannel(channelKey, channelName, importance).apply {
            description = channelDescription
        }
        manager.createNotificationChannel(nc)
    }

    private fun broadcastIntent(id: Int, event: String, requestOffset: Int): PendingIntent {
        val intent = Intent(context, NotificationActionReceiver::class.java).apply {
            putExtra(EXTRA_NOTIFICATION_ID, id)
            putExtra(EXTRA_EVENT, event)
        }
        return PendingIntent.getBroadcast(
            context,
            id * 10 + requestOffset,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun showCompletion(id: Int, channelKey: String, title: String, body: String) {
        val smallIcon = resId("res_notification_icon")
        val bigPicture = loadBitmap("res_large_notification_icon")

        val contentIntent = broadcastIntent(id, EVENT_ACTION, 0)
        val deleteIntent = broadcastIntent(id, EVENT_DISMISS, 1)
        val dismissIntent = broadcastIntent(id, EVENT_ACTION, 2)

        val builder = NotificationCompat.Builder(context, channelKey)
            .setSmallIcon(smallIcon)
            .setColor(NOTIFICATION_ACCENT_COLOR)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .setDeleteIntent(deleteIntent)
            .addAction(0, "dismiss", dismissIntent)

        if (bigPicture != null) {
            builder.setLargeIcon(bigPicture)
            builder.setStyle(
                NotificationCompat.BigPictureStyle()
                    .bigPicture(bigPicture)
                    .bigLargeIcon(null as Bitmap?),
            )
        }

        // POST_NOTIFICATIONS is requested elsewhere (flutter_foreground_task); if it
        // isn't granted, notify() is a no-op rather than a crash.
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            NotificationManagerCompat.from(context).notify(id, builder.build())
        }
    }

    private fun resId(name: String, type: String = "drawable"): Int =
        context.resources.getIdentifier(name, type, context.packageName)

    /**
     * Renders [name] to a bitmap. Tolerant: a `<bitmap>` wrapper around an
     * adaptive launcher icon can't be inflated as a BitmapDrawable, so on any
     * failure we fall back to rendering the launcher mipmap directly (adaptive
     * icons draw fine to a canvas). Returns null if even that fails — the
     * notification still posts, just without a big picture.
     */
    private fun loadBitmap(name: String): Bitmap? =
        renderDrawable(resId(name)) ?: renderDrawable(resId("ic_launcher", "mipmap"))

    private fun renderDrawable(id: Int): Bitmap? {
        if (id == 0) return null
        return try {
            val drawable: Drawable = ContextCompat.getDrawable(context, id) ?: return null
            val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: 256
            val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: 256
            val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, width, height)
            drawable.draw(canvas)
            bmp
        } catch (e: Exception) {
            null
        }
    }
}
