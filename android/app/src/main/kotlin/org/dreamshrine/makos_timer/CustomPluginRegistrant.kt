package org.dreamshrine.makos_timer

import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant


/// this is a hack to get the PlatformAudioPlugin to work in the background isolate, other dart plugins don't seem to need this, so if we just made PlatformAudioPlugin a standard plugin, it would work without this. No need to fix for now.
class CustomPluginRegistrant : FlutterForegroundTaskLifecycleListener {
    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        if (flutterEngine != null) {
            // this is already done, don't have to do it again, this CustomPluginRegistrant only exists for PlatformAudioPlugin.
            // // Register all standard plugins
            // GeneratedPluginRegistrant.registerWith(flutterEngine)
            // Register our custom plugin
            flutterEngine.plugins.add(PlatformAudioPlugin())
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {
        // Not needed for plugin registration
    }

    override fun onTaskRepeatEvent() {
        // Not needed for plugin registration
    }

    override fun onTaskDestroy() {
        // Not needed for plugin registration
    }

    override fun onEngineWillDestroy() {
        // Not needed for plugin registration
    }
}
