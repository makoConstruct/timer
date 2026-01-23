package org.dreamshrine.makos_timer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register plugins for main engine
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        flutterEngine.plugins.add(PlatformAudioPlugin())

        // Register lifecycle listener for background engine
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(CustomPluginRegistrant())
    }
}
