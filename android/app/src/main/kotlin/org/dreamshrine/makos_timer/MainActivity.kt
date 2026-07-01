package org.dreamshrine.makos_timer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register plugins for main engine
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        flutterEngine.plugins.add(PlatformAudioPlugin())
        flutterEngine.plugins.add(PlatformNotificationPlugin())
        flutterEngine.plugins.add(ForegroundControlPlugin())

        // The foreground engine's custom plugins are registered directly in
        // MakosTimerForegroundService.bootstrapEngine (not here), so they're present
        // even when the service is started by the boot receiver, which bypasses this
        // activity.
    }
}
