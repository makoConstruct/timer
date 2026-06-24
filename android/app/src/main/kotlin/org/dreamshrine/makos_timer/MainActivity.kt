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

        // The background-engine lifecycle listener is registered in  MakosTimerApplication.onCreate (not here), so that it will be present even when the service is started by the boot receiver (via foreground task), which bypasses this activity.
    }
}
