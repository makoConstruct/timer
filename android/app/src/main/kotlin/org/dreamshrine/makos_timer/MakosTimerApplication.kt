package org.dreamshrine.makos_timer

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin

/**
 * Registers the foreground-task lifecycle listener at process startup, so the
 * background (foreground-service) Flutter engine gets PlatformAudioPlugin and
 * PlatformNotificationPlugin registered EVEN when the process was started by the
 * boot receiver — i.e. with no MainActivity.
 *
 * Previously this registration lived in MainActivity.configureFlutterEngine,
 * which never runs on a reboot-started service. The boot engine therefore came
 * up with neither custom plugin, so after a reboot the background isolate could
 * vibrate (vibration is a normal plugin, registered via GeneratedPluginRegistrant)
 * but produced no sound and no completion notifications. Because the engine is
 * never recreated, the breakage persisted for that process's whole lifetime,
 * even after the app was opened and re-backgrounded.
 *
 * onCreate runs once per process, before the service creates its engine, so the
 * listener is guaranteed to be present when onEngineCreate fires.
 */
class MakosTimerApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(CustomPluginRegistrant())
    }
}
